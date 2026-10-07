# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "pathname"
require "securerandom"
require "time"
require_relative "adventure_finder_ingest_operation_store"
require_relative "adventure_finder_ingest_routing"

module AdventureFinderWorkspace
  # Human-facing start/resume lifecycle for one durable digital-book ingest.
  class CatalogIngest
    CONTEXT_VERSION = "adventurefinder-catalog-ingest-context/v0.1"
    RECEIPT_VERSION = "pdf-to-llm-md/conversion-receipt/v0.1"
    CONTEXT_ROOTS = IngestOperation::ROOTS.sort.freeze

    class Failure < Error
      attr_reader :code, :status

      def initialize(code, message, status: 1)
        @code = code
        @status = status
        super("#{code}: #{message}")
      end
    end

    attr_reader :front_door_root, :project_root, :out, :env

    def initialize(front_door_root:, project_root:, out: $stdout, env: ENV)
      @front_door_root = Pathname(front_door_root).expand_path
      @project_root = Pathname(project_root).expand_path
      @out = out
      @env = env
    end

    def start(pdf:, base_catalog:, source_declaration:, policy_definition:, policy_id:,
              policy_version:, policy_values:, selected_by:, operation_id: SecureRandom.uuid)
      input = required_file(pdf, "input PDF")
      fail_with("UNSUPPORTED_INPUT", "input must be a .pdf file") unless input.extname.casecmp?(".pdf")
      catalog = required_file(base_catalog, "base catalog")
      policy_path = required_file(policy_definition, "policy definition")
      selected_at = utc_now
      context = build_context(operation_id, input:, catalog:)
      store = store_for(context)
      choices = source_declaration.to_h do |key, value|
        [key, choice(value, selected_by:, selected_at:)]
      end
      policy = {
        "policy_id" => required_text(policy_id, "policy ID"),
        "policy_version" => required_text(policy_version, "policy version"),
        "definition_sha256" => Digest::SHA256.file(policy_path).hexdigest,
        "selected_values" => policy_values,
        "selected_by" => required_text(selected_by, "selected by"),
        "selected_at" => selected_at
      }

      operation = store.create(
        operation_id:,
        created_at: selected_at,
        input_locator: locator(input, Pathname(context.dig("roots", "input")), "input"),
        base_catalog_locator: locator(catalog, Pathname(context.dig("roots", "catalog")), "catalog"),
        catalog_selected_by: selected_by,
        catalog_selected_at: selected_at,
        source_declaration: choices,
        policy:
      )
      write_context!(context)

      out.puts "Started durable catalog ingest"
      out.puts "Operation handle: #{operation_id}"
      out.puts "Input: #{input}"
      out.puts "Base catalog: #{catalog}"
      out.puts

      status, receipt = convert(input, context)
      unless receipt&.file?
        fail_with(
          "CONVERSION_RECEIPT_MISSING",
          "converter did not report a durable conversion receipt; conversion exit status was #{status.exitstatus}",
          status: status.success? ? 1 : status.exitstatus
        )
      end

      current = bind_receipt(store, operation, receipt, context)
      result = routing_for(store, context).compose(current.fetch("operation_id"))
      out.puts
      routing_for(store, context).render(result, out:)
      return status.exitstatus unless status.success?

      result["status"] == "REJECTED" ? 2 : 0
    rescue IngestOperationStore::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    end

    def resume(operation_id)
      context = load_context(operation_id)
      store = store_for(context)
      result = routing_for(store, context).compose(operation_id)
      routing_for(store, context).render(result, out:)
      result["status"] == "REJECTED" ? 2 : 0
    rescue IngestOperationStore::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    end

    private

    def build_context(operation_id, input:, catalog:)
      pipeline_root = Pathname(env.fetch("AF_DATA_PIPELINE_ROOT", project_root.join("af-data-pipeline").to_s)).expand_path
      converter_root = Pathname(
        env.fetch("AF_PDF_CONVERTER_ROOT", project_root.join("pdf-to-llm-md-converter").to_s)
      ).expand_path
      source_root = Pathname(env.fetch("AF_SOURCE_ROOT", project_root.join("md-for-llm-book-content").to_s)).expand_path
      roots = {
        "input" => input.dirname.to_s,
        "front_door" => front_door_root.to_s,
        "pipeline" => pipeline_root.to_s,
        "converter" => converter_root.to_s,
        "source" => source_root.to_s,
        "catalog" => catalog.dirname.to_s
      }
      {
        "contract_version" => CONTEXT_VERSION,
        "operation_id" => operation_id,
        "project_root" => project_root.to_s,
        "front_door_root" => front_door_root.to_s,
        "pipeline_root" => pipeline_root.to_s,
        "source_root" => source_root.to_s,
        "catalog_root" => catalog.dirname.to_s,
        "roots" => roots
      }
    end

    def store_for(context)
      IngestOperationStore.new(
        root: IngestOperationStore.default_root(front_door_root: context.fetch("front_door_root")),
        roots: context.fetch("roots")
      )
    end

    def routing_for(store, context)
      IngestOperationRouting.new(
        store:,
        project_root: context.fetch("project_root"),
        front_door_root: context.fetch("front_door_root"),
        pipeline_root: context.fetch("pipeline_root"),
        source_root: context.fetch("source_root"),
        catalog_root: context.fetch("catalog_root")
      )
    end

    def convert(input, context)
      converter_root = Pathname(context.dig("roots", "converter"))
      converter = converter_root.join("bin", "convert-cached")
      executable!(converter, "cached PDF converter")
      child_env = {
        "AF_PROJECT_ROOT" => context.fetch("project_root"),
        "AF_ADVENTURE_FINDER_ROOT" => context.fetch("front_door_root")
      }
      venv_bin = converter_root.join(".venv", "bin")
      if venv_bin.directory?
        child_env["PATH"] = [venv_bin.to_s, env.fetch("PATH", "")].reject(&:empty?).join(File::PATH_SEPARATOR)
      end

      receipt = nil
      status = nil
      Open3.popen2e(child_env, converter.to_s, input.to_s, "--output-dir", converter_root.join("build").to_s) do |_in, io, wait|
        buffer = +""
        begin
          loop do
            chunk = io.readpartial(4096)
            out.write(chunk)
            out.flush
            buffer << chunk
            while (newline = buffer.index("\n"))
              receipt = receipt_from(buffer.slice!(0..newline)) || receipt
            end
          end
        rescue EOFError
          receipt = receipt_from(buffer) || receipt
        end
        status = wait.value
      end
      [status, receipt]
    end

    def bind_receipt(store, operation, receipt, context)
      root = Pathname(context.dig("roots", "converter"))
      relative = locator(receipt, root, "converter")
      content = File.binread(receipt)
      updated = JSON.parse(JSON.generate(operation))
      updated["revision"] += 1
      updated["previous_revision_sha256"] = IngestOperation.digest(operation)
      updated["artifacts"] << {
        "artifact_id" => "conversion-receipt",
        "kind" => "conversion_receipt",
        "owner" => "pdf-to-llm-md-converter",
        "contract_version" => RECEIPT_VERSION,
        "content" => {
          "sha256" => Digest::SHA256.hexdigest(content),
          "bytes" => content.bytesize,
          "locator" => relative
        },
        "inputs" => ["input"],
        "supersedes" => nil
      }
      updated["coordination"]["status"] = "open"
      updated["coordination"]["route_observation"] = nil
      store.persist!(updated, expected_revision: operation.fetch("revision"),
                     expected_sha256: IngestOperation.digest(operation))
    end

    def context_root
      front_door_root.join("output", "ingest-contexts", "v0.1")
    end

    def context_path(operation_id)
      validate_operation_id!(operation_id)
      context_root.join("#{operation_id}.json")
    end

    def write_context!(context)
      path = context_path(context.fetch("operation_id"))
      fail_with("CONFLICT", "resume context already exists for this operation") if path.exist?

      FileUtils.mkdir_p(path.dirname)
      temporary = path.dirname.join(".#{path.basename}.tmp-#{Process.pid}-#{SecureRandom.hex(6)}")
      begin
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.binmode
          file.write(JSON.pretty_generate(context) + "\n")
          file.flush
          file.fsync
        end
        File.rename(temporary, path)
      ensure
        File.unlink(temporary) if temporary.exist?
      end
    rescue SystemCallError => e
      fail_with("CORRUPT_RESUME_CONTEXT", "could not persist resume context: #{e.class}")
    end

    def load_context(operation_id)
      path = context_path(operation_id)
      fail_with("UNKNOWN_OPERATION", "unknown operation handle #{operation_id}") unless path.file?
      context = JSON.parse(File.binread(path))
      expected = %w[catalog_root contract_version front_door_root operation_id pipeline_root project_root roots source_root]
      unless context.is_a?(Hash) && context.keys.sort == expected &&
             context["contract_version"] == CONTEXT_VERSION && context["operation_id"] == operation_id &&
             context["roots"].is_a?(Hash) && context["roots"].keys.sort == CONTEXT_ROOTS
        fail_with("CORRUPT_RESUME_CONTEXT", "resume context is malformed or incompatible")
      end
      context.fetch("roots").each_value { |value| absolute_path!(value) }
      %w[catalog_root front_door_root pipeline_root project_root source_root].each do |key|
        absolute_path!(context.fetch(key))
      end
      context
    rescue JSON::ParserError, TypeError
      fail_with("CORRUPT_RESUME_CONTEXT", "resume context is malformed or incompatible")
    rescue SystemCallError => e
      fail_with("CORRUPT_RESUME_CONTEXT", "resume context could not be read: #{e.class}")
    end

    def locator(path, root, root_name)
      resolved_root = root.realpath
      resolved_path = Pathname(path).realpath
      relative = resolved_path.relative_path_from(resolved_root).to_s
      if relative == ".." || relative.start_with?("../")
        fail_with("UNSAFE_PATH", "#{resolved_path} is outside configured root #{resolved_root}")
      end
      {"root" => root_name, "path" => relative}
    rescue ArgumentError, Errno::ENOENT
      fail_with("UNSAFE_PATH", "could not resolve a safe portable locator")
    end

    def choice(value, selected_by:, selected_at:)
      {"value" => required_text(value, "source declaration"),
       "selected_by" => required_text(selected_by, "selected by"), "selected_at" => selected_at}
    end

    def receipt_from(line)
      match = line.match(/\AConversion receipt:\s+(.+?)\s*\z/)
      Pathname(match[1]).expand_path if match
    end

    def required_file(path, label)
      value = Pathname(path.to_s).expand_path
      fail_with("MISSING_INPUT", "#{label} does not exist: #{value}") unless value.file?
      value
    end

    def executable!(path, label)
      fail_with("COMPONENT_UNAVAILABLE", "#{label} not found or not executable: #{path}") unless path.file? && path.executable?
    end

    def required_text(value, label)
      unless value.is_a?(String) && !value.empty? && value == value.strip && !value.match?(/[[:cntrl:]]/)
        fail_with("MISSING_CHOICE", "#{label} must be a non-empty trimmed value")
      end
      value
    end

    def absolute_path!(value)
      path = Pathname(value.to_s)
      fail_with("CORRUPT_RESUME_CONTEXT", "resume context contains a non-absolute path") unless path.absolute?
    end

    def validate_operation_id!(value)
      fail_with("INVALID_OPERATION_HANDLE", "operation handle must be a lowercase UUIDv4") unless
        value.is_a?(String) && IngestOperationStore::UUID_V4.match?(value)
    end

    def utc_now
      Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def fail_with(code, message, status: 1)
      raise Failure.new(code, message, status:)
    end
  end

  class CatalogIngestCLI
    REQUIRED_START_OPTIONS = %i[source_id edition pagination_authority publisher base_catalog
                                policy_definition policy_id policy_version policy_values selected_by].freeze

    def self.run(argv, front_door_root:, project_root:, out: $stdout, err: $stderr, env: ENV)
      command = argv.shift
      service = CatalogIngest.new(front_door_root:, project_root:, out:, env:)
      case command
      when "start"
        options = {}
        parser = OptionParser.new do |opts|
          opts.on("--source-id VALUE") { |value| options[:source_id] = value }
          opts.on("--edition VALUE") { |value| options[:edition] = value }
          opts.on("--pagination-authority VALUE") { |value| options[:pagination_authority] = value }
          opts.on("--publisher VALUE") { |value| options[:publisher] = value }
          opts.on("--base-catalog PATH") { |value| options[:base_catalog] = value }
          opts.on("--policy-definition PATH") { |value| options[:policy_definition] = value }
          opts.on("--policy-id VALUE") { |value| options[:policy_id] = value }
          opts.on("--policy-version VALUE") { |value| options[:policy_version] = value }
          opts.on("--policy-values JSON") { |value| options[:policy_values] = parse_policy_values(value) }
          opts.on("--selected-by VALUE") { |value| options[:selected_by] = value }
          opts.on("--operation-id UUID") { |value| options[:operation_id] = value }
        end
        parser.parse!(argv)
        pdf = argv.shift
        missing = REQUIRED_START_OPTIONS.reject { |key| options.key?(key) }
        unless pdf && argv.empty? && missing.empty?
          detail = missing.empty? ? "" : "; missing: #{missing.join(', ')}"
          raise CatalogIngest::Failure.new(
            "MISSING_CHOICE", "usage: bin/af-catalog start INPUT.pdf [required options]#{detail}"
          )
        end
        source = IngestOperation::SOURCE_CHOICES.to_h { |key| [key, options.fetch(key.to_sym)] }
        service.start(pdf:, source_declaration: source, **options.slice(
          :base_catalog, :policy_definition, :policy_id, :policy_version, :policy_values,
          :selected_by, :operation_id
        ))
      when "resume"
        operation_id = argv.shift
        unless operation_id && argv.empty?
          raise CatalogIngest::Failure.new(
            "INVALID_OPERATION_HANDLE", "usage: bin/af-catalog resume OPERATION_ID"
          )
        end
        service.resume(operation_id)
      else
        raise CatalogIngest::Failure.new(
          "USAGE", "usage: bin/af-catalog {start INPUT.pdf [required options] | resume OPERATION_ID}"
        )
      end
    rescue OptionParser::ParseError => e
      err.puts "af-catalog: USAGE: #{e.message}"
      1
    rescue CatalogIngest::Failure => e
      err.puts "af-catalog: #{e.message}"
      e.status
    end

    def self.parse_policy_values(value)
      parsed = JSON.parse(value)
      raise CatalogIngest::Failure.new("MISSING_CHOICE", "policy values must be a non-empty JSON object") unless
        parsed.is_a?(Hash) && !parsed.empty?

      parsed
    rescue JSON::ParserError
      raise CatalogIngest::Failure.new("MISSING_CHOICE", "policy values must be valid JSON")
    end
    private_class_method :parse_policy_values
  end
end
