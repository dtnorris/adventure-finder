# frozen_string_literal: true

require "digest"
require "json"
require_relative "adventure_finder_workspace"

module AdventureFinderWorkspace
  class CapabilityProvenance
    CONTRACT_VERSION = "adventurefinder-capability-provenance/v0.1"
    SHA256 = /\A[0-9a-f]{64}\z/

    attr_reader :document, :bytes

    def initialize(operator_alias:, batch_handle:, production_batch_id:, plan_id:, plan_sha256:,
                   pool_id:, capability_contract_version:, capability_fingerprint:,
                   capability_artifact_sha256:)
      @document = deep_freeze(
        "contract_version" => CONTRACT_VERSION,
        "operator_alias" => identity!(operator_alias, "operator_alias"),
        "batch_handle" => identity!(batch_handle, "batch_handle"),
        "production_batch_id" => identity!(production_batch_id, "production_batch_id"),
        "plan_id" => identity!(plan_id, "plan_id"),
        "plan_sha256" => digest!(plan_sha256, "plan_sha256"),
        "pool_id" => identity!(pool_id, "pool_id"),
        "capability_request" => {
          "contract_version" => identity!(capability_contract_version, "capability contract_version"),
          "fingerprint" => digest!(capability_fingerprint, "capability fingerprint"),
          "artifact_sha256" => digest!(capability_artifact_sha256, "capability artifact_sha256")
        }
      )
      @bytes = JSON.generate(document).freeze
      freeze
    end

    private

    def identity!(value, label)
      valid = value.is_a?(String) && !value.empty? && value == value.strip && !value.match?(/[[:cntrl:]]/)
      raise Error, "#{label} must be a non-empty trimmed string" unless valid

      value.dup.freeze
    end

    def digest!(value, label)
      raise Error, "#{label} must be a lowercase SHA-256" unless value.is_a?(String) && SHA256.match?(value)

      value.dup.freeze
    end

    def deep_freeze(value)
      case value
      when Hash then value.each do |key, item|
        deep_freeze(key)
        deep_freeze(item)
      end
      when Array then value.each { |item| deep_freeze(item) }
      end
      value.freeze
    end
  end

  # Builds the provider-neutral artifact owned by WLO without adding
  # AdventureFinder operation, batch, or provenance fields to it.
  class GenericCapabilityArtifact
    REQUIRED_OLLAMA_KEYS = %w[
      model expected_digest required_context_length require_fully_gpu_resident
    ].freeze
    OPTIONAL_OLLAMA_KEYS = %w[required_gpu_id].freeze

    attr_reader :capability_request, :capability_request_bytes,
                :capability_fingerprint, :capability_artifact_sha256,
                :contract_version

    def initialize(ollama_requirement:, capability_request_class:)
      @capability_request, request = build_capability_request(
        ollama_requirement, capability_request_class
      )
      @capability_request_bytes = JSON.generate(capability_request).freeze
      @capability_fingerprint = request.fingerprint
      @capability_artifact_sha256 = Digest::SHA256.hexdigest(capability_request_bytes).freeze
      @contract_version = request.contract_version
      freeze
    end

    private

    def build_capability_request(source, capability_request_class)
      unless source.is_a?(Hash)
        raise Error, "AFW Ollama requirement must be an object"
      end
      missing = REQUIRED_OLLAMA_KEYS - source.keys
      unknown = source.keys - REQUIRED_OLLAMA_KEYS - OPTIONAL_OLLAMA_KEYS
      raise Error, "AFW Ollama requirement missing field(s): #{missing.join(', ')}" unless missing.empty?
      raise Error, "AFW Ollama requirement has unknown field(s): #{unknown.sort.join(', ')}" unless unknown.empty?

      ollama = REQUIRED_OLLAMA_KEYS.to_h { |key| [key, source.fetch(key)] }
      ollama["required_gpu_id"] = source.fetch("required_gpu_id") if source.key?("required_gpu_id")
      document = {
        "contract_version" => capability_request_class::CONTRACT_VERSION,
        "ollama" => ollama
      }
      bytes = JSON.generate(document)
      request = capability_request_class.new(bytes)
      [request.document, request]
    rescue StandardError => e
      raise unless e.class.name == "WorkloadOrchestrator::Error"

      raise Error, "WLO capability request rejected AFW requirement: #{e.message}"
    end
  end

  class CapabilityArtifacts
    attr_reader :capability_request, :capability_request_bytes,
                :capability_fingerprint, :capability_artifact_sha256,
                :provenance, :provenance_bytes

    def initialize(ollama_requirement:, provenance:, capability_request_class:)
      artifact = GenericCapabilityArtifact.new(
        ollama_requirement:, capability_request_class:
      )
      @capability_request = artifact.capability_request
      @capability_request_bytes = artifact.capability_request_bytes
      @capability_fingerprint = artifact.capability_fingerprint
      @capability_artifact_sha256 = artifact.capability_artifact_sha256
      binding = CapabilityProvenance.new(
        **provenance,
        capability_contract_version: artifact.contract_version,
        capability_fingerprint: capability_fingerprint,
        capability_artifact_sha256: capability_artifact_sha256
      )
      @provenance = binding.document
      @provenance_bytes = binding.bytes
      freeze
    end

    def to_h
      {
        "capability_request" => capability_request,
        "provenance" => provenance
      }.freeze
    end
  end
end
