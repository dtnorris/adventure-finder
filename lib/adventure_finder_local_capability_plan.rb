# frozen_string_literal: true

require_relative "adventure_finder_state_paths"

require "digest"
require "json"
require "pathname"
require "yaml"
require_relative "adventure_finder_capability_artifacts"

module AdventureFinderWorkspace
  # Derives a planning-only, one-worker capability sequence from the exact
  # frozen AFW execution plan. It observes neither workers nor providers.
  class LocalCapabilityPlan
    CONTRACT_VERSION = "adventurefinder-local-capability-plan/v0.1"
    PREPARATION_VERSION = "adventurefinder-staged-workload-preparation/v0.2"
    LEGACY_PREPARATION_VERSION = "adventurefinder-staged-workload-preparation/v0.1"
    PLAN_VERSION = "wlo-execution-plan/v0.3"
    SNAPSHOT_VERSION = "afw-workload/v0.1"
    STAGED_VERSION = "afw-staged-scoring-input/v0.1"
    LEGACY_RESULT_KEYS = %w[
      contract_version status operation_id intent_id authority_id workload_id plan
      qualified_cases metric_denominator selected deferred execution_authorized
      catalog_adoption_authorized next_action
    ].freeze
    RESULT_KEYS = %w[
      contract_version status operation_id intent_id authority_id workload_id
      selection_contract_version selection_id decision inspection plan qualified_cases
      metric_denominator selected deferred refused execution_authorized
      catalog_adoption_authorized next_action
    ].freeze
    SHA256 = /\A[0-9a-f]{64}\z/
    UUID_V4 = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

    class Failure < Error
      attr_reader :code

      def initialize(code, message)
        @code = code
        super("#{code}: #{message}")
      end
    end

    attr_reader :front_door_root, :project_root, :env

    def initialize(front_door_root:, project_root:, env: ENV,
                   plan_class: nil, capability_request_class: nil)
      @front_door_root = Pathname(front_door_root).expand_path
      @project_root = Pathname(project_root).expand_path
      @env = env
      @plan_class = plan_class
      @capability_request_class = capability_request_class
    end

    def call(operation_id:)
      result = read_json(preparation_path(operation_id), "staged workload preparation")
      validate_result!(result, operation_id)
      manifest = afw_root.join("workloads", result.fetch("workload_id"))
      expected_plan_path = manifest.join("execution-plan.json").expand_path
      bound_plan_path = Pathname(result.dig("plan", "path").to_s).expand_path
      fail_with("STALE_WORKLOAD_BINDING", "preparation result does not bind the frozen workload plan") unless
        bound_plan_path == expected_plan_path

      load_wlo_contracts!
      plan = load_plan(expected_plan_path)
      validate_plan_binding!(plan, result)
      validate_workload_provenance!(manifest, plan, result)
      reject_dependencies!(plan)

      capabilities = build_capabilities(plan)
      document = {
        "contract_version" => CONTRACT_VERSION,
        "operation" => {
          "operation_id" => result.fetch("operation_id"),
          "intent_id" => result.fetch("intent_id"),
          "authority_id" => result.fetch("authority_id")
        },
        "workload" => {
          "workload_id" => result.fetch("workload_id"),
          "plan_id" => plan.id,
          "plan_contract_version" => plan.contract_version,
          "plan_sha256" => plan.sha256
        },
        "capabilities" => capabilities,
        "sequence" => capabilities.map.with_index do |capability, index|
          pool_ids = capability.fetch("pools").map { |pool| pool.fetch("pool_id") }
          {
            "step" => index + 1,
            "capability_fingerprint" => capability.fetch("capability_fingerprint"),
            "pool_ids" => pool_ids,
            "job_ids" => plan.jobs.select { |job| pool_ids.include?(job.pool_id) }.map(&:id)
          }
        end,
        "accounting" => {
          "capability_count" => capabilities.length,
          "pool_count" => plan.pools.length,
          "job_count" => plan.jobs.length
        },
        "assumptions" => [
          "Sequence order is first required occurrence in the frozen independent-job plan.",
          "Required capabilities do not assert that local hardware can host them or that a worker is READY.",
          "Pool labels and optional GPU identities remain exact requirements, not substitutions.",
          "This document grants no scheduling, execution, provider, capacity, or catalog-adoption authority."
        ],
        "planning_only" => true,
        "read_only" => true,
        "readiness_observed" => false,
        "execution_authorized" => false,
        "provider_authorized" => false,
        "catalog_adoption_authorized" => false
      }
      deep_freeze(document)
    rescue Failure
      raise
    rescue JSON::ParserError, Psych::Exception, KeyError, TypeError => e
      fail_with("INVALID_CAPABILITY_INPUT", e.message)
    rescue Error => e
      fail_with("INVALID_CAPABILITY_INPUT", e.message)
    rescue StandardError => e
      raise unless e.class.name == "WorkloadOrchestrator::Error"

      fail_with("INVALID_WLO_PLAN", e.message)
    end

    def bytes(operation_id:)
      JSON.pretty_generate(call(operation_id:)) + "\n"
    end

    private

    def build_capabilities(plan)
      pool_order = plan.jobs.map(&:pool_id).uniq + plan.pools.map(&:id)
      pools = pool_order.uniq.map { |pool_id| plan.pool(pool_id) }
      grouped = []
      by_fingerprint = {}

      pools.each do |pool|
        artifact = GenericCapabilityArtifact.new(
          ollama_requirement: pool.ollama_requirement,
          capability_request_class: @capability_request_class
        )
        capability = by_fingerprint[artifact.capability_fingerprint]
        unless capability
          capability = {
            "capability_request" => artifact.capability_request,
            "capability_fingerprint" => artifact.capability_fingerprint,
            "capability_artifact_sha256" => artifact.capability_artifact_sha256,
            "pools" => []
          }
          by_fingerprint[artifact.capability_fingerprint] = capability
          grouped << capability
        end
        capability.fetch("pools") << {
          "pool_id" => pool.id,
          "required_labels" => pool.required_labels,
          "jobs" => plan.jobs.select { |job| job.pool_id == pool.id }.map do |job|
            {
              "job_id" => job.id,
              "group_id" => job.group_id,
              "depends_on_job_ids" => job.depends_on_job_ids
            }
          end
        }
      end
      grouped
    end

    def validate_result!(result, operation_id)
      version = result.is_a?(Hash) ? result["contract_version"] : nil
      keys = version == LEGACY_PREPARATION_VERSION ? LEGACY_RESULT_KEYS : RESULT_KEYS
      valid = result.is_a?(Hash) && result.keys.sort == keys.sort &&
              [PREPARATION_VERSION, LEGACY_PREPARATION_VERSION].include?(version) &&
              result["status"] == "PREPARED" &&
              result["operation_id"] == operation_id && result["execution_authorized"] == false &&
              result["catalog_adoption_authorized"] == false && result["plan"].is_a?(Hash) &&
              result["plan"].keys.sort == %w[path sha256] && SHA256.match?(result["plan"]["sha256"].to_s)
      fail_with("INVALID_PREPARATION_RESULT", "stored preparation is not a bound PREPARED workload") unless valid
      if version == PREPARATION_VERSION
        valid_owner = result["selection_contract_version"] == "afw-staged-selection/v0.1" &&
                      SHA256.match?(result["selection_id"].to_s) && result.fetch("refused").empty? &&
                      result.dig("inspection", "contract_version") == "afw-workload-inspection/v0.1" &&
                      result.dig("inspection", "action") == "reuse"
        fail_with("INVALID_PREPARATION_RESULT", "stored preparation lacks verified AFW owner evidence") unless valid_owner
      end
      %w[operation_id intent_id authority_id workload_id].each do |key|
        fail_with("INVALID_PREPARATION_RESULT", "#{key} is missing") unless identity?(result[key])
      end
    end

    def validate_plan_binding!(plan, result)
      unless plan.contract_version == PLAN_VERSION && plan.id == result.fetch("workload_id") &&
             plan.sha256 == result.dig("plan", "sha256")
        fail_with("STALE_WORKLOAD_BINDING", "frozen plan identity or bytes differ from preparation")
      end
      unless result.fetch("qualified_cases") == plan.jobs.length &&
             result.fetch("metric_denominator") == plan.jobs.length
        fail_with("STALE_WORKLOAD_BINDING", "preparation accounting differs from frozen plan jobs")
      end
    end

    def validate_workload_provenance!(manifest, plan, result)
      snapshot = read_yaml(manifest.join("snapshot.yml"), "AFW workload snapshot")
      staged = read_json(manifest.join("staged-scoring.json"), "AFW staged authority binding")
      binding = staged["binding"]
      valid_snapshot = snapshot.is_a?(Hash) && snapshot["contract_version"] == SNAPSHOT_VERSION &&
                       snapshot["workload_id"] == result.fetch("workload_id") &&
                       snapshot["execution_plan_sha256"] == plan.sha256 &&
                       snapshot["case_count"] == plan.jobs.length
      valid_binding = staged.is_a?(Hash) && staged["schema_version"] == STAGED_VERSION &&
                      binding.is_a?(Hash) && binding["operation_id"] == result.fetch("operation_id") &&
                      binding["workload_id"] == result.fetch("workload_id") &&
                      binding["authority_id"] == result.fetch("authority_id")
      unless valid_snapshot && valid_binding
        fail_with("STALE_WORKLOAD_BINDING", "AFW snapshot or staged authority does not bind this operation and plan")
      end
    end

    def reject_dependencies!(plan)
      job = plan.jobs.find { |candidate| !candidate.depends_on_job_ids.empty? }
      return unless job

      fail_with(
        "UNSUPPORTED_DEPENDENCY_SEQUENCE",
        "job #{job.id.inspect} has dependencies; a safe one-pass capability sequence is not established"
      )
    end

    def load_plan(path)
      fail_with("MISSING_FROZEN_PLAN", "frozen plan is missing: #{path}") unless path.file?
      @plan_class.load(path.to_s)
    end

    def load_wlo_contracts!
      return if @plan_class && @capability_request_class

      root = Pathname(env.fetch("WLO_REPO_ROOT", project_root.join("workload-orchestrator").to_s)).expand_path
      error_path = root.join("lib", "workload_orchestrator", "error.rb")
      plan_path = root.join("lib", "workload_orchestrator", "plan.rb")
      capability_path = root.join("lib", "workload_orchestrator", "ollama_capability_request.rb")
      unless [error_path, plan_path, capability_path].all?(&:file?)
        fail_with("COMPONENT_UNAVAILABLE", "WLO public planning contracts are unavailable under #{root}")
      end
      require error_path.to_s
      require plan_path.to_s
      require capability_path.to_s
      @plan_class = WorkloadOrchestrator::Plan
      @capability_request_class = WorkloadOrchestrator::OllamaCapabilityRequest
    end

    def preparation_path(operation_id)
      unless operation_id.is_a?(String) && UUID_V4.match?(operation_id)
        fail_with("INVALID_OPERATION_HANDLE", "operation handle must be a lowercase UUIDv4")
      end
      StatePaths.root(front_door_root:, project_root:, env:).join("output", "staged-workload-preparations", "v0.1", operation_id, "result.json")
    end

    def afw_root
      Pathname(env.fetch("AF_AFW_ROOT", project_root.join("af-workloads").to_s)).expand_path
    end

    def read_json(path, label)
      fail_with("MISSING_CAPABILITY_INPUT", "#{label} is missing: #{path}") unless path.file?
      JSON.parse(File.binread(path))
    end

    def read_yaml(path, label)
      fail_with("MISSING_CAPABILITY_INPUT", "#{label} is missing: #{path}") unless path.file?
      YAML.safe_load_file(path, aliases: false)
    end

    def identity?(value)
      value.is_a?(String) && !value.empty? && value == value.strip && !value.match?(/[[:cntrl:]]/)
    end

    def deep_freeze(value)
      case value
      when Hash then value.each { |key, item| deep_freeze(key); deep_freeze(item) }
      when Array then value.each { |item| deep_freeze(item) }
      end
      value.freeze
    end

    def fail_with(code, message)
      raise Failure.new(code, message)
    end
  end
end
