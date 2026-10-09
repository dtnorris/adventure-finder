# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "securerandom"
require "yaml"
require_relative "adventure_finder_ingest_operation"
require_relative "adventure_finder_ingest_routing"
require_relative "adventure_finder_staged_scoring_intent"
require_relative "adventure_finder_successor_version_authorization"

module AdventureFinderWorkspace
  # Coordinates pipeline authority issuance and one zero-inference AFW build.
  # It owns neither qualification policy nor execution. All model, dimension,
  # profile and runtime selection stays inside AFW's public compiler.
  class StagedWorkloadPreparation
    RESULT_VERSION = "adventurefinder-staged-workload-preparation/v0.1"
    LOCATOR_VERSION = "af-staged-scoring-evidence-locators/v0.1"
    AUTHORITY_PROJECTION_VERSION = "af-staged-scoring-authority-projection/v0.1"
    AUTHORITY_VERSION = "af-staged-scoring-authority/v0.1"
    PLAN_VERSION = "wlo-execution-plan/v0.3"
    SNAPSHOT_VERSION = "afw-workload/v0.1"
    STAGED_DOCUMENT_VERSION = "afw-staged-scoring-input/v0.1"
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
                   authorization_store:, routing:, runner: CommandRunner.new)
      @front_door_root = Pathname(front_door_root).expand_path
      @project_root = Pathname(project_root).expand_path
      @pipeline_root = Pathname(pipeline_root).expand_path
      @afw_root = Pathname(afw_root).expand_path
      @scorer_root = Pathname(scorer_root).expand_path
      @source_root = Pathname(source_root).expand_path
      @catalog_root = Pathname(catalog_root).expand_path
      @operation_store = operation_store
      @intent_store = intent_store
      @authorization_store = authorization_store
      @routing = routing
      @runner = runner
    end

    def prepare(operation_id:, freeze_path:, approval_path:, bundle_dir:,
                historical_project_state_path:, current_project_state_path: nil)
      operation = operation_store.validate!(operation_id)
      require_editorial_lineage!(operation)
      intent = intent_store.intent!(operation_id)
      paths = evidence_paths(
        operation_id:, freeze_path:, approval_path:, bundle_dir:,
        historical_project_state_path:,
        current_project_state_path: current_project_state_path || catalog_root.join("PROJECT_STATE.yml")
      )
      documents = preparation_documents(operation_id, paths, intent)
      persist_preparation_inputs!(operation_id, documents)
      projection = issue_authority!(operation_id, paths.fetch(:current_project_state_path))
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

      workload_id = intent.fetch("workload_id")
      manifest = afw_root.join("workloads", workload_id)
      if manifest.directory?
        run_afw_verify!(workload_id)
      else
        run_afw_build!(operation_id, workload_id, staged_catalog, ids, paths.fetch(:current_project_state_path))
      end
      result = inspect_workload!(operation_id, intent, authority, manifest, ids)
      persist_result!(operation_id, result)
      result
    rescue IngestOperationStore::Failure, StagedScoringIntentStore::Failure,
           SuccessorVersionAuthorizationStore::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    rescue Psych::Exception, JSON::ParserError, CSV::MalformedCSVError, KeyError, TypeError => e
      fail_with("INVALID_PREPARATION_OUTPUT", e.message)
    end

    private

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
       "intent_id" => intent.fetch("intent_id")}
    end

    def persist_preparation_inputs!(operation_id, documents)
      destination = preparation_dir(operation_id)
      FileUtils.mkdir_p(preparation_root)
      File.open(preparation_lock(operation_id), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        if destination.directory?
          documents.slice("operation-input.json", "successor-authorization.json", "authority-inputs.json").each do |name, document|
            path = destination.join(name)
            fail_with("PREPARATION_CONFLICT", "preparation input is missing: #{path}") unless path.file?
            fail_with("PREPARATION_CONFLICT", "preparation input changed: #{name}") unless read_json(path) == document
          end
          return
        end

        stage = preparation_root.join(".#{operation_id}.tmp-#{Process.pid}-#{SecureRandom.hex(6)}")
        begin
          FileUtils.mkdir_p(stage)
          documents.slice("operation-input.json", "successor-authorization.json", "authority-inputs.json").each do |name, document|
            write_json(stage.join(name), document)
          end
          File.rename(stage, destination)
        ensure
          FileUtils.remove_entry(stage) if stage.exist?
        end
      end
    rescue SystemCallError => e
      fail_with("PREPARATION_PERSISTENCE_FAILED", e.message)
    end

    def issue_authority!(operation_id, current_state_path)
      executable = pipeline_root.join("bin", "af-staged-scoring-authority")
      required_executable(executable, "pipeline staged-scoring authority")
      response = runner.capture(
        child_environment,
        executable.to_s, "issue",
        "--inputs", preparation_dir(operation_id).join("authority-inputs.json").to_s,
        "--store", authority_root.to_s,
        "--project-state", current_state_path.to_s,
        chdir: pipeline_root.to_s
      )
      document = parse_json_output(response.stdout, "pipeline authority")
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

    def run_afw_build!(operation_id, workload_id, catalog, ids, current_state_path)
      executable = afw_root.join("bin", "afw-build-workload")
      required_executable(executable, "AFW workload compiler")
      argv = [
        executable.to_s,
        "--workload", workload_id,
        "--catalog", catalog.to_s,
        "--ids", ids.join(","),
        "--scorer-repo", scorer_root.to_s,
        "--required-context-length", REQUIRED_CONTEXT_LENGTH.to_s,
        "--require-fully-gpu-resident",
        "--staged-authority-inputs", preparation_dir(operation_id).join("authority-inputs.json").to_s,
        "--staged-authority-store", authority_root.to_s,
        "--staged-project-state", current_state_path.to_s,
        "--staged-operation", operation_id,
        "--staged-pipeline-root", pipeline_root.to_s
      ]
      response = runner.capture(child_environment, *argv, chdir: afw_root.to_s)
      unless response.status.success?
        detail = [response.stderr, response.stdout].map(&:to_s).reject(&:empty?).join(" ").strip
        disposition = ids.map { |id| "#{id}=deferred" }.join(", ")
        fail_with("AFW_PREPARATION_REFUSED", "#{disposition}; AFW qualification refused: #{detail}")
      end
    end

    def run_afw_verify!(workload_id)
      executable = afw_root.join("bin", "afw-verify-staged-workload")
      required_executable(executable, "AFW staged-workload verifier")
      response = runner.capture(
        child_environment, executable.to_s, "--workload", workload_id, chdir: afw_root.to_s
      )
      unless response.status.success?
        detail = [response.stderr, response.stdout].map(&:to_s).reject(&:empty?).join(" ").strip
        fail_with("WORKLOAD_REPAIR_REQUIRED", detail)
      end
    end

    def inspect_workload!(operation_id, intent, authority, manifest, intended_ids)
      required_directory(manifest, "AFW workload manifest")
      plan_path = required_file(manifest.join("execution-plan.json"), "AFW execution plan")
      snapshot_path = required_file(manifest.join("snapshot.yml"), "AFW snapshot")
      index_path = required_file(manifest.join("case_index.csv"), "AFW case index")
      staged_path = required_file(manifest.join("staged-scoring.json"), "AFW staged authority binding")
      plan = read_json(plan_path)
      snapshot = YAML.safe_load_file(snapshot_path, aliases: false)
      staged = read_json(staged_path)
      rows = CSV.read(index_path, headers: true).map(&:to_h)

      unless plan["contract_version"] == PLAN_VERSION && plan["plan_id"] == intent.fetch("workload_id")
        fail_with("INVALID_PREPARATION_OUTPUT", "AFW plan is not provider-neutral v0.3 for this workload")
      end
      validate_capabilities!(plan)
      plan_sha = Digest::SHA256.file(plan_path).hexdigest
      unless snapshot.is_a?(Hash) && snapshot["contract_version"] == SNAPSHOT_VERSION &&
             snapshot["workload_id"] == intent.fetch("workload_id") &&
             snapshot["execution_plan_sha256"] == plan_sha &&
             snapshot["adventure_order"] == intended_ids &&
             snapshot["case_count"] == rows.length && rows.length == plan.fetch("jobs").length
        fail_with("INVALID_PREPARATION_OUTPUT", "AFW snapshot, plan and case index do not reconcile")
      end
      row_ids = rows.map { |row| row.fetch("adventure_id") }
      unless (row_ids - intended_ids).empty? && intended_ids.all? { |id| row_ids.include?(id) }
        fail_with("INVALID_PREPARATION_OUTPUT", "AFW case coverage differs from intended new Adventure IDs")
      end
      job_ids = plan.fetch("jobs").map { |job| job.fetch("job_id") }
      fail_with("INVALID_PREPARATION_OUTPUT", "AFW plan jobs differ from case index") unless
        job_ids == rows.map { |row| row.fetch("case_id") } && job_ids.uniq == job_ids
      binding = staged.fetch("binding")
      unless staged["schema_version"] == STAGED_DOCUMENT_VERSION &&
             binding["authority_id"] == authority.fetch("authority_id") &&
             binding["operation_id"] == operation_id &&
             binding["workload_id"] == intent.fetch("workload_id") &&
             binding["intended_ids"] == intended_ids
        fail_with("INVALID_PREPARATION_OUTPUT", "AFW staged authority binding differs")
      end
      {
        "contract_version" => RESULT_VERSION,
        "status" => "PREPARED",
        "operation_id" => operation_id,
        "intent_id" => intent.fetch("intent_id"),
        "authority_id" => authority.fetch("authority_id"),
        "workload_id" => intent.fetch("workload_id"),
        "plan" => {"path" => plan_path.to_s, "sha256" => plan_sha},
        "qualified_cases" => rows.length,
        "metric_denominator" => rows.length,
        "selected" => intended_ids.map do |id|
          {"adventure_id" => id, "case_count" => row_ids.count(id), "evidence" => "AFW snapshot and case index"}
        end,
        "deferred" => [],
        "execution_authorized" => false,
        "catalog_adoption_authorized" => false,
        "next_action" => "#{afw_root.join('bin', 'afw-verify-staged-workload')} --workload #{intent.fetch('workload_id')}"
      }
    end

    def validate_capabilities!(plan)
      pools = plan["pools"]
      unless pools.is_a?(Array) && !pools.empty?
        fail_with("CAPABILITY_POLICY_MISMATCH", "AFW plan has no logical pools")
      end
      pools.each do |pool|
        ollama = pool.dig("requirements", "ollama")
        unless ollama.is_a?(Hash) && ollama["required_context_length"] == REQUIRED_CONTEXT_LENGTH &&
               ollama["require_fully_gpu_resident"] == true && !ollama.key?("required_gpu_id") &&
               !pool.key?("worker_names") && !pool.key?("max_concurrency")
          fail_with("CAPABILITY_POLICY_MISMATCH", "AFW plan changed the frozen production capability policy")
        end
      end
    end

    def zero_result(operation_id, intent, projection)
      {
        "contract_version" => RESULT_VERSION,
        "status" => "NO_RUNNABLE_WORK",
        "operation_id" => operation_id,
        "intent_id" => intent.fetch("intent_id"),
        "authority_id" => nil,
        "workload_id" => intent.fetch("workload_id"),
        "plan" => nil,
        "qualified_cases" => 0,
        "metric_denominator" => 0,
        "selected" => [],
        "deferred" => [{"adventure_id" => nil, "reason" => "approved boundary freeze contains no new records",
                        "evidence" => projection.fetch("observation")}],
        "execution_authorized" => false,
        "catalog_adoption_authorized" => false,
        "next_action" => nil
      }
    end

    def persist_result!(operation_id, result)
      path = preparation_dir(operation_id).join("result.json")
      if path.file?
        fail_with("PREPARATION_CONFLICT", "stored preparation result changed") unless read_json(path) == result
        return
      end
      write_json(path, result)
    rescue SystemCallError => e
      fail_with("PREPARATION_PERSISTENCE_FAILED", e.message)
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

    def authority_root
      pipeline_root.join("output", "staged-scoring-authority", "v0.1")
    end

    def preparation_root
      front_door_root.join("output", "staged-workload-preparations", "v0.1")
    end

    def preparation_dir(operation_id)
      preparation_root.join(operation_id)
    end

    def preparation_lock(operation_id)
      preparation_root.join("#{operation_id}.lock")
    end

    def child_environment
      {"AF_PROJECT_ROOT" => project_root.to_s, "AF_ADVENTURE_FINDER_ROOT" => front_door_root.to_s}
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
