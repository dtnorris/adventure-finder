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
require_relative "adventure_finder_ingest_source_driver"
require_relative "adventure_finder_local_capability_plan"
require_relative "adventure_finder_local_execution"
require_relative "adventure_finder_staged_scoring_intent"
require_relative "adventure_finder_staged_workload_preparation"
require_relative "adventure_finder_successor_version_authorization"

module AdventureFinderWorkspace
  # Human-facing start/resume lifecycle for one durable digital-book ingest.
  class CatalogIngest
    CONTEXT_VERSION = "adventurefinder-catalog-ingest-context/v0.1"
    SOURCE_CONTEXT_VERSION = "adventurefinder-catalog-ingest-context/v0.2"
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
              policy_version:, policy_values:, selected_by:, operation_id: SecureRandom.uuid,
              canonical_destination: nil, scoring_choice: nil)
      input = required_file(pdf, "input PDF")
      fail_with("UNSUPPORTED_INPUT", "input must be a .pdf file") unless input.extname.casecmp?(".pdf")
      catalog = required_file(base_catalog, "base catalog")
      policy_path = required_file(policy_definition, "policy definition")
      selected_at = utc_now
      context = build_context(operation_id, input:, catalog:, canonical_destination:)
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
      capture_scoring_choice!(context, store, operation_id, scoring_choice,
                              selected_by:, interaction: "ingest_start") if scoring_choice

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
      result = continue_or_route(store, context, current.fetch("operation_id"))
      out.puts
      routing_for(store, context).render(result, out:)
      return status.exitstatus unless status.success?

      result["status"] == "REJECTED" ? 2 : 0
    rescue IngestOperationStore::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    end

    def resume(operation_id, scoring_choice: nil, selected_by: nil)
      context = load_context(operation_id)
      store = store_for(context)
      capture_scoring_choice!(context, store, operation_id, scoring_choice,
                              selected_by:, interaction: "post_boundary_resume") if scoring_choice
      result = continue_or_route(store, context, operation_id)
      routing_for(store, context).render(result, out:)
      result["status"] == "REJECTED" ? 2 : 0
    rescue IngestOperationStore::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    end

    def prepare_workload(operation_id, freeze_path:, approval_path:, bundle_dir:,
                         historical_project_state_path:, current_project_state_path: nil)
      context = load_context(operation_id)
      store = store_for(context)
      routing = routing_for(store, context)
      intent_store = scoring_intent_store_for(context, store)
      result = StagedWorkloadPreparation.new(
        front_door_root: context.fetch("front_door_root"),
        project_root: context.fetch("project_root"),
        pipeline_root: context.fetch("pipeline_root"),
        afw_root: env["AF_AFW_ROOT"] || Pathname(context.fetch("project_root")).join("af-workloads"),
        scorer_root: env["AF_SCORER_ROOT"] || Pathname(context.fetch("project_root")).join("af-cli-scoring-utility"),
        source_root: context.fetch("source_root"),
        catalog_root: context.fetch("catalog_root"),
        operation_store: store,
        intent_store:,
        authorization_store: authority_store_for(context, store),
        routing:
      ).prepare(
        operation_id:, freeze_path:, approval_path:, bundle_dir:,
        historical_project_state_path:, current_project_state_path:
      )
      render_workload_result(result)
      0
    rescue IngestOperationStore::Failure, StagedScoringIntentStore::Failure,
           StagedWorkloadPreparation::Failure, SuccessorVersionAuthorizationStore::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    end

    def plan_local_capabilities(operation_id)
      context = load_context(operation_id)
      planner = LocalCapabilityPlan.new(
        front_door_root: context.fetch("front_door_root"),
        project_root: context.fetch("project_root"),
        env:
      )
      out.write(planner.bytes(operation_id:))
      0
    rescue LocalCapabilityPlan::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    end

    def local_start(operation_id, selected_by:)
      context = load_context(operation_id)
      plan = local_capability_plan(context, operation_id)
      local_execution(context).start(operation_id:, selected_by:, capability_plan: plan)
    rescue LocalCapabilityPlan::Failure, LocalExecution::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    end

    def local_resume(operation_id, continue_operator_pause: false)
      context = load_context(operation_id)
      plan = local_capability_plan(context, operation_id)
      local_execution(context).resume(operation_id:, capability_plan: plan, continue_operator_pause:)
    rescue LocalCapabilityPlan::Failure, LocalExecution::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    end

    def local_status(operation_id)
      context = load_context(operation_id)
      plan = local_capability_plan(context, operation_id)
      local_execution(context).status(operation_id:, capability_plan: plan)
    rescue LocalCapabilityPlan::Failure, LocalExecution::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    end

    def bind_successor_version(operation_id, successor_version:, selected_by:)
      context = load_context(operation_id)
      store = store_for(context)
      authorization = authority_store_for(context, store).bind!(
        operation_id:, successor_version:, selected_by:
      )
      out.puts "Bound successor-version authority"
      out.puts "Operation handle: #{operation_id}"
      out.puts "Successor version: #{authorization.fetch('successor_version')}"
      out.puts "Authorization: #{authorization.fetch('authorization_id')}"
      0
    rescue IngestOperationStore::Failure, SuccessorVersionAuthorizationStore::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    end

    def successor_version_authority(operation_id)
      context = load_context(operation_id)
      store = store_for(context)
      out.puts JSON.pretty_generate(authority_store_for(context, store).projection(operation_id))
      0
    rescue IngestOperationStore::Failure, SuccessorVersionAuthorizationStore::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    end

    private

    def local_capability_plan(context, operation_id)
      LocalCapabilityPlan.new(
        front_door_root: context.fetch("front_door_root"),
        project_root: context.fetch("project_root"),
        env:
      ).call(operation_id:)
    end

    def local_execution(context)
      LocalExecution.new(
        front_door_root: context.fetch("front_door_root"),
        project_root: context.fetch("project_root"), out:, env:
      )
    end

    def build_context(operation_id, input:, catalog:, canonical_destination:)
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
      context = {
        "contract_version" => canonical_destination ? SOURCE_CONTEXT_VERSION : CONTEXT_VERSION,
        "operation_id" => operation_id,
        "project_root" => project_root.to_s,
        "front_door_root" => front_door_root.to_s,
        "pipeline_root" => pipeline_root.to_s,
        "source_root" => source_root.to_s,
        "catalog_root" => catalog.dirname.to_s,
        "roots" => roots
      }
      if canonical_destination
        context["source_progression"] = {
          "canonical_destination" => destination_locator(
            canonical_destination, Pathname(source_root), "source"
          )
        }
      end
      context
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

    def continue_or_route(store, context, operation_id)
      routing = routing_for(store, context)
      progression = context["source_progression"]
      return routing.compose(operation_id) unless progression

      driver = IngestSourceDriver.new(
        store:,
        routing:,
        project_root: context.fetch("project_root"),
        front_door_root: context.fetch("front_door_root"),
        pipeline_root: context.fetch("pipeline_root"),
        source_root: context.fetch("source_root"),
        catalog_root: context.fetch("catalog_root")
      )
      driver.drive(
        operation_id,
        canonical_destination: resolve_destination(
          progression.fetch("canonical_destination"),
          Pathname(context.fetch("source_root"))
        )
      )
    end

    def authority_store_for(context, store)
      SuccessorVersionAuthorizationStore.new(
        root: SuccessorVersionAuthorizationStore.default_root(
          front_door_root: context.fetch("front_door_root")
        ),
        operation_store: store
      )
    end

    def scoring_intent_store_for(context, store)
      StagedScoringIntentStore.new(
        root: StagedScoringIntentStore.default_root(front_door_root: context.fetch("front_door_root")),
        operation_store: store,
        policy_path: Pathname(context.fetch("pipeline_root")).join(
          "config", "staged_scoring_input_policy_v0.1.json"
        )
      )
    end

    def capture_scoring_choice!(context, store, operation_id, choice, selected_by:, interaction:)
      scoring_intent_store_for(context, store).capture!(
        operation_id:, choice:, selected_by: required_text(selected_by, "scoring choice selected by"), interaction:
      )
    end

    def render_workload_result(result)
      out.puts "Staged scoring workload: #{result.fetch('status')}"
      out.puts "Operation: #{result.fetch('operation_id')}"
      out.puts "Workload: #{result.fetch('workload_id')}"
      out.puts "Qualified cases / metric denominator: #{result.fetch('qualified_cases')} / #{result.fetch('metric_denominator')}"
      result.fetch("selected").each do |entry|
        out.puts "Selected: #{entry.fetch('adventure_id')} (#{entry.fetch('case_count')} cases)"
      end
      result.fetch("deferred").each do |entry|
        label = entry["adventure_id"] || "no new record"
        out.puts "Deferred: #{label} — #{render_workload_reason(entry.fetch('reason'))}"
      end
      result.fetch("refused", []).each do |entry|
        out.puts "Refused: #{entry.fetch('adventure_id')} — #{render_workload_reason(entry.fetch('reason'))}"
      end
      out.puts "Owner decision: #{result.dig('decision', 'code')}"
      if result["inspection"]
        out.puts "AFW inspection: #{result.dig('inspection', 'action')} (#{result.dig('inspection', 'reason_code')})"
      end
      out.puts "Execution authorized: no"
      out.puts "Catalog adoption authorized: no"
      out.puts "Next inspection: #{result.fetch('next_action')}" if result["next_action"]
    end

    def render_workload_reason(reason)
      return reason unless reason.is_a?(Hash)

      [reason["code"], reason["detail"]].compact.join(": ")
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
      base_keys = %w[catalog_root contract_version front_door_root operation_id pipeline_root project_root roots source_root]
      valid_keys = if context.is_a?(Hash) && context["contract_version"] == SOURCE_CONTEXT_VERSION
                     context.keys.sort == (base_keys + %w[source_progression]).sort &&
                       valid_source_progression?(context["source_progression"])
                   else
                     context.is_a?(Hash) && context.keys.sort == base_keys &&
                       context["contract_version"] == CONTEXT_VERSION
                   end
      unless valid_keys && context["operation_id"] == operation_id &&
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

    def destination_locator(path, root, root_name)
      resolved_root = root.realpath
      destination = Pathname(path.to_s).expand_path
      fail_with("MISSING_CHOICE", "canonical destination must end in .md") unless
        destination.extname.casecmp?(".md")
      relative = destination.relative_path_from(root).to_s
      if relative == ".." || relative.start_with?("../") ||
         relative.include?("\\") || relative.include?(":") ||
         relative.match?(/[[:cntrl:]]/) ||
         relative.split("/", -1).any? { |part| ["", ".", ".."].include?(part) }
        fail_with("UNSAFE_PATH", "canonical destination is outside configured source root")
      end
      ancestor = destination
      ancestor = ancestor.parent until ancestor.exist? || ancestor.symlink?
      unless ancestor.realpath == resolved_root ||
             ancestor.realpath.to_s.start_with?(resolved_root.to_s + File::SEPARATOR)
        fail_with("UNSAFE_PATH", "canonical destination escapes configured source root")
      end
      {"root" => root_name, "path" => relative}
    rescue ArgumentError, Errno::ENOENT
      fail_with("UNSAFE_PATH", "could not resolve a safe canonical destination")
    end

    def resolve_destination(locator, root)
      unless locator.is_a?(Hash) && locator.keys.sort == %w[path root] &&
             locator["root"] == "source"
        fail_with("CORRUPT_RESUME_CONTEXT", "resume context has an invalid canonical destination")
      end
      destination_locator(root.join(locator.fetch("path")), root, "source")
      root.join(locator.fetch("path")).cleanpath
    end

    def valid_source_progression?(value)
      value.is_a?(Hash) && value.keys == %w[canonical_destination] &&
        value["canonical_destination"].is_a?(Hash) &&
        value["canonical_destination"].keys.sort == %w[path root]
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
          opts.on("--canonical-destination FILE") { |value| options[:canonical_destination] = value }
          opts.on("--prepare-staged-scoring") { select_scoring_choice!(options, "prepare") }
          opts.on("--decline-staged-scoring") { select_scoring_choice!(options, "decline") }
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
          :selected_by, :operation_id, :canonical_destination, :scoring_choice
        ))
      when "resume"
        options = {}
        parser = OptionParser.new do |opts|
          opts.on("--prepare-staged-scoring") { select_scoring_choice!(options, "prepare") }
          opts.on("--decline-staged-scoring") { select_scoring_choice!(options, "decline") }
          opts.on("--selected-by VALUE") { |value| options[:selected_by] = value }
        end
        parser.parse!(argv)
        operation_id = argv.shift
        valid_choice = !options.key?(:scoring_choice) || options[:selected_by]
        valid_selector = options.key?(:scoring_choice) || !options.key?(:selected_by)
        unless operation_id && argv.empty? && valid_choice && valid_selector
          raise CatalogIngest::Failure.new(
            "INVALID_OPERATION_HANDLE",
            "usage: bin/af-catalog resume OPERATION_ID " \
            "[--prepare-staged-scoring|--decline-staged-scoring --selected-by VALUE]"
          )
        end
        service.resume(operation_id, **options)
      when "prepare-workload"
        options = {}
        parser = OptionParser.new do |opts|
          opts.on("--freeze PATH") { |value| options[:freeze_path] = value }
          opts.on("--approval PATH") { |value| options[:approval_path] = value }
          opts.on("--editorial-bundle DIR") { |value| options[:bundle_dir] = value }
          opts.on("--historical-project-state PATH") { |value| options[:historical_project_state_path] = value }
          opts.on("--current-project-state PATH") { |value| options[:current_project_state_path] = value }
        end
        parser.parse!(argv)
        operation_id = argv.shift
        required = %i[freeze_path approval_path bundle_dir historical_project_state_path]
        missing = required.reject { |key| options.key?(key) }
        unless operation_id && argv.empty? && missing.empty?
          raise CatalogIngest::Failure.new(
            "MISSING_CHOICE",
            "usage: bin/af-catalog prepare-workload OPERATION_ID --freeze PATH --approval PATH " \
            "--editorial-bundle DIR --historical-project-state PATH"
          )
        end
        service.prepare_workload(operation_id, **options)
      when "plan-local-capabilities"
        json = false
        parser = OptionParser.new { |opts| opts.on("--json") { json = true } }
        parser.parse!(argv)
        operation_id = argv.shift
        unless operation_id && argv.empty? && json
          raise CatalogIngest::Failure.new(
            "USAGE", "usage: bin/af-catalog plan-local-capabilities OPERATION_ID --json"
          )
        end
        service.plan_local_capabilities(operation_id)
      when "local-start"
        options = {}
        OptionParser.new do |opts|
          opts.on("--selected-by VALUE") { |value| options[:selected_by] = value }
        end.parse!(argv)
        operation_id = argv.shift
        unless operation_id && argv.empty? && options[:selected_by]
          raise CatalogIngest::Failure.new(
            "MISSING_CHOICE", "usage: bin/af-catalog local-start OPERATION_ID --selected-by VALUE"
          )
        end
        service.local_start(operation_id, **options)
      when "local-resume"
        options = {continue_operator_pause: false}
        OptionParser.new do |opts|
          opts.on("--continue-operator-pause") { options[:continue_operator_pause] = true }
        end.parse!(argv)
        operation_id = argv.shift
        unless operation_id && argv.empty?
          raise CatalogIngest::Failure.new(
            "INVALID_OPERATION_HANDLE",
            "usage: bin/af-catalog local-resume OPERATION_ID [--continue-operator-pause]"
          )
        end
        service.local_resume(operation_id, **options)
      when "local-status"
        operation_id = argv.shift
        unless operation_id && argv.empty?
          raise CatalogIngest::Failure.new(
            "INVALID_OPERATION_HANDLE", "usage: bin/af-catalog local-status OPERATION_ID"
          )
        end
        service.local_status(operation_id)
      when "bind-successor-version"
        options = {}
        parser = OptionParser.new do |opts|
          opts.on("--successor-version VERSION") { |value| options[:successor_version] = value }
          opts.on("--selected-by VALUE") { |value| options[:selected_by] = value }
        end
        parser.parse!(argv)
        operation_id = argv.shift
        unless operation_id && argv.empty? && options.keys.sort == %i[selected_by successor_version]
          raise CatalogIngest::Failure.new(
            "MISSING_CHOICE",
            "usage: bin/af-catalog bind-successor-version OPERATION_ID " \
            "--successor-version VERSION --selected-by VALUE"
          )
        end
        service.bind_successor_version(operation_id, **options)
      when "successor-version-authority"
        json = false
        parser = OptionParser.new { |opts| opts.on("--json") { json = true } }
        parser.parse!(argv)
        operation_id = argv.shift
        unless operation_id && argv.empty? && json
          raise CatalogIngest::Failure.new(
            "USAGE", "usage: bin/af-catalog successor-version-authority OPERATION_ID --json"
          )
        end
        service.successor_version_authority(operation_id)
      else
        raise CatalogIngest::Failure.new(
          "USAGE", "usage: bin/af-catalog {start | resume | bind-successor-version | " \
                   "successor-version-authority | prepare-workload | plan-local-capabilities | " \
                   "local-start | local-resume | local-status} ..."
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

    def self.select_scoring_choice!(options, choice)
      if options.key?(:scoring_choice) && options[:scoring_choice] != choice
        raise CatalogIngest::Failure.new(
          "INVALID_SCORING_CHOICE", "choose exactly one staged-scoring disposition"
        )
      end
      options[:scoring_choice] = choice
    end
    private_class_method :select_scoring_choice!
  end
end
