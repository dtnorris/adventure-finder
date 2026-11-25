# frozen_string_literal: true

require_relative "adventure_finder_state_paths"
require_relative "adventure_finder_workload_paths"

require "csv"
require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "securerandom"
require "shellwords"
require "stringio"
require "yaml"
require_relative "adventure_finder_ingest_operation"
require_relative "adventure_finder_ingest_routing"
require_relative "adventure_finder_staged_scoring_intent"
require_relative "adventure_finder_successor_version_authorization"

module AdventureFinderWorkspace
  # Loads and composes AFW's public staged-selection and workload-inspection
  # contracts. AdventureFinder branches only on AFW's versioned owner results;
  # qualification, immutable-workload validation and deterministic regeneration
  # remain AFW responsibilities.
  class AFWStagedWorkloadCoordinator
    SELECTION_VERSION = "afw-staged-selection/v0.1"
    INSPECTION_VERSION = "afw-workload-inspection/v0.1"

    class Failure < Error; end

    # Bind producer code, optional split storage and pipeline authority inputs.
    # Invalid modes raise ArgumentError. Injected contracts support unit tests.
    def initialize(afw_root:, scorer_root:, pipeline_root:, authority_inputs_path:,
                   authority_store:, current_project_state_path:, scorer_config: nil, mode: "production", contracts: nil,
                   afw_data_root: nil)
      @afw_root = Pathname(afw_root).expand_path
      @afw_data_root = afw_data_root && Pathname(afw_data_root).expand_path
      @scorer_root = Pathname(scorer_root).expand_path
      @scorer_config = scorer_config && Pathname(scorer_config).expand_path
      @pipeline_root = Pathname(pipeline_root).expand_path
      @authority_inputs_path = Pathname(authority_inputs_path).expand_path
      @authority_store = Pathname(authority_store).expand_path
      @current_project_state_path = Pathname(current_project_state_path).expand_path
      @mode = mode.to_s
      @contracts = contracts
      raise ArgumentError, "mode must be production or synthetic" unless %w[production synthetic].include?(@mode)
    end

    def prepare(operation_id:, workload_id:, catalog_path:)
      load_contracts!
      staged = staged_input(operation_id)
      authority = staged.authority!(catalog_path: catalog_path.to_s)
      raise Failure, "pipeline returned zero allocation after issuing nonzero authority" unless authority

      selector = contract(:selection).new(root: @afw_root.to_s, scorer_repo: @scorer_root.to_s,
                                           **data_options, **scorer_config_options)
      selection, selection_path = selector.select!(authority:, catalog_path: catalog_path.to_s)
      validate_selection_identity!(selection, operation_id, workload_id, authority)
      result = {"status" => selection.fetch("status"), "selection" => selection,
                "inspection" => nil, "manifest" => nil, "refusal" => nil}
      return result unless selection["status"] == "SELECTED"

      staged.use_selection!(path: selection_path, scorer_repo: @scorer_root.to_s, **scorer_config_options)
      inspection = inspect_workload(staged, selection, catalog_path)
      result["inspection"] = inspection
      case inspection.fetch("action")
      when "fresh-build"
        prepared = selector.prepare!(
          staged_scoring: staged, catalog_path: catalog_path.to_s,
          required_context_length: StagedWorkloadPreparation::REQUIRED_CONTEXT_LENGTH,
          require_fully_gpu_resident: true, out: StringIO.new
        )
        if prepared.fetch("status") == "REFUSED"
          return result.merge("status" => "REFUSED", "refusal" => prepared)
        end
      when "regenerate"
        compile(staged, selection, catalog_path)
      when "reuse"
        # The inspector already replayed the complete producer validation.
      when "refuse"
        return result.merge("status" => "REFUSED")
      else
        raise Failure, "unsupported AFW inspection action: #{inspection.fetch('action').inspect}"
      end

      final = inspect_workload(staged, selection, catalog_path)
      unless final["contract_version"] == INSPECTION_VERSION && final["action"] == "reuse"
        return result.merge("status" => "REFUSED", "inspection" => final)
      end
      result.merge(
        "status" => "PREPARED", "inspection" => final,
        "manifest" => (@afw_data_root || @afw_root).join("workloads", workload_id).to_s
      )
    rescue Failure
      raise
    rescue StandardError => e
      raise unless contract_error?(e)

      raise Failure, e.message
    end

    private

    def load_contracts!
      unless @contracts
        path = @afw_root.join("lib", "af_workloads.rb")
        raise Failure, "AFW public library is unavailable: #{path}" unless path.file?
        require path.to_s
        required = %i[Error StagedScoringInput StagedSelection FrozenWorkloadValidator WorkloadInspector WorkloadCompiler]
        missing = required.reject { |name| AFWorkloads.const_defined?(name, false) }
        raise Failure, "AFW public contracts are incomplete: #{missing.join(', ')}" unless missing.empty?
        @contracts = {
          error: AFWorkloads::Error, staged_input: AFWorkloads::StagedScoringInput,
          selection: AFWorkloads::StagedSelection, validator: AFWorkloads::FrozenWorkloadValidator,
          inspector: AFWorkloads::WorkloadInspector, compiler: AFWorkloads::WorkloadCompiler
        }
      end
      unless contract(:selection).const_get(:VERSION) == SELECTION_VERSION &&
             contract(:inspector).const_get(:CONTRACT_VERSION) == INSPECTION_VERSION
        raise Failure, "AFW staged-selection or workload-inspection contract version changed"
      end
    end

    # Forward one optional explicit config to selection, compilation and inspection.
    # AFW validates the roots-only contract and binds the selected bytes.
    def scorer_config_options
      @scorer_config ? {scorer_config: @scorer_config.to_s} : {}
    end

    # Returns the split owner argument when the selected producer supports it.
    def data_options
      @afw_data_root ? {data_root: @afw_data_root.to_s} : {}
    end

    def staged_input(operation_id)
      contract(:staged_input).new(
        root: (@afw_data_root || @afw_root).to_s,
        config: {
          pipeline_root: @pipeline_root.to_s,
          inputs_path: @authority_inputs_path.to_s,
          store_root: @authority_store.to_s,
          project_state_path: @current_project_state_path.to_s,
          operation_id:, mode: @mode
        }
      )
    end

    def inspect_workload(staged, selection, catalog_path)
      validator = contract(:validator).new(
        root: @afw_root.to_s, workload_id: selection.fetch("workload_id"),
        catalog_path: catalog_path.to_s, ids: selection.fetch("selected_ids"),
        scorer_repo: @scorer_root.to_s, **data_options, **scorer_config_options,
        required_context_length: StagedWorkloadPreparation::REQUIRED_CONTEXT_LENGTH,
        require_fully_gpu_resident: true, staged_scoring: staged
      )
      contract(:inspector).new(
        root: (@afw_data_root || @afw_root).to_s, workload_id: selection.fetch("workload_id"), validator:
      ).inspect
    end

    def compile(staged, selection, catalog_path)
      contract(:compiler).new(
        root: @afw_root.to_s, workload_id: selection.fetch("workload_id"),
        catalog_path: catalog_path.to_s, ids: selection.fetch("selected_ids"),
        scorer_repo: @scorer_root.to_s, **data_options, **scorer_config_options,
        required_context_length: StagedWorkloadPreparation::REQUIRED_CONTEXT_LENGTH,
        require_fully_gpu_resident: true, staged_scoring: staged, out: StringIO.new
      ).build
    end

    def validate_selection_identity!(selection, operation_id, workload_id, authority)
      allocation = authority.fetch("allocation")
      dispositions = selection.fetch("dispositions")
      valid = selection["schema_version"] == SELECTION_VERSION &&
              selection["producer"] == "af-workloads" &&
              %w[SELECTED ALL_DEFERRED REFUSED].include?(selection["status"]) &&
              selection["authority_id"] == authority.fetch("authority_id") &&
              selection.dig("operation", "operation_id") == operation_id &&
              selection["workload_id"] == workload_id &&
              selection["allocation"] == allocation &&
              dispositions.map { |row| row["adventure_id"] } == allocation.map { |row| row["adventure_id"] }
      raise Failure, "AFW selection identity/allocation differs from pipeline authority" unless valid
    rescue KeyError, TypeError => e
      raise Failure, "AFW selection is malformed: #{e.message}"
    end

    def contract(name)
      @contracts.fetch(name)
    end

    def contract_error?(error)
      @contracts && @contracts[:error] && error.is_a?(@contracts.fetch(:error))
    end
  end

  # Coordinates pipeline authority issuance and one zero-inference AFW build.
  # It owns neither qualification policy nor execution. All model, dimension,
  # profile and runtime selection stays inside AFW's public compiler.
  class StagedWorkloadPreparation
    RESULT_VERSION = "adventurefinder-staged-workload-preparation/v0.2"
    LOCATOR_VERSION = "af-staged-scoring-evidence-locators/v0.1"
    AUTHORITY_PROJECTION_VERSION = "af-staged-scoring-authority-projection/v0.1"
    AUTHORITY_VERSION = "af-staged-scoring-authority/v0.1"
    PLAN_VERSION = "wlo-execution-plan/v0.3"
    REQUIRED_CONTEXT_LENGTH = 131_072
    AUTHORITY_KEYS = %w[
      schema_version issuer mode operation intent permissions base_amc staged_amc
      approval_id allocation protected_ids evidence authority_id
    ].freeze
    AUTHORITY_PERMISSIONS = %w[scoring_input workload_preparation].freeze

    class Failure < Error
      attr_reader :code

      def initialize(code, message)
        @code = code
        super("#{code}: #{message}")
      end
    end

    class CommandRunner
      Result = Struct.new(:stdout, :stderr, :status, keyword_init: true)

      def capture(environment, *argv, chdir:)
        stdout, stderr, status = Open3.capture3(environment, *argv, chdir:)
        Result.new(stdout:, stderr:, status:)
      end
    end

    attr_reader :front_door_root, :project_root, :pipeline_root, :afw_root,
                :scorer_root, :source_root, :catalog_root, :operation_store,
                :intent_store, :authorization_store, :routing, :runner

    def initialize(front_door_root:, project_root:, pipeline_root:, afw_root:, scorer_root:,
                   source_root:, catalog_root:, operation_store:, intent_store:,
                   authorization_store:, routing:, runner: CommandRunner.new,
                   afw_coordinator: nil, env: ENV)
      @front_door_root = Pathname(front_door_root).expand_path
      @project_root = Pathname(project_root).expand_path
      @pipeline_root = Pathname(pipeline_root).expand_path
      @afw_root = afw_root
      @scorer_root = scorer_root && Pathname(scorer_root).expand_path
      @scorer_override = @scorer_root
      @source_root = Pathname(source_root).expand_path
      @catalog_root = Pathname(catalog_root).expand_path
      @operation_store = operation_store
      @intent_store = intent_store
      @authorization_store = authorization_store
      @routing = routing
      @runner = runner
      @afw_coordinator = afw_coordinator
      @scorer_config = env["AF_SCORER_CONFIG"] && File.expand_path(env.fetch("AF_SCORER_CONFIG"))
      @env = env
    end

    def prepare(operation_id:, freeze_path:, approval_path:, bundle_dir:,
                historical_project_state_path:, current_project_state_path: nil)
      operation = operation_store.validate!(operation_id)
      require_editorial_lineage!(operation)
      intent = intent_store.intent!(operation_id)
      select_workload_paths! unless @afw_coordinator
      paths = evidence_paths(
        operation_id:, freeze_path:, approval_path:, bundle_dir:,
        historical_project_state_path:,
        current_project_state_path: current_project_state_path || catalog_root.join("PROJECT_STATE.yml")
      )
      documents = preparation_documents(operation_id, paths, intent)
      action = persist_preparation_inputs!(operation_id, documents, intent.fetch("workload_id"))
      projection = issue_authority!(operation_id, paths.fetch(:current_project_state_path), action:)
      if projection["status"] == "NO_SUCCESSOR_NEEDED"
        result = zero_result(operation_id, intent, projection)
        persist_result!(operation_id, result)
        return result
      end

      authority = validate_authority_projection!(projection, operation_id, intent)
      ids = authority.fetch("allocation").map { |record| record.fetch("adventure_id") }
      fail_with("INVALID_AUTHORITY", "authority contains duplicate or malformed Adventure IDs") unless
        !ids.empty? && ids.uniq == ids && ids.all? { |id| id.match?(/\AADV-\d{4}\z/) }
      staged_catalog = catalog_root.join(authority.dig("staged_amc", "filename"))
      validate_staged_catalog!(staged_catalog, authority.fetch("staged_amc"))

      owner = (@afw_coordinator || default_afw_coordinator(operation_id, paths))
      owner_result = owner.prepare(
        operation_id:, workload_id: intent.fetch("workload_id"), catalog_path: staged_catalog
      )
      result = compose_result(
        operation_id, intent, authority, owner_result,
        current_state_path: paths.fetch(:current_project_state_path)
      )
      persist_result!(operation_id, result)
      result
    rescue IngestOperationStore::Failure, StagedScoringIntentStore::Failure,
           SuccessorVersionAuthorizationStore::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    rescue AFWStagedWorkloadCoordinator::Failure => e
      fail_with("AFW_PREPARATION_REFUSED", e.message)
    rescue Psych::Exception, JSON::ParserError, CSV::MalformedCSVError, KeyError, TypeError => e
      fail_with("INVALID_PREPARATION_OUTPUT", e.message)
    end

    private

    # Admit the configured producer and output stores before persisting inputs.
    # Invalid splits raise the front door's AFW refusal.
    def select_workload_paths!
      @workload_paths = WorkloadPaths.new(code: afw_root.to_s, data: @env["AF_AFW_DATA_ROOT"],
                                         explicit_code: @env.key?("AF_AFW_ROOT"))
      @afw_root = @workload_paths.code
      library = afw_root.join("lib", "af_workloads.rb")
      raise Error, "AFW public library is unavailable: #{library}" unless library.file?
      @scorer_root = WorkloadPaths.scorer_root!(project_root, override: @scorer_override)
      return unless @workload_paths.data

      @workload_paths.check_scorer!(scorer_root, @scorer_config)
      owners = [front_door_root, pipeline_root, source_root, catalog_root, scorer_root]
      owners << Pathname(@env.fetch("AF_DATA_PIPELINE_DATA_ROOT")) if @env.key?("AF_DATA_PIPELINE_DATA_ROOT")
      owners.each do |owner|
        path = owner.realpath
        data = @workload_paths.data
        if PipelineDataPaths.contained?(data, path) || PipelineDataPaths.contained?(path, data)
          raise Error, "AF_AFW_DATA_ROOT overlaps a selected owner root: #{path}"
        end
      end
    rescue Error, SystemCallError => error
      fail_with("AFW_PREPARATION_REFUSED", error.message)
    end

    def evidence_paths(operation_id:, freeze_path:, approval_path:, bundle_dir:,
                       historical_project_state_path:, current_project_state_path:)
      paths = {
        freeze_path: required_file(freeze_path, "boundary freeze"),
        approval_path: required_file(approval_path, "editorial approval"),
        bundle_dir: required_directory(bundle_dir, "editorial bundle"),
        historical_project_state_path: required_file(
          historical_project_state_path, "retained historical project state"
        ),
        current_project_state_path: required_file(current_project_state_path, "current project state")
      }
      dossier = operation_store.validate!(operation_id).fetch("artifacts").reverse.find do |artifact|
        artifact["kind"] == "boundary_dossier"
      end
      fail_with("MISSING_BOUNDARY_DOSSIER", "operation has no bound boundary dossier") unless dossier
      paths[:dossier_path] = Pathname(operation_store.binding_path(operation_id, dossier.fetch("artifact_id")))
      paths
    end

    def preparation_documents(operation_id, paths, intent)
      prepared = routing.boundary_freeze_input(operation_id, freeze_path: paths.fetch(:freeze_path))
      if prepared.is_a?(Hash)
        code = prepared.dig("diagnostic", "code") || "INVALID_OPERATION_INPUT"
        message = prepared.dig("diagnostic", "message") || "could not project the boundary freeze"
        fail_with(code, message)
      end
      operation_input = prepared.projection
      successor = authorization_store.projection(operation_id)
      envelope = {
        "schema_version" => LOCATOR_VERSION,
        "evidence" => {
          "freeze_path" => paths.fetch(:freeze_path).to_s,
          "operation_input_path" => preparation_dir(operation_id).join("operation-input.json").to_s,
          "successor_authorization_path" => preparation_dir(operation_id).join("successor-authorization.json").to_s,
          "source_root" => source_root.to_s,
          "catalog_root" => catalog_root.to_s,
          "project_state_path" => paths.fetch(:historical_project_state_path).to_s,
          "approval_path" => paths.fetch(:approval_path).to_s,
          "bundle_dir" => paths.fetch(:bundle_dir).to_s,
          "dossier_path" => paths.fetch(:dossier_path).to_s,
          "intent_path" => intent_store.intent_path(operation_id).to_s,
          "policy_path" => intent_store.policy_path.to_s
        }
      }
      {"operation-input.json" => operation_input,
       "successor-authorization.json" => successor,
       "authority-inputs.json" => envelope,
       "authority-store.json" => {"operation_id" => operation_id, "store_root" => authority_root.to_s},
       "afw-roots.json" => @workload_paths&.binding,
       "intent_id" => intent.fetch("intent_id")}
    end

    # Retains exact preparation inputs and the selected owner store. Returns
    # "issue" only for a new preparation, otherwise "validate"; missing or
    # changed retained bindings raise Failure rather than regenerating authority.
    def persist_preparation_inputs!(operation_id, documents, workload_id)
      destination = preparation_dir(operation_id)
      FileUtils.mkdir_p(preparation_root)
      File.open(preparation_lock(operation_id), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        if destination.directory?
          begin
            @workload_paths&.verify_binding!(destination.join("afw-roots.json"))
            result_path = destination.join("result.json")
            if @workload_paths && !@workload_paths.data && result_path.file?
              recorded_plan = read_json(result_path).dig("plan", "path")
              expected_plan = @workload_paths.store.join("workloads", workload_id, "execution-plan.json")
              if recorded_plan && File.expand_path(recorded_plan) != expected_plan.to_s
                raise Error, "historical preparation requires the original AFW checkout: #{recorded_plan}"
              end
            end
          rescue Error => error
            fail_with("PREPARATION_CONFLICT", error.message)
          end
          documents.slice("operation-input.json", "successor-authorization.json", "authority-inputs.json").each do |name, document|
            path = destination.join(name)
            fail_with("PREPARATION_CONFLICT", "preparation input is missing: #{path}") unless path.file?
            fail_with("PREPARATION_CONFLICT", "preparation input changed: #{name}") unless read_json(path) == document
          end
          binding = destination.join("authority-store.json")
          if binding.exist? || binding.symlink?
            fail_with("PREPARATION_CONFLICT", "authority store binding changed") unless
              !binding.symlink? && binding.file? && read_json(binding) == documents.fetch("authority-store.json")
          elsif @env.key?("AF_DATA_PIPELINE_DATA_ROOT")
            fail_with("PREPARATION_CONFLICT", "historical authority has no private store binding")
          end
          return "validate"
        end

        stage = preparation_root.join(".#{operation_id}.tmp-#{Process.pid}-#{SecureRandom.hex(6)}")
        begin
          FileUtils.mkdir_p(stage)
          documents.slice("operation-input.json", "successor-authorization.json", "authority-inputs.json", "authority-store.json").each do |name, document|
            write_json(stage.join(name), document)
          end
          write_json(stage.join("afw-roots.json"), documents.fetch("afw-roots.json")) if documents["afw-roots.json"]
          File.rename(stage, destination)
          "issue"
        ensure
          FileUtils.remove_entry(stage) if stage.exist?
        end
      end
    rescue SystemCallError => e
      fail_with("PREPARATION_PERSISTENCE_FAILED", e.message)
    end

    # Invokes AFDP issue for new inputs or read-only validate on restart.
    # Returns the owner projection; owner refusal raises Failure without retry.
    def issue_authority!(operation_id, current_state_path, action:)
      executable = pipeline_root.join("bin", "af-staged-scoring-authority")
      required_executable(executable, "pipeline staged-scoring authority")
      response = runner.capture(
        child_environment,
        executable.to_s, action,
        "--inputs", preparation_dir(operation_id).join("authority-inputs.json").to_s,
        "--store", authority_root.to_s,
        "--project-state", current_state_path.to_s,
        chdir: pipeline_root.to_s
      )
      document = response.stdout.to_s.strip.empty? ? {} : parse_json_output(response.stdout, "pipeline authority")
      unless response.status.success? || document["status"] == "NO_SUCCESSOR_NEEDED"
        detail = response.stderr.to_s.strip
        detail = response.stdout.to_s.strip if detail.empty?
        fail_with("AUTHORITY_REJECTED", detail)
      end
      document
    end

    def validate_authority_projection!(projection, operation_id, intent)
      expected_keys = %w[schema_version authority concurrency workload_frozen preparation_allowed
                         execution_authorized catalog_adoption_authorized]
      unless projection.is_a?(Hash) && projection.keys.sort == expected_keys.sort &&
             projection["schema_version"] == AUTHORITY_PROJECTION_VERSION &&
             projection["preparation_allowed"] == true && projection["workload_frozen"] == false &&
             projection["execution_authorized"] == false && projection["catalog_adoption_authorized"] == false
        fail_with("INVALID_AUTHORITY", "pipeline returned an incompatible preparation projection")
      end
      authority = projection.fetch("authority")
      unless projection.dig("concurrency", "decision") == "SAFE_REUSE" &&
             authority.is_a?(Hash) && authority.keys.sort == AUTHORITY_KEYS.sort &&
             authority["schema_version"] == AUTHORITY_VERSION &&
             authority["issuer"] == "af-data-pipeline" && authority["mode"] == "production" &&
             authority["permissions"] == AUTHORITY_PERMISSIONS &&
             authority.dig("operation", "operation_id") == operation_id &&
             authority.fetch("intent") == intent &&
             authority.dig("intent", "workload_id") == intent.fetch("workload_id")
        fail_with("INVALID_AUTHORITY", "pipeline authority does not bind the operation intent")
      end
      expected_id = StagedScoringIntentStore.digest(authority.except("authority_id"))
      fail_with("INVALID_AUTHORITY", "pipeline authority digest mismatch") unless authority["authority_id"] == expected_id
      authority
    end

    def default_afw_coordinator(operation_id, paths)
      AFWStagedWorkloadCoordinator.new(
        afw_root:, afw_data_root: @workload_paths&.data, scorer_root:, pipeline_root:, scorer_config: @scorer_config,
        authority_inputs_path: preparation_dir(operation_id).join("authority-inputs.json"),
        authority_store: authority_root,
        current_project_state_path: paths.fetch(:current_project_state_path)
      )
    end

    def compose_result(operation_id, intent, authority, owner_result, current_state_path:)
      selection = owner_result.fetch("selection")
      dispositions = owner_result.dig("refusal", "dispositions") || selection.fetch("dispositions")
      selected = disposition_rows(dispositions, "selected-qualified")
      deferred = disposition_rows(dispositions, "legitimately-deferred")
      refused = disposition_rows(dispositions, "refused")
      plan = nil
      rows = []
      if owner_result["status"] == "PREPARED"
        manifest = required_directory(owner_result.fetch("manifest"), "AFW workload manifest")
        plan_path = required_file(manifest.join("execution-plan.json"), "AFW execution plan")
        index_path = required_file(manifest.join("case_index.csv"), "AFW case index")
        plan_document = read_json(plan_path)
        rows = CSV.read(index_path, headers: true).map(&:to_h)
        selected_ids = selection.fetch("selected_ids")
        unless plan_document["contract_version"] == PLAN_VERSION &&
               plan_document["plan_id"] == intent.fetch("workload_id") &&
               rows.map { |row| row.fetch("case_id") } == plan_document.fetch("jobs").map { |job| job.fetch("job_id") } &&
               (rows.map { |row| row.fetch("adventure_id") }.uniq - selected_ids).empty? &&
               selected_ids.all? { |id| rows.any? { |row| row.fetch("adventure_id") == id } }
          fail_with("INVALID_PREPARATION_OUTPUT", "AFW verified result and exact case denominator differ")
        end
        selected.each do |entry|
          entry["case_count"] = rows.count { |row| row.fetch("adventure_id") == entry.fetch("adventure_id") }
        end
        plan = {"path" => plan_path.to_s, "sha256" => Digest::SHA256.file(plan_path).hexdigest}
      end
      status = owner_result.fetch("status")
      {
        "contract_version" => RESULT_VERSION,
        "status" => status,
        "operation_id" => operation_id,
        "intent_id" => intent.fetch("intent_id"),
        "authority_id" => authority.fetch("authority_id"),
        "workload_id" => intent.fetch("workload_id"),
        "selection_contract_version" => selection.fetch("schema_version"),
        "selection_id" => selection.fetch("selection_id"),
        "decision" => owner_decision(owner_result),
        "inspection" => owner_result["inspection"],
        "plan" => plan,
        "qualified_cases" => rows.length,
        "metric_denominator" => rows.length,
        "selected" => selected,
        "deferred" => deferred,
        "refused" => refused,
        "execution_authorized" => false,
        "catalog_adoption_authorized" => false,
        "next_action" => status == "PREPARED" ?
          inspection_command(operation_id, intent, selection, authority, current_state_path) : nil
      }
    rescue KeyError, TypeError, CSV::MalformedCSVError => e
      fail_with("INVALID_PREPARATION_OUTPUT", e.message)
    end

    def disposition_rows(dispositions, disposition)
      dispositions.filter_map do |row|
        next unless row["disposition"] == disposition

        row.slice("adventure_id", "reason", "evidence")
      end
    end

    def owner_decision(owner_result)
      inspection = owner_result["inspection"]
      refusal = owner_result["refusal"]
      status_code = {
        "ALL_DEFERRED" => "AFW_ALL_DEFERRED",
        "REFUSED" => "AFW_SELECTION_REFUSED"
      }[owner_result.fetch("status")]
      {
        "code" => refusal&.dig("reason", "code") || status_code ||
          inspection&.fetch("reason_code", nil) || "AFW_PREPARED",
        "detail" => refusal&.dig("reason", "detail") || inspection&.fetch("detail", nil)
      }.compact
    end

    def inspection_command(operation_id, intent, selection, authority, current_state_path)
      argv = [
        Pathname(afw_root).join("bin", "afw-inspect-workload"),
        *(@workload_paths&.data ? @workload_paths.data_arguments : ["--root", afw_root]),
        "--workload", intent.fetch("workload_id"),
        "--catalog", catalog_root.join(authority.dig("staged_amc", "filename")),
        "--ids", selection.fetch("selected_ids").join(","),
        "--scorer-repo", scorer_root,
        "--required-context-length", REQUIRED_CONTEXT_LENGTH,
        "--require-fully-gpu-resident",
        "--staged-authority-inputs", preparation_dir(operation_id).join("authority-inputs.json"),
        "--staged-authority-store", authority_root,
        "--staged-project-state", current_state_path,
        "--staged-operation", operation_id,
        "--staged-selection", (@workload_paths&.store || Pathname(afw_root)).join("workloads", ".selections", intent.fetch("workload_id"), "selection.json"),
        "--staged-pipeline-root", pipeline_root
      ]
      argv += ["--scorer-config", @scorer_config] if @scorer_config
      Shellwords.join(argv.map(&:to_s))
    end

    def zero_result(operation_id, intent, projection)
      {
        "contract_version" => RESULT_VERSION,
        "status" => "NO_SUCCESSOR_NEEDED",
        "operation_id" => operation_id,
        "intent_id" => intent.fetch("intent_id"),
        "authority_id" => nil,
        "workload_id" => intent.fetch("workload_id"),
        "selection_contract_version" => nil,
        "selection_id" => nil,
        "decision" => {"code" => "NO_SUCCESSOR_NEEDED", "evidence" => projection.fetch("observation")},
        "inspection" => nil,
        "plan" => nil,
        "qualified_cases" => 0,
        "metric_denominator" => 0,
        "selected" => [],
        "deferred" => [],
        "refused" => [],
        "execution_authorized" => false,
        "catalog_adoption_authorized" => false,
        "next_action" => nil
      }
    end

    def persist_result!(operation_id, result)
      path = preparation_dir(operation_id).join("result.json")
      if path.file?
        existing = read_json(path)
        # AFW's public inspector includes an observation of scoring results.
        # Successful execution changes that observation without changing the
        # frozen selection, workload or preparation identity. AFW still checks
        # the current results for conflicts before returning a reuse action.
        fail_with("PREPARATION_CONFLICT", "stored preparation result changed") unless
          stable_preparation_result(existing) == stable_preparation_result(result)
        return
      end
      write_json(path, result)
    rescue SystemCallError => e
      fail_with("PREPARATION_PERSISTENCE_FAILED", e.message)
    end

    def stable_preparation_result(result)
      copy = Marshal.load(Marshal.dump(result))
      %w[output results].each { |key| copy.dig("inspection", "observed")&.delete(key) }
      copy
    end

    def require_editorial_lineage!(operation)
      kinds = operation.fetch("artifacts").map { |artifact| artifact.fetch("kind") }
      required = %w[boundary_dossier editorial_context editorial_decisions]
      missing = required - kinds
      fail_with("INCOMPLETE_EDITORIAL_LINEAGE", "operation lacks #{missing.join(', ')}") unless missing.empty?
    end

    def validate_staged_catalog!(path, identity)
      actual = {"sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => File.size(path)}
      unless path.file? && File.basename(path) == identity.fetch("filename") &&
             actual == identity.slice("sha256", "bytes")
        fail_with("INVALID_AUTHORITY", "authorized staged catalog is missing or changed")
      end
    rescue Errno::ENOENT
      fail_with("INVALID_AUTHORITY", "authorized staged catalog is missing or changed")
    end

    # Returns the selected AFDP store locator; AFDP validates the destination.
    # An absent selector preserves the existing checkout layout.
    def authority_root
      Pathname(@env.fetch("AF_DATA_PIPELINE_DATA_ROOT", pipeline_root.to_s))
        .join("output", "staged-scoring-authority", "v0.1")
    end

    def preparation_root
      StatePaths.root(front_door_root:, project_root:, owner_roots: [source_root, catalog_root, afw_root, pipeline_root, scorer_root].compact, env: @env).join("output", "staged-workload-preparations", "v0.1")
    end

    def preparation_dir(operation_id)
      preparation_root.join(operation_id)
    end

    def preparation_lock(operation_id)
      preparation_root.join("#{operation_id}.lock")
    end

    def child_environment
      {"AF_PROJECT_ROOT" => project_root.to_s, "AF_ADVENTURE_FINDER_ROOT" => front_door_root.to_s,
       "AF_DATA_PIPELINE_DATA_ROOT" => @env["AF_DATA_PIPELINE_DATA_ROOT"]}
    end

    def required_file(path, label)
      value = Pathname(path).expand_path
      fail_with("MISSING_PREPARATION_INPUT", "#{label} is missing: #{value}") unless value.file?
      value
    end

    def required_directory(path, label)
      value = Pathname(path).expand_path
      fail_with("MISSING_PREPARATION_INPUT", "#{label} is missing: #{value}") unless value.directory?
      value
    end

    def required_executable(path, label)
      fail_with("COMPONENT_UNAVAILABLE", "#{label} is unavailable: #{path}") unless path.file? && path.executable?
    end

    def parse_json_output(value, label)
      JSON.parse(value)
    rescue JSON::ParserError
      fail_with("COMPONENT_PROTOCOL_ERROR", "#{label} returned invalid JSON")
    end

    def write_json(path, value)
      temporary = Pathname("#{path}.tmp-#{Process.pid}-#{SecureRandom.hex(6)}")
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.pretty_generate(StagedScoringIntentStore.canonical(value)) + "\n")
        file.flush
        file.fsync
      end
      File.rename(temporary, path)
    ensure
      File.unlink(temporary) if temporary&.exist?
    end

    def read_json(path)
      JSON.parse(File.binread(path))
    end

    def fail_with(code, message)
      raise Failure.new(code, message)
    end
  end
end
