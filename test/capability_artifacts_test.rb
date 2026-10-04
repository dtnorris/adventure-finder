# frozen_string_literal: true

require "json"
require "minitest/autorun"

ROOT = File.expand_path("..", __dir__) unless defined?(ROOT)
WLO_ROOT = ENV.fetch("WLO_REPOSITORY_ROOT", File.expand_path("../workload-orchestrator", ROOT)) unless defined?(WLO_ROOT)
$LOAD_PATH.unshift(File.join(WLO_ROOT, "lib"))

require "workload_orchestrator/ollama_capability_request"
require "adventure_finder_capability_artifacts"

class CapabilityArtifactsTest < Minitest::Test
  DIGEST = "a" * 64

  def test_generic_artifact_is_accepted_by_the_normative_wlo_contract
    artifacts = build_artifacts
    parsed = WorkloadOrchestrator::OllamaCapabilityRequest.new(artifacts.capability_request_bytes)

    assert_equal artifacts.capability_request, parsed.document
    assert_equal artifacts.capability_fingerprint, parsed.fingerprint
    assert_equal "ollama-capability-request/v0.1", parsed.contract_version
    assert_equal %w[contract_version ollama], artifacts.capability_request.keys
    assert_equal %w[
      model expected_digest required_context_length require_fully_gpu_resident required_gpu_id
    ], artifacts.capability_request.fetch("ollama").keys
  end

  def test_provenance_is_separate_and_binds_the_exact_generic_artifact
    artifacts = build_artifacts
    provenance = artifacts.provenance
    identity = provenance.fetch("capability_request")

    assert_equal "adventurefinder-capability-provenance/v0.1", provenance.fetch("contract_version")
    assert_equal %w[
      contract_version operator_alias batch_handle production_batch_id plan_id
      plan_sha256 pool_id capability_request
    ], provenance.keys
    assert_equal "qwen27", provenance.fetch("operator_alias")
    assert_equal "39", provenance.fetch("batch_handle")
    assert_equal "production-batch-039", provenance.fetch("production_batch_id")
    assert_equal "production-batch-039", provenance.fetch("plan_id")
    assert_equal "b" * 64, provenance.fetch("plan_sha256")
    assert_equal "qwen27", provenance.fetch("pool_id")
    assert_equal artifacts.capability_fingerprint, identity.fetch("fingerprint")
    assert_equal artifacts.capability_artifact_sha256, identity.fetch("artifact_sha256")
    assert_equal artifacts.capability_artifact_sha256,
                 Digest::SHA256.hexdigest(artifacts.capability_request_bytes)
  end

  def test_af_provenance_never_appears_in_the_generic_request
    generic = JSON.generate(build_artifacts.capability_request)

    %w[
      qwen27 batch_handle production-batch-039 plan_id plan_sha256 pool_id
      provider fleet campaign budget worker generation endpoint
    ].each do |term|
      refute_includes generic, term
    end
  end

  def test_different_provenance_preserves_generic_bytes_and_fingerprint
    first = build_artifacts
    second = build_artifacts(
      provenance: provenance.merge(
        operator_alias: "another-alias",
        batch_handle: "40",
        production_batch_id: "another-batch",
        plan_id: "another-plan",
        plan_sha256: "c" * 64,
        pool_id: "another-pool"
      )
    )

    assert_equal first.capability_request_bytes, second.capability_request_bytes
    assert_equal first.capability_fingerprint, second.capability_fingerprint
    assert_equal first.capability_artifact_sha256, second.capability_artifact_sha256
    refute_equal first.provenance_bytes, second.provenance_bytes
  end

  def test_every_runtime_field_changes_generic_artifact_and_fingerprint
    original = build_artifacts
    mutations = {
      "model" => "other:latest",
      "expected_digest" => "d" * 64,
      "required_context_length" => 65_536,
      "require_fully_gpu_resident" => false,
      "required_gpu_id" => "NVIDIA L40S"
    }

    mutations.each do |field, value|
      requirement = ollama_requirement.merge(field => value)
      changed = build_artifacts(requirement:)
      refute_equal original.capability_request_bytes, changed.capability_request_bytes, field
      refute_equal original.capability_fingerprint, changed.capability_fingerprint, field
      refute_equal original.capability_artifact_sha256, changed.capability_artifact_sha256, field
    end

    without_gpu = ollama_requirement.reject { |key, _value| key == "required_gpu_id" }
    changed = build_artifacts(requirement: without_gpu)
    refute_equal original.capability_request_bytes, changed.capability_request_bytes
    refute_equal original.capability_fingerprint, changed.capability_fingerprint
  end

  def test_malformed_provenance_fails_closed
    invalid = {
      operator_alias: " ",
      batch_handle: "bad\nhandle",
      plan_sha256: "not-a-digest"
    }

    invalid.each do |field, value|
      error = assert_raises(AdventureFinderWorkspace::Error) do
        build_artifacts(provenance: provenance.merge(field => value))
      end
      assert_includes error.message, field.to_s.tr("_", " ").split.first, field
    end
  end

  def test_no_low_or_rpof_runtime_dependency_is_loaded
    forbidden = $LOADED_FEATURES.grep(/local[_-]ollama[_-]workers|runpod[_-]ollama[_-]fleet/i)
    assert_empty forbidden
  end

  private

  def build_artifacts(requirement: ollama_requirement, provenance: self.provenance)
    AdventureFinderWorkspace::CapabilityArtifacts.new(
      ollama_requirement: requirement,
      provenance:,
      capability_request_class: WorkloadOrchestrator::OllamaCapabilityRequest
    )
  end

  def ollama_requirement
    {
      "model" => "qwen3.6:27b",
      "expected_digest" => DIGEST,
      "required_context_length" => 131_072,
      "require_fully_gpu_resident" => true,
      "required_gpu_id" => "NVIDIA A40"
    }
  end

  def provenance
    {
      operator_alias: "qwen27",
      batch_handle: "39",
      production_batch_id: "production-batch-039",
      plan_id: "production-batch-039",
      plan_sha256: "b" * 64,
      pool_id: "qwen27"
    }
  end
end
