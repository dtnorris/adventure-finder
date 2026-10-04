# frozen_string_literal: true

require "digest"
require "json"
require_relative "adventure_finder_workspace"
require_relative "adventure_finder_capability_artifacts"
require_relative "adventure_finder_production_context"

module AdventureFinderWorkspace
  class ModelPreflight
    LEGACY_CONTRACT_VERSION = "adventurefinder-model-requirement/v0.1"
    PLAN_CONTRACT_VERSION = "wlo-execution-plan/v0.3"
    DIGEST = /\A[0-9a-f]{64}\z/
    OLLAMA_KEYS = %w[
      model expected_digest required_context_length require_fully_gpu_resident required_gpu_id
    ].freeze

    Source = Struct.new(
      :batch_handle, :alias_name, :batch, :plan, :pool_id, :pool,
      :requirement, :required_labels,
      keyword_init: true
    )

    def initialize(registry:, capability_request_class: nil)
      @registry = registry
      @capability_request_class = capability_request_class
    end

    def resolve(batch_handle:, alias_name:)
      source = resolve_source(batch_handle:, alias_name:)
      CapabilityArtifacts.new(
        ollama_requirement: source.requirement,
        provenance: {
          operator_alias: source.alias_name,
          batch_handle: source.batch_handle,
          production_batch_id: source.batch.fetch("production_batch_id"),
          plan_id: source.plan.fetch("plan_id"),
          plan_sha256: source.batch.dig("plan", "sha256"),
          pool_id: source.pool_id
        },
        capability_request_class: capability_request_class!(source.batch)
      ).to_h
    end

    # Transitional compatibility for the existing LOW handoff. New
    # AdventureFinder artifact generation uses #resolve and the split contracts.
    def resolve_legacy_requirement(batch_handle:, alias_name:)
      source = resolve_source(batch_handle:, alias_name:)
      {
        "contract_version" => LEGACY_CONTRACT_VERSION,
        "batch_handle" => source.batch_handle,
        "production_batch_id" => source.batch.fetch("production_batch_id"),
        "plan_id" => source.plan.fetch("plan_id"),
        "plan_sha256" => source.batch.dig("plan", "sha256"),
        "alias" => source.alias_name,
        "pool_id" => source.pool_id,
        "required_labels" => source.required_labels,
        "ollama" => source.requirement
      }.freeze
    end

    private

    def resolve_source(batch_handle:, alias_name:)
      batch = @registry.resolve("batch", batch_handle)
      verify_plan_bytes!(batch)
      plan = load_plan(batch.dig("afw", "plan_path"))
      verify_plan_identity!(plan, batch)
      pool_id = resolve_pool_id!(batch, alias_name)
      pool = exact_pool!(plan, pool_id)
      requirement = exact_requirement!(pool)

      Source.new(
        batch_handle: batch_handle.to_s,
        alias_name: alias_name.to_s,
        batch:,
        plan:,
        pool_id:,
        pool:,
        requirement:,
        required_labels: exact_labels!(pool.fetch("required_labels", []))
      ).freeze
    end

    def capability_request_class!(batch)
      return @capability_request_class if @capability_request_class
      return WorkloadOrchestrator::OllamaCapabilityRequest if defined?(WorkloadOrchestrator::OllamaCapabilityRequest)

      path = File.join(
        batch.dig("wlo", "repository_root"), "lib", "workload_orchestrator",
        "ollama_capability_request.rb"
      )
      raise Error, "WLO capability-request contract is unavailable: #{path}" unless File.file?(path)

      require path
      WorkloadOrchestrator::OllamaCapabilityRequest
    rescue LoadError, NameError => e
      raise Error, "WLO capability-request contract could not be loaded: #{e.message}"
    end

    def verify_plan_bytes!(batch)
      path = batch.dig("afw", "plan_path")
      actual = Digest::SHA256.file(path).hexdigest
      expected = batch.dig("plan", "sha256")
      return if actual == expected

      raise Error, "plan SHA-256 mismatch: expected #{expected}, got #{actual}"
    rescue Errno::ENOENT => e
      raise Error, "AFW execution plan is unavailable: #{e.message}"
    end

    def load_plan(path)
      value = JSON.parse(File.binread(path))
      raise Error, "AFW execution plan must be a JSON object" unless value.is_a?(Hash)
      value
    rescue JSON::ParserError => e
      raise Error, "AFW execution plan is invalid JSON: #{e.message}"
    end

    def verify_plan_identity!(plan, batch)
      unless plan["contract_version"] == PLAN_CONTRACT_VERSION
        raise Error, "AFW execution plan must use #{PLAN_CONTRACT_VERSION}"
      end
      expected = batch.dig("plan", "plan_id")
      actual = plan["plan_id"]
      raise Error, "plan_id mismatch: expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
      unless plan["pools"].is_a?(Array) && !plan["pools"].empty?
        raise Error, "AFW execution plan pools must be a non-empty array"
      end
    end

    def resolve_pool_id!(batch, alias_name)
      candidates = batch.fetch("model_aliases")[alias_name.to_s]
      raise Error, "unknown model alias #{alias_name.inspect} for batch #{batch.fetch('handle')}" unless candidates
      unless candidates.length == 1
        raise Error, "model alias #{alias_name.inspect} is ambiguous: #{candidates.join(', ')}"
      end
      candidates.first
    end

    def exact_pool!(plan, pool_id)
      pools = plan.fetch("pools").select { |pool| pool.is_a?(Hash) && pool["pool_id"] == pool_id }
      raise Error, "model alias references absent pool #{pool_id.inspect}" if pools.empty?
      raise Error, "execution plan contains duplicate pool #{pool_id.inspect}" unless pools.length == 1
      pools.first
    end

    def exact_requirement!(pool)
      requirements = pool["requirements"]
      unless requirements.is_a?(Hash) && requirements.keys == ["ollama"] && requirements["ollama"].is_a?(Hash)
        raise Error, "pool #{pool['pool_id'].inspect} must contain exactly one Ollama requirement"
      end
      source = requirements.fetch("ollama")
      unknown = source.keys - OLLAMA_KEYS
      raise Error, "Ollama requirement has unknown field(s): #{unknown.sort.join(', ')}" unless unknown.empty?

      model = exact_string!(source["model"], "model")
      digest = source["expected_digest"]
      raise Error, "expected_digest must be a lowercase SHA-256" unless digest.is_a?(String) && DIGEST.match?(digest)
      context = source["required_context_length"]
      unless context.is_a?(Integer) && context.positive?
        raise Error, "required_context_length must be a positive integer"
      end
      raise Error, "require_fully_gpu_resident must be true" unless source["require_fully_gpu_resident"] == true

      output = {
        "model" => model,
        "expected_digest" => digest,
        "required_context_length" => context,
        "require_fully_gpu_resident" => true
      }
      if source.key?("required_gpu_id")
        output["required_gpu_id"] = exact_string!(source["required_gpu_id"], "required_gpu_id")
      end
      output.freeze
    end

    def exact_labels!(value)
      valid = value.is_a?(Array) && value.all? do |item|
        item.is_a?(String) && !item.empty? && item == item.strip
      end
      unless valid && value.uniq == value
        raise Error, "pool required_labels must be unique non-empty strings"
      end
      value.dup.freeze
    end

    def exact_string!(value, label)
      return value if value.is_a?(String) && !value.empty? && value == value.strip && !value.match?(/[[:cntrl:]]/)
      raise Error, "#{label} must be a non-empty trimmed string"
    end
  end
end
