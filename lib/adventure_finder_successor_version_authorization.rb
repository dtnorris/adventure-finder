# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
require_relative "adventure_finder_state_paths"
require "securerandom"
require "time"
require_relative "adventure_finder_ingest_operation_store"

module AdventureFinderWorkspace
  # Durable operator authority for one successor version and one operation/base.
  #
  # This is deliberately separate from IngestOperation revisions. It records
  # AdventureFinder-owned intent without changing the operation v0.1 contract or
  # becoming a component artifact eligible for pipeline routing.
  class SuccessorVersionAuthorizationStore
    VERSION = "adventurefinder-successor-version-authorization/v0.1"
    STORE_VERSION = "adventurefinder-successor-version-authorization-store/v0.1"
    PROJECTION_VERSION = "adventurefinder-successor-version-authorization-projection/v0.1"
    INSPECTION_VERSION = "adventurefinder-successor-version-authorization-inspection/v0.1"
    SUCCESSOR_VERSION = /\A\d+(?:\.\d+)+\z/

    class Failure < Error
      attr_reader :code

      def initialize(code, message)
        @code = code
        super("#{code}: #{message}")
      end
    end

    attr_reader :root, :operation_store

    # Returns the selected AF state family; invalid explicit selectors raise Error.
    def self.default_root(front_door_root: ENV["AF_ADVENTURE_FINDER_ROOT"] || File.expand_path("..", __dir__), env: ENV)
      StatePaths.root(front_door_root:, env:).join(
        "output", "ingest-authorities", "successor-version", "v0.1"
      )
    end

    def initialize(root: self.class.default_root, operation_store:, clock: -> { Time.now.utc })
      @root = Pathname(root).expand_path
      @operation_store = operation_store
      @clock = clock
    end

    # Bind once. An exact replay returns the validated existing authority without
    # rewriting any authority or operation bytes.
    def bind!(operation_id:, successor_version:, selected_by:)
      validate_operation_id!(operation_id)
      validate_successor_version!(successor_version)
      validate_text!(selected_by, "selected_by")
      operation = operation_store.validate!(operation_id)
      prior_evidence = authority_evidence?(operation_id)

      with_lock(operation_id) do
        # Revalidate under the authority lock so a broken or missing operation
        # cannot acquire durable authority between validation and persistence.
        operation = operation_store.validate!(operation_id)
        if authorization_dir(operation_id).exist?
          existing = load_authorization!(operation_id, operation)
          if existing["successor_version"] == successor_version && existing["selected_by"] == selected_by
            return existing
          end
          fail_with("SUCCESSOR_VERSION_AUTHORITY_CONFLICT",
                    "successor-version authority is already bound for this operation/base")
        end
        if prior_evidence
          fail_with("CORRUPT_SUCCESSOR_VERSION_AUTHORITY",
                    "authority publication evidence exists but its document is missing")
        end

        authorization = build_authorization(operation, successor_version, selected_by)
        persist!(operation_id, authorization)
        load_authorization!(operation_id, operation_store.validate!(operation_id))
      end
    rescue IngestOperationStore::Failure
      raise
    rescue Failure
      raise
    rescue SystemCallError => e
      fail_with("CORRUPT_SUCCESSOR_VERSION_AUTHORITY", "authority storage failed: #{e.class}")
    end

    # Read-only inspection. A never-bound operation is distinct from an authority
    # directory whose bytes are missing, corrupt, incompatible, or stale.
    def inspect(operation_id)
      validate_operation_id!(operation_id)
      operation = operation_store.validate!(operation_id)
      unless authorization_dir(operation_id).exist?
        if authority_evidence?(operation_id)
          fail_with("CORRUPT_SUCCESSOR_VERSION_AUTHORITY",
                    "authority publication evidence exists but its document is missing")
        end
        return inspection(operation_id, "UNBOUND")
      end

      authorization = with_existing_lock(operation_id) { load_authorization!(operation_id, operation) }
      inspection(operation_id, "BOUND", authorization:)
    rescue IngestOperationStore::Failure => e
      inspection(operation_id, "INVALID", findings: [finding(e.code, e.message)])
    rescue Failure => e
      inspection(operation_id, "INVALID", findings: [finding(e.code, e.message)])
    end

    def fetch!(operation_id)
      validate_operation_id!(operation_id)
      operation = operation_store.validate!(operation_id)
      unless authorization_dir(operation_id).exist?
        if authority_evidence?(operation_id)
          fail_with("CORRUPT_SUCCESSOR_VERSION_AUTHORITY",
                    "authority publication evidence exists but its document is missing")
        end
        fail_with("SUCCESSOR_VERSION_AUTHORITY_NOT_BOUND",
                  "successor-version authority is not yet bound")
      end

      with_existing_lock(operation_id) { load_authorization!(operation_id, operation) }
    end

    # Public AdventureFinder-owned handoff. Consumers need only this projection;
    # they do not need to know the private store layout.
    def projection(operation_id)
      {
        "contract_version" => PROJECTION_VERSION,
        "authorization" => fetch!(operation_id)
      }
    end

    def authorization_path(operation_id)
      validate_operation_id!(operation_id)
      authorization_dir(operation_id).join("authorization.json")
    end

    private

    def build_authorization(operation, successor_version, selected_by)
      body = {
        "contract_version" => VERSION,
        "operation" => {
          "contract_version" => operation.fetch("contract_version"),
          "operation_id" => operation.fetch("operation_id"),
          "created_at" => operation.fetch("created_at")
        },
        "base_catalog" => operation.fetch("base_catalog").fetch("content").slice("sha256", "bytes"),
        "successor_version" => successor_version,
        "selected_by" => selected_by,
        "selected_at" => @clock.call.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      }
      body.merge("authorization_id" => IngestOperation.digest(body))
    end

    def persist!(operation_id, authorization)
      FileUtils.mkdir_p(root)
      stage = root.join(".#{operation_id}.tmp-#{Process.pid}-#{SecureRandom.hex(6)}")
      begin
        FileUtils.mkdir_p(stage)
        atomic_write(stage.join("store.json"), document_bytes(
          "contract_version" => STORE_VERSION, "operation_id" => operation_id
        ))
        atomic_write(stage.join("authorization.json"), document_bytes(authorization))
        fail_with("SUCCESSOR_VERSION_AUTHORITY_CONFLICT", "authority appeared concurrently") if
          authorization_dir(operation_id).exist?
        File.rename(stage, authorization_dir(operation_id))
        fsync_directory(root)
      ensure
        FileUtils.remove_entry(stage) if stage.exist?
      end
    end

    def load_authorization!(operation_id, operation)
      directory = authorization_dir(operation_id)
      unless directory.directory? && directory.children.map { |path| path.basename.to_s }.sort ==
             %w[authorization.json store.json]
        fail_with("CORRUPT_SUCCESSOR_VERSION_AUTHORITY",
                  "authority directory contains missing or unexpected data")
      end

      metadata = parse_json!(directory.join("store.json"))
      unless metadata.is_a?(Hash) && metadata.keys.sort == %w[contract_version operation_id] &&
             metadata["operation_id"] == operation_id
        fail_with("CORRUPT_SUCCESSOR_VERSION_AUTHORITY", "invalid authority store metadata")
      end
      unless metadata["contract_version"] == STORE_VERSION
        fail_with("INCOMPATIBLE_SUCCESSOR_VERSION_AUTHORITY", "unsupported authority store contract")
      end

      authorization = parse_json!(directory.join("authorization.json"))
      validate_authorization!(authorization)
      expected = operation_binding(operation)
      actual = authorization.slice("operation", "base_catalog")
      unless IngestOperation.digest(actual) == IngestOperation.digest(expected)
        fail_with("SUCCESSOR_VERSION_AUTHORITY_PROVENANCE_CONFLICT",
                  "authority does not match the operation and frozen base catalog")
      end
      authorization
    end

    def validate_authorization!(authorization)
      unless authorization.is_a?(Hash) && authorization.keys.sort ==
             %w[authorization_id base_catalog contract_version operation selected_at selected_by successor_version]
        fail_with("CORRUPT_SUCCESSOR_VERSION_AUTHORITY", "authority document has an invalid shape")
      end
      unless authorization["contract_version"] == VERSION
        fail_with("INCOMPATIBLE_SUCCESSOR_VERSION_AUTHORITY", "unsupported authority contract")
      end
      operation = authorization["operation"]
      unless operation.is_a?(Hash) && operation.keys.sort == %w[contract_version created_at operation_id] &&
             operation["contract_version"] == IngestOperation::VERSION
        fail_with("CORRUPT_SUCCESSOR_VERSION_AUTHORITY", "authority operation identity is invalid")
      end
      validate_operation_id!(operation["operation_id"])
      validate_timestamp!(operation["created_at"], "operation created_at")
      base = authorization["base_catalog"]
      unless base.is_a?(Hash) && base.keys.sort == %w[bytes sha256] &&
             base["sha256"].is_a?(String) && base["sha256"].match?(/\A[0-9a-f]{64}\z/) &&
             base["bytes"].is_a?(Integer) && base["bytes"].positive?
        fail_with("CORRUPT_SUCCESSOR_VERSION_AUTHORITY", "authority base identity is invalid")
      end
      validate_successor_version!(authorization["successor_version"], corrupt: true)
      validate_text!(authorization["selected_by"], "selected_by", corrupt: true)
      validate_timestamp!(authorization["selected_at"], "selected_at")
      body = authorization.reject { |key, _value| key == "authorization_id" }
      unless authorization["authorization_id"].is_a?(String) &&
             authorization["authorization_id"] == IngestOperation.digest(body)
        fail_with("CORRUPT_SUCCESSOR_VERSION_AUTHORITY", "authority content identity does not match its bytes")
      end
    end

    def operation_binding(operation)
      {
        "operation" => {
          "contract_version" => operation.fetch("contract_version"),
          "operation_id" => operation.fetch("operation_id"),
          "created_at" => operation.fetch("created_at")
        },
        "base_catalog" => operation.fetch("base_catalog").fetch("content").slice("sha256", "bytes")
      }
    end

    def inspection(operation_id, status, authorization: nil, findings: [])
      {
        "contract_version" => INSPECTION_VERSION,
        "operation_id" => operation_id,
        "authority_status" => status,
        "authorization" => authorization,
        "findings" => findings
      }
    end

    def finding(code, message)
      {"code" => code, "message" => message.sub(/\A[^:]+: /, "")}
    end

    def authorization_dir(operation_id)
      root.join(operation_id)
    end

    def lock_path(operation_id)
      root.join(".locks", "#{operation_id}.lock")
    end

    def authority_evidence?(operation_id)
      lock_path(operation_id).exist? || !root.glob(".#{operation_id}.tmp-*").empty?
    end

    def with_lock(operation_id)
      FileUtils.mkdir_p(lock_path(operation_id).dirname)
      File.open(lock_path(operation_id), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def with_existing_lock(operation_id, &block)
      path = lock_path(operation_id)
      return yield unless path.file?

      File.open(path, File::RDONLY) do |lock|
        lock.flock(File::LOCK_SH)
        block.call
      end
    end

    def parse_json!(path)
      JSON.parse(File.binread(path))
    rescue JSON::ParserError, TypeError, SystemCallError => e
      fail_with("CORRUPT_SUCCESSOR_VERSION_AUTHORITY", "could not read authority bytes: #{e.class}")
    end

    def document_bytes(document)
      JSON.pretty_generate(IngestOperation.canonical(document)) + "\n"
    end

    def atomic_write(path, bytes)
      temporary = path.dirname.join(".#{path.basename}.tmp-#{Process.pid}-#{SecureRandom.hex(6)}")
      begin
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.binmode
          file.write(bytes)
          file.flush
          file.fsync
        end
        File.rename(temporary, path)
        fsync_directory(path.dirname)
      ensure
        File.unlink(temporary) if temporary.exist?
      end
    end

    def fsync_directory(directory)
      File.open(directory, File::RDONLY) { |file| file.fsync }
    rescue Errno::EINVAL, Errno::ENOTSUP
      nil
    end

    def validate_operation_id!(value)
      return if value.is_a?(String) && IngestOperationStore::UUID_V4.match?(value)

      fail_with("INVALID_OPERATION_HANDLE", "operation handle must be a lowercase UUIDv4")
    end

    def validate_successor_version!(value, corrupt: false)
      return if value.is_a?(String) && SUCCESSOR_VERSION.match?(value)

      code = corrupt ? "CORRUPT_SUCCESSOR_VERSION_AUTHORITY" : "INVALID_SUCCESSOR_VERSION"
      fail_with(code, "successor version must have two or more dot-separated numeric components")
    end

    def validate_text!(value, label, corrupt: false)
      return if value.is_a?(String) && !value.empty? && value == value.strip && !value.match?(/[[:cntrl:]]/)

      code = corrupt ? "CORRUPT_SUCCESSOR_VERSION_AUTHORITY" : "MISSING_CHOICE"
      fail_with(code, "#{label} must be a non-empty trimmed value")
    end

    def validate_timestamp!(value, label)
      valid = value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/) &&
              Time.iso8601(value).utc.strftime("%Y-%m-%dT%H:%M:%SZ") == value
      fail_with("CORRUPT_SUCCESSOR_VERSION_AUTHORITY", "#{label} is not a UTC timestamp") unless valid
    rescue ArgumentError
      fail_with("CORRUPT_SUCCESSOR_VERSION_AUTHORITY", "#{label} is not a UTC timestamp")
    end

    def fail_with(code, message)
      raise Failure.new(code, message)
    end
  end
end
