# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"
require "adventure_finder_model_preflight"

# Providers are always separate subprocesses. Set all three repository roots
# to run this offline composition proof; no provider or Ollama service is used.
class CapabilityCompositionTest < Minitest::Test
  def setup
    @repos = %w[WLO_REPO_ROOT LOW_REPO_ROOT RPOF_REPO_ROOT].to_h { |key| [key, ENV[key]] }
    skip "set WLO_REPO_ROOT, LOW_REPO_ROOT and RPOF_REPO_ROOT for composition proof" if @repos.values.any?(&:nil?)
    require File.join(@repos.fetch("WLO_REPO_ROOT"), "lib/workload_orchestrator")
    @root = Dir.mktmpdir("capability-composition-")
  end

  def teardown
    FileUtils.rm_rf(@root) if @root
  end

  def test_frozen_plan_bytes_compose_without_provenance_or_authority_leakage
    first = derive("39", "primary", "pool-a", requirement)
    second = derive("40", "alternate", "pool-b", requirement)
    refute_equal first.provenance, second.provenance
    assert_equal first.capability_request_bytes, second.capability_request_bytes
    assert_equal first.capability_fingerprint, second.capability_fingerprint
    assert_equal %w[contract_version ollama], first.capability_request.keys
    assert_equal requirement, first.capability_request.fetch("ollama")

    paths = [first, second].each_with_index.map { |a, i| artifact(a, "base-#{i}") }
    low = probe("low", paths)
    rpof = probe("rpof", paths)
    [low, rpof].each do |results|
      assert_equal [first.capability_fingerprint] * 2, results.map { |r| r.fetch("fingerprint") }
      assert_equal [first.capability_artifact_sha256] * 2, results.map { |r| r.fetch("artifact_sha256") }
      assert_equal results.first.fetch("generation_id"), results.last.fetch("generation_id")
    end
    assert_equal rpof.first.fetch("bringup_identity"), rpof.last.fetch("bringup_identity")
    assert rpof.last.fetch("historical_read_unchanged")
    assert rpof.last.fetch("authority_unchanged")
    assert rpof.last.fetch("no_replacement")
    assert_equal 1, rpof.last.fetch("controller_launches")
    assert low.all? { |r| r.fetch("read_only_publication") }
  end

  def test_each_runtime_change_changes_both_independent_fingerprints_and_bringup_identity
    baseline = derive("39", "primary", "pool-a", requirement)
    changes = {
      "model" => "different:latest", "expected_digest" => "b" * 64,
      "required_context_length" => 262_144, "require_fully_gpu_resident" => false,
      "required_gpu_id" => "NVIDIA L40S", "gpu_absent" => nil
    }
    artifacts = [baseline] + changes.map do |key, value|
      changed = requirement.dup
      key == "gpu_absent" ? changed.delete("required_gpu_id") : changed[key] = value
      AdventureFinderWorkspace::CapabilityArtifacts.new(
        ollama_requirement: changed,
        provenance: baseline.provenance.reject { |k, _| %w[contract_version capability_request].include?(k) }.transform_keys(&:to_sym),
        capability_request_class: WorkloadOrchestrator::OllamaCapabilityRequest
      )
    end
    assert_equal artifacts.length, artifacts.map(&:capability_fingerprint).uniq.length
    paths = artifacts.each_with_index.map { |a, i| artifact(a, "variant-#{i}") }
    low = probe("low", paths)
    rpof = probe("rpof", paths, "--identities")
    artifacts.each_with_index do |a, i|
      assert_equal a.capability_fingerprint, low[i].fetch("fingerprint")
      assert_equal a.capability_fingerprint, rpof[i].fetch("fingerprint")
    end
    assert_equal artifacts.length, rpof.map { |r| r.fetch("bringup_identity") }.uniq.length
    assert_equal false, low[4].dig("evidence", "models", 0, "fully_gpu_resident")
    assert_equal "unsupported_false_residency", rpof[4].fetch("campaign_result")
  end

  def test_plan_policy_and_optional_gpu_are_preserved
    without_gpu = requirement.reject { |key, _| key == "required_gpu_id" }
    result = derive("39", "primary", "pool-a", without_gpu)
    assert_equal without_gpu, result.capability_request.fetch("ollama")
    # False is a valid generic v0.1 capability, but v0.3 plans cannot express
    # it. Do not change the plan contract merely to fabricate this variation.
    error = assert_raises(WorkloadOrchestrator::Error) do
      derive("39", "primary", "pool-a", requirement.merge("require_fully_gpu_resident" => false))
    end
    assert_includes error.message, "must be true"
  end

  private

  def requirement
    {
      "model" => "qwen3.6:35b-a3b", "expected_digest" => "a" * 64,
      "required_context_length" => 131_072, "require_fully_gpu_resident" => true,
      "required_gpu_id" => "NVIDIA A40"
    }
  end

  def derive(batch, alias_name, pool, ollama)
    root = Dir.mktmpdir("frozen-", @root)
    FileUtils.mkdir_p(File.join(root, "afw/workloads"))
    plan_path = File.join(root, "afw/workloads/plan.json")
    plan = {
      "contract_version" => "wlo-execution-plan/v0.3", "plan_id" => "production-batch-#{batch}",
      "failure_policy" => { "max_consecutive_failures" => 2, "max_total_failures" => 4 },
      "pools" => [
        { "pool_id" => pool, "required_labels" => ["inference", "label-#{batch}"], "requirements" => { "ollama" => ollama } },
        { "pool_id" => "decoy", "requirements" => { "ollama" => requirement.merge("model" => "decoy:latest") } }
      ],
      "jobs" => [{ "job_id" => "job-1", "pool_id" => pool, "argv" => ["must-not-execute"] }]
    }
    File.binwrite(plan_path, JSON.pretty_generate(plan) + "\n")
    WorkloadOrchestrator::Plan.load(plan_path)
    frozen_bytes = File.binread(plan_path)
    registry_path = File.join(root, "contexts.yml")
    File.write(registry_path, YAML.dump(
      "schema_version" => "adventurefinder-production-context/v0.1",
      "contexts" => { "batch" => { batch => {
        "production_batch_id" => plan.fetch("plan_id"),
        "afw" => { "repository_root" => "afw", "workload_root" => "afw/workloads", "plan_path" => "afw/workloads/plan.json" },
        "wlo" => { "repository_root" => "wlo", "output_root" => "output" },
        "plan" => { "plan_id" => plan.fetch("plan_id"), "sha256" => Digest::SHA256.hexdigest(frozen_bytes) },
        "model_aliases" => { alias_name => [pool] }, "associated_fleets" => []
      } }, "fleet" => {} }
    ))
    registry = AdventureFinderWorkspace::ProductionContextRegistry.new(registry_path, workspace_root: root)
    result = AdventureFinderWorkspace::ModelPreflight.new(
      registry:, capability_request_class: WorkloadOrchestrator::OllamaCapabilityRequest
    ).resolve_artifacts(batch_handle: batch, alias_name:)
    assert_equal [batch, alias_name, pool], result.provenance.values_at("batch_handle", "operator_alias", "pool_id")
    assert_equal frozen_bytes, File.binread(plan_path)
    result
  end

  def artifact(result, name)
    path = File.join(@root, "#{name}.json")
    File.binwrite(path, result.capability_request_bytes)
    path
  end

  def probe(provider, paths, *flags)
    repo = @repos.fetch("#{provider.upcase}_REPO_ROOT")
    script = File.expand_path("../support/bd04f/#{provider}_probe.rb", __dir__)
    stdout, stderr, status = Open3.capture3(
      { "BUNDLE_GEMFILE" => File.join(repo, "Gemfile"), "BUNDLE_LOCKFILE" => nil, "RUBYLIB" => File.join(repo, "lib") },
      "bundle", "exec", RbConfig.ruby, "-I#{repo}/lib", script, *flags, *paths, chdir: repo
    )
    assert status.success?, "#{provider} probe failed: #{stderr}\n#{stdout}"
    JSON.parse(stdout)
  end
end
