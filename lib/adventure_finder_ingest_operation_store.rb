# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"
require "securerandom"
require "time"
require_relative "adventure_finder_ingest_operation"

module AdventureFinderWorkspace
  # Durable, append-only persistence for IngestOperation documents.
  #
  # Absolute roots are runtime configuration. Only contract locators and content
  # identities are persisted, so an operation remains portable between machines.
  class IngestOperationStore
    STORE_VERSION = "adventurefinder-ingest-operation-store/v0.1"
    INSPECTION_VERSION = "adventurefinder-ingest-operation-inspection/v0.1"
    UUID_V4 = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

    class Failure < Error
      attr_reader :code

      def initialize(code, message)
        @code = code
        super("#{code}: #{message}")
      end
    end

    attr_reader :root, :roots

    def self.default_root(front_door_root: ENV["AF_ADVENTURE_FINDER_ROOT"] || File.expand_path("..", __dir__))
      Pathname(front_door_root).expand_path.join("output", "ingest-operations", "v0.1")
    end

    def initialize(root: self.class.default_root, roots: {})
      @root = Pathname(root).expand_path
      @roots = roots.to_h.transform_keys(&:to_s).transform_values { |path| Pathname(path).expand_path }
      unknown = @roots.keys - IngestOperation::ROOTS
      fail_with("CORRUPT_EVIDENCE", "unknown configured roots: #{unknown.join(', ')}") unless unknown.empty?
    end

    # Create revision zero from files and explicit operator choices. This method
    # hashes the referenced bytes; callers cannot persist invented content facts.
    def create(operation_id: SecureRandom.uuid, created_at: utc_now,
               input_locator:, base_catalog_locator:, catalog_selected_by:,
               catalog_selected_at: created_at, catalog_selection_method: "explicit",
               project_state_locator: nil, source_declaration: nil, policy: nil)
      selection = {
        "method" => catalog_selection_method,
        "selected_by" => catalog_selected_by,
        "selected_at" => catalog_selected_at,
        "project_state" => nil
      }
      if catalog_selection_method == "catalog_head"
        fail_with("CORRUPT_EVIDENCE", "catalog_head requires project_state_locator") unless project_state_locator
        selection["project_state"] = {
          "contract_version" => "adventurefinder-project-state/v0.2",
          "content" => content_for(project_state_locator, binding_id: "project_state")
        }
      elsif project_state_locator
        fail_with("CORRUPT_EVIDENCE", "explicit selection cannot bind project_state_locator")
      end

      document = {
        "contract_version" => IngestOperation::VERSION,
        "operation_id" => operation_id,
        "created_at" => created_at,
        "revision" => 0,
        "previous_revision_sha256" => nil,
        "input" => {
          "kind" => "digital_book_pdf",
          "content" => content_for(input_locator, binding_id: "input")
        },
        "source_declaration" => source_declaration ||
          IngestOperation::SOURCE_CHOICES.to_h { |choice| [choice, nil] },
        "base_catalog" => {
          "content" => content_for(base_catalog_locator, binding_id: "base_catalog"),
          "selection" => selection
        },
        "policy" => policy,
        "artifacts" => [],
        "future_choices" => IngestOperation::FUTURE_CHOICES.to_h { |choice| [choice, nil] },
        "coordination" => {"status" => "created", "route_observation" => nil}
      }
      IngestOperation.validate!(document)
      persist_initial!(document)
    rescue Failure
      raise
    rescue Error => e
      fail_with("CORRUPT_EVIDENCE", e.message)
    end

    # Append one validated revision with an optimistic-lock assertion. An exact
    # replay returns the already persisted document without rewriting its bytes.
    def persist!(document, expected_revision:, expected_sha256:)
      operation_id = document.is_a?(Hash) && document["operation_id"]
      validate_operation_id!(operation_id)
      with_operation_lock(operation_id, File::LOCK_EX) do
        current = load_history_unlocked!(operation_id).last
        if IngestOperation.digest(current) == IngestOperation.digest(document)
          verify_bindings!(current)
          return current
        end

        unless current["revision"] == expected_revision && IngestOperation.digest(current) == expected_sha256
          fail_with("CONFLICT", "operation advanced from the expected revision")
        end

        begin
          IngestOperation.validate_revision!(current, document)
        rescue Error => e
          fail_with("CONFLICT", e.message)
        end
        verify_bindings!(document)
        target = revisions_dir(operation_id).join(revision_filename(document.fetch("revision")))
        fail_with("CONFLICT", "revision already exists") if target.exist?

        atomic_write(target, document_bytes(document))
        load_history_unlocked!(operation_id).last
      end
    end

    # Load and validate the complete immutable revision chain.
    def load(operation_id)
      validate_operation_id!(operation_id)
      fail_with("NOT_FOUND", "operation does not exist") unless operation_dir(operation_id).directory?

      with_operation_lock(operation_id, File::LOCK_SH) { load_history_unlocked!(operation_id).last }
    end

    # Read-only inspection. It never creates a store, lock, or operation file.
    def inspect(operation_id)
      validate_operation_id!(operation_id)
      return inspection(operation_id, "ABSENT", artifact_state: "ABSENT") unless operation_dir(operation_id).exist?

      with_operation_lock(operation_id, File::LOCK_SH) do
        document = load_history_unlocked!(operation_id).last
        binding_results = binding_entries(document).map { |entry| inspect_binding(entry) }
        findings = binding_results.filter_map { |entry| entry.delete("finding") }
        artifact_state = if document["artifacts"].empty?
                           "INTENTIONALLY_UNBOUND"
                         elsif findings.empty?
                           "BOUND"
                         else
                           "INVALID"
                         end
        inspection(operation_id, findings.empty? ? "VALID" : "INVALID",
                   document: document, bindings: binding_results, findings: findings,
                   artifact_state: artifact_state)
      end
    rescue Failure => e
      inspection(operation_id, "INVALID", artifact_state: "INVALID",
                 findings: [{"code" => e.code, "binding_id" => nil, "message" => e.message.sub(/\A[^:]+: /, "")}])
    end

    def validate!(operation_id)
      result = inspect(operation_id)
      return result.fetch("operation") if result["operation_status"] == "VALID"

      finding = result.fetch("findings").first || {"code" => "CORRUPT_EVIDENCE", "message" => "invalid operation"}
      fail_with(finding.fetch("code"), finding.fetch("message"))
    end

    def revision_path(operation_id, revision)
      validate_operation_id!(operation_id)
      revisions_dir(operation_id).join(revision_filename(revision))
    end

    private

    def utc_now
      Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def persist_initial!(document)
      operation_id = document.fetch("operation_id")
      validate_operation_id!(operation_id)
      with_creation_lock(operation_id) do
        if operation_dir(operation_id).exist?
          current = load(operation_id)
          return current if IngestOperation.digest(current) == IngestOperation.digest(document)

          fail_with("CONFLICT", "operation_id is already bound to different content")
        end

        FileUtils.mkdir_p(root)
        stage = root.join(".#{operation_id}.tmp-#{Process.pid}-#{SecureRandom.hex(6)}")
        begin
          FileUtils.mkdir_p(stage.join("revisions"))
          File.open(stage.join(".lock"), "wb") { |file| file.flush; file.fsync }
          atomic_write(stage.join("store.json"), document_bytes(
            "contract_version" => STORE_VERSION, "operation_id" => operation_id
          ))
          atomic_write(stage.join("revisions", revision_filename(0)), document_bytes(document))
          File.rename(stage, operation_dir(operation_id))
          fsync_directory(root)
        ensure
          FileUtils.remove_entry(stage) if stage.exist?
        end
        load(operation_id)
      end
    end

    def load_history_unlocked!(operation_id)
      directory = operation_dir(operation_id)
      fail_with("CORRUPT_EVIDENCE", "operation data is not a directory") unless directory.directory?
      expected_entries = %w[.lock revisions store.json]
      unless directory.children.map { |path| path.basename.to_s }.sort == expected_entries
        fail_with("CORRUPT_EVIDENCE", "operation directory contains missing or unexpected data")
      end
      fail_with("CORRUPT_EVIDENCE", "operation lock is missing") unless directory.join(".lock").file?
      fail_with("CORRUPT_EVIDENCE", "revision directory is missing") unless revisions_dir(operation_id).directory?

      metadata = parse_json!(directory.join("store.json"))
      unless metadata.is_a?(Hash) && metadata.keys.sort == %w[contract_version operation_id] &&
             metadata["operation_id"] == operation_id
        fail_with("CORRUPT_EVIDENCE", "invalid operation store metadata")
      end
      unless metadata["contract_version"] == STORE_VERSION
        fail_with("INCOMPATIBLE_VERSION", "unsupported operation store contract")
      end

      paths = revisions_dir(operation_id).children.sort_by { |path| path.basename.to_s }
      fail_with("CORRUPT_EVIDENCE", "operation has no revisions") if paths.empty?
      expected_names = paths.length.times.map { |revision| revision_filename(revision) }
      unless paths.all?(&:file?) && paths.map { |path| path.basename.to_s } == expected_names
        fail_with("CORRUPT_EVIDENCE", "revision sequence is missing, duplicated or malformed")
      end

      documents = paths.each_with_index.map do |path, revision|
        document = parse_json!(path)
        unless document.is_a?(Hash) && document["contract_version"] == IngestOperation::VERSION
          fail_with("INCOMPATIBLE_VERSION", "unsupported ingest operation contract")
        end
        begin
          IngestOperation.validate!(document)
        rescue Error => e
          fail_with("CORRUPT_EVIDENCE", "invalid revision #{revision}: #{e.message}")
        end
        unless document["operation_id"] == operation_id && document["revision"] == revision
          fail_with("CORRUPT_EVIDENCE", "revision identity does not match storage identity")
        end
        document
      end
      documents.each_cons(2) do |previous, current|
        begin
          IngestOperation.validate_revision!(previous, current)
        rescue Error => e
          fail_with("CORRUPT_EVIDENCE", "invalid revision chain: #{e.message}")
        end
      end
      documents
    end

    def verify_bindings!(document)
      binding_entries(document).each do |entry|
        result = inspect_binding(entry)
        next unless result["finding"]

        finding = result.fetch("finding")
        fail_with(finding.fetch("code"), "#{entry.fetch('binding_id')}: #{finding.fetch('message')}")
      end
    end

    def binding_entries(document)
      entries = [
        {"binding_id" => "input", "kind" => "input", "content" => document.dig("input", "content")},
        {"binding_id" => "base_catalog", "kind" => "base_catalog", "content" => document.dig("base_catalog", "content")}
      ]
      project_state = document.dig("base_catalog", "selection", "project_state")
      if project_state
        entries << {"binding_id" => "project_state", "kind" => "project_state",
                    "content" => project_state["content"]}
      end
      document.fetch("artifacts").each do |artifact|
        entries << {"binding_id" => artifact.fetch("artifact_id"), "kind" => artifact.fetch("kind"),
                    "owner" => artifact.fetch("owner"), "contract_version" => artifact.fetch("contract_version"),
                    "content" => artifact.fetch("content")}
      end
      entries
    end

    def inspect_binding(entry)
      content = entry.fetch("content")
      path = resolve_locator(content.fetch("locator"), binding_id: entry.fetch("binding_id"), require_file: false)
      result = entry.reject { |key, _| key == "content" }.merge(
        "expected_sha256" => content.fetch("sha256"),
        "expected_bytes" => content.fetch("bytes"),
        "locator" => content.fetch("locator")
      )
      unless path.file?
        return result.merge("status" => "MISSING", "finding" => {
          "code" => "MISSING_BOUND_ARTIFACT", "binding_id" => entry.fetch("binding_id"),
          "message" => "bound content is missing"
        })
      end

      bytes = File.binread(path)
      actual_sha = Digest::SHA256.hexdigest(bytes)
      actual_bytes = bytes.bytesize
      if actual_sha != content.fetch("sha256") || actual_bytes != content.fetch("bytes")
        return result.merge("status" => "MISMATCH", "actual_sha256" => actual_sha,
                            "actual_bytes" => actual_bytes, "finding" => {
                              "code" => "STALE_INPUT", "binding_id" => entry.fetch("binding_id"),
                              "message" => "bound content bytes changed"
                            })
      end
      result.merge("status" => "PRESENT", "actual_sha256" => actual_sha, "actual_bytes" => actual_bytes)
    rescue Failure => e
      result ||= entry.reject { |key, _| key == "content" }
      result.merge("status" => "INVALID", "finding" => {
        "code" => e.code, "binding_id" => entry.fetch("binding_id"),
        "message" => e.message.sub(/\A[^:]+: /, "")
      })
    rescue SystemCallError => e
      result ||= entry.reject { |key, _| key == "content" }
      result.merge("status" => "INVALID", "finding" => {
        "code" => "CORRUPT_EVIDENCE", "binding_id" => entry.fetch("binding_id"),
        "message" => "bound content could not be read: #{e.class}"
      })
    end

    def content_for(locator, binding_id:)
      path = resolve_locator(locator, binding_id: binding_id, require_file: true)
      bytes = File.binread(path)
      {
        "sha256" => Digest::SHA256.hexdigest(bytes),
        "bytes" => bytes.bytesize,
        "locator" => deep_copy(locator)
      }
    rescue SystemCallError => e
      fail_with("CORRUPT_EVIDENCE", "#{binding_id} could not be read: #{e.class}")
    end

    def resolve_locator(locator, binding_id:, require_file:)
      unless locator.is_a?(Hash) && locator.keys.sort == %w[path root]
        fail_with("CORRUPT_EVIDENCE", "#{binding_id} has an invalid locator")
      end
      root_name = locator["root"]
      relative = locator["path"]
      configured_root = roots[root_name]
      fail_with("CORRUPT_EVIDENCE", "#{binding_id} root #{root_name.inspect} is not configured") unless configured_root
      unless configured_root.directory?
        fail_with("CORRUPT_EVIDENCE", "#{binding_id} configured root is unavailable")
      end
      unless relative.is_a?(String) && !relative.empty? && !relative.start_with?("/") &&
             !relative.include?("\\") && !relative.include?(":") &&
             relative.split("/", -1).none? { |part| ["", ".", ".."].include?(part) }
        fail_with("CORRUPT_EVIDENCE", "#{binding_id} has an unsafe locator")
      end

      candidate = configured_root.join(relative).cleanpath
      root_real = configured_root.realpath
      existing_ancestor = candidate
      existing_ancestor = existing_ancestor.parent until existing_ancestor.exist? || existing_ancestor.symlink?
      unless descendant?(existing_ancestor.realpath, root_real)
        fail_with("CORRUPT_EVIDENCE", "#{binding_id} locator escapes its configured root")
      end
      if candidate.exist? || candidate.symlink?
        begin
          candidate_real = candidate.realpath
        rescue Errno::ENOENT
          return candidate unless require_file
          fail_with("MISSING_BOUND_ARTIFACT", "#{binding_id} is missing")
        end
        unless descendant?(candidate_real, root_real)
          fail_with("CORRUPT_EVIDENCE", "#{binding_id} locator escapes its configured root")
        end
      elsif !descendant?(candidate, configured_root)
        fail_with("CORRUPT_EVIDENCE", "#{binding_id} locator escapes its configured root")
      end
      if require_file && !candidate.file?
        fail_with("MISSING_BOUND_ARTIFACT", "#{binding_id} is missing")
      end
      candidate
    end

    def descendant?(path, ancestor)
      path_string = path.to_s
      ancestor_string = ancestor.to_s
      path_string == ancestor_string || path_string.start_with?(ancestor_string + File::SEPARATOR)
    end

    def with_creation_lock(operation_id)
      FileUtils.mkdir_p(root.join(".locks"))
      File.open(root.join(".locks", "#{operation_id}.lock"), File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        yield
      ensure
        file.flock(File::LOCK_UN)
      end
    end

    def with_operation_lock(operation_id, mode)
      lock_path = operation_dir(operation_id).join(".lock")
      fail_with("CORRUPT_EVIDENCE", "operation lock is missing") unless lock_path.file?
      File.open(lock_path, File::RDONLY) do |file|
        file.flock(mode)
        yield
      ensure
        file.flock(File::LOCK_UN)
      end
    rescue Errno::ENOENT
      fail_with("CORRUPT_EVIDENCE", "operation data changed during inspection")
    end

    def atomic_write(path, bytes)
      temporary = path.dirname.join(".#{path.basename}.tmp-#{Process.pid}-#{SecureRandom.hex(6)}")
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.binmode
        file.write(bytes)
        file.flush
        file.fsync
      end
      File.rename(temporary, path)
      fsync_directory(path.dirname)
    ensure
      File.unlink(temporary) if temporary && temporary.exist?
    end

    def fsync_directory(directory)
      File.open(directory, File::RDONLY, &:fsync)
    rescue Errno::EINVAL, Errno::EISDIR
      # Some filesystems do not support directory fsync; atomic rename still
      # prevents a reader from observing partial JSON.
    end

    def parse_json!(path)
      JSON.parse(File.binread(path))
    rescue Errno::ENOENT
      fail_with("CORRUPT_EVIDENCE", "missing operation data: #{path.basename}")
    rescue JSON::ParserError
      fail_with("CORRUPT_EVIDENCE", "invalid JSON in #{path.basename}")
    end

    def inspection(operation_id, status, document: nil, bindings: [], findings: [], artifact_state:)
      {
        "contract_version" => INSPECTION_VERSION,
        "operation_id" => operation_id,
        "operation_status" => status,
        "operation_revision" => document && document["revision"],
        "operation_sha256" => document && IngestOperation.digest(document),
        "coordination_status" => document && document.dig("coordination", "status"),
        "artifact_state" => artifact_state,
        "operation" => document,
        "bindings" => bindings,
        "findings" => findings
      }
    end

    def operation_dir(operation_id)
      root.join(operation_id)
    end

    def revisions_dir(operation_id)
      operation_dir(operation_id).join("revisions")
    end

    def revision_filename(revision)
      fail_with("CORRUPT_EVIDENCE", "invalid revision number") unless revision.is_a?(Integer) && revision >= 0
      format("%08d.json", revision)
    end

    def document_bytes(document)
      JSON.pretty_generate(IngestOperation.canonical(document)) + "\n"
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end

    def validate_operation_id!(operation_id)
      fail_with("CORRUPT_EVIDENCE", "operation_id must be a lowercase UUIDv4") unless operation_id&.match?(UUID_V4)
    end

    def fail_with(code, message)
      raise Failure.new(code, message)
    end
  end
end
