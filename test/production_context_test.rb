# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"
require "yaml"

require "adventure_finder_workspace"
require "adventure_finder_production_context"

class ProductionContextTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  REGISTRY_PATH = File.join(ROOT, "config", "production_contexts.yml")

  def test_registered_context_uses_manifest_default_workspace_root
    manifest = AdventureFinderWorkspace::Manifest.new(File.join(ROOT, "repos.yml"))
    context = registry(workspace_root: manifest.workspace_root_default).resolve("batch", "39")

    assert_equal File.join(manifest.workspace_root_default, "af-workloads-production"),
                 context.dig("afw", "repository_root")
    assert_equal File.join(
      manifest.workspace_root_default,
      "af-workloads-production/workloads/production-batch-039-fresh-20260930/execution-plan.json"
    ), context.dig("afw", "plan_path")
    assert_equal "0396dadb15bf0ca68238fd4f449ca99e58c3a4ee329dadc8a6e242f5da0ae5d1",
                 context.dig("plan", "sha256")
    assert_equal File.join(manifest.workspace_root_default, "local-ollama-workers"),
                 context.dig("local_workers", "repository_root")
    assert_equal %w[local remote], context.fetch("worker_sources")
  end

  def test_workspace_override_resolves_the_same_context_beneath_temporary_root
    Dir.mktmpdir do |root|
      context = registry(workspace_root: root).resolve("fleet", "A")

      assert_equal File.join(root, "runpod-ollama-fleet-production"),
                   context.dig("rpof", "repository_root")
      assert_equal File.join(
        root,
        "runpod-ollama-fleet-production/output/production-batch-039-fresh-20260930/campaign.json"
      ), context.dig("rpof", "campaign_path")
      assert_equal ["39"], context.fetch("associated_batches")
    end
  end

  def test_checked_in_registry_contains_no_absolute_or_machine_specific_paths
    source = File.read(REGISTRY_PATH)
    refute_includes source, "/Users/davidnorris/code"
    data = YAML.safe_load(source, permitted_classes: [], aliases: false)

    path_values(data).each do |path|
      refute Pathname(path).absolute?, path
      refute_includes Pathname(path).each_filename.to_a, "..", path
    end
  end

  def test_path_traversal_fails_closed
    data = checked_in_data
    data.dig("contexts", "batch", "39", "afw", "plan_path").replace("../outside.json")

    Dir.mktmpdir do |dir|
      path = File.join(dir, "contexts.yml")
      File.write(path, data.to_yaml)
      error = assert_raises(AdventureFinderWorkspace::Error) do
        registry(path:, workspace_root: dir)
      end
      assert_includes error.message, "must stay beneath the workspace root"
    end
  end

  def test_unknown_handle_fails_closed
    error = assert_raises(AdventureFinderWorkspace::Error) do
      registry(workspace_root: Dir.tmpdir).resolve("batch", "40")
    end
    assert_match(/unknown production context: batch 40/, error.message)
  end

  def test_batch_verifier_checks_plan_identity_and_hash
    with_fixture_workspace do |fixture|
      verifier = registry(path: fixture.fetch(:registry), workspace_root: fixture.fetch(:root))
      assert_empty verifier.verify("batch", "39")

      plan_path = fixture.fetch(:plan_path)
      File.write(plan_path, JSON.generate("plan_id" => "wrong"))
      failures = verifier.verify("batch", "39")
      assert failures.any? { |failure| failure.include?("plan SHA-256 mismatch") }
      assert failures.any? { |failure| failure.include?("plan_id mismatch") }
    end
  end

  def test_fleet_verifier_accepts_consistent_rpof_identity_chain
    with_fixture_workspace do |fixture|
      failures = registry(path: fixture.fetch(:registry), workspace_root: fixture.fetch(:root))
                 .verify("fleet", "A")
      assert_empty failures
    end
  end

  def test_fleet_verifier_rejects_campaign_id_drift
    with_fixture_workspace do |fixture|
      mutate_json(fixture.fetch(:campaign_path)) { |value| value["campaign_id"] = "different-campaign" }
      failures = verify_fleet(fixture)
      assert failures.any? { |failure| failure.include?("campaign ID drift") }
    end
  end

  def test_fleet_verifier_rejects_campaign_identity_hash_drift
    with_fixture_workspace do |fixture|
      mutate_json(fixture.fetch(:campaign_path)) do |value|
        value.fetch("profiles").first["model"] = "different:model"
      end
      failures = verify_fleet(fixture)
      assert failures.any? { |failure| failure.include?("campaign identity hash drift") }
    end
  end

  def test_fleet_verifier_rejects_budget_bound_to_different_campaign
    with_fixture_workspace do |fixture|
      mutate_json(fixture.fetch(:budget_path)) do |value|
        identity = value.fetch("campaign_identity")
        identity["campaign_id"] = "different-campaign"
        value["campaign_identity_sha256"] = Digest::SHA256.hexdigest(JSON.generate(identity))
      end
      failures = verify_fleet(fixture)
      assert failures.any? { |failure| failure.include?("budget is bound to campaign") }
    end
  end

  def test_fleet_verifier_rejects_budget_identity_hash_mismatch
    with_fixture_workspace do |fixture|
      mutate_json(fixture.fetch(:budget_path)) do |value|
        value["campaign_identity_sha256"] = "0" * 64
      end
      failures = verify_fleet(fixture)
      assert failures.any? { |failure| failure.include?("budget identity/hash mismatch") }
    end
  end

  def test_fleet_verifier_rejects_durable_budget_binding_mismatch
    with_fixture_workspace do |fixture|
      mutate_json(fixture.fetch(:binding_path)) { |value| value["binding_sha256"] = "0" * 64 }
      failures = verify_fleet(fixture)
      assert failures.any? { |failure| failure.include?("budget binding hash mismatch") }
    end
  end

  def test_fleet_verifier_reports_missing_campaign_and_budget_files
    with_fixture_workspace do |fixture|
      File.delete(fixture.fetch(:campaign_path))
      File.delete(fixture.fetch(:budget_path))
      failures = verify_fleet(fixture)
      assert failures.any? { |failure| failure.include?("RPOF campaign is not a file") }
      assert failures.any? { |failure| failure.include?("RPOF budget is not a file") }
    end
  end

  def test_default_human_rendering_is_compact_and_json_remains_absolute
    Dir.mktmpdir do |root|
      stdout, stderr, status = Open3.capture3(
        {"AF_PROJECT_ROOT" => root},
        RbConfig.ruby, File.join(ROOT, "bin", "af-workspace"),
        "context", "batch", "39", "--registry", REGISTRY_PATH,
        chdir: ROOT
      )
      assert status.success?, stderr
      assert_includes stdout, "Batch: 39\n"
      assert_includes stdout, "AFW: #{root}/af-workloads-production\n"
      assert_includes stdout, "Plan: workloads/production-batch-039-fresh-20260930/execution-plan.json\n"
      assert_includes stdout, "Plan SHA: 0396dadb15bf…\n"
      refute_match(/^---$/, stdout)

      json, json_stderr, json_status = Open3.capture3(
        {"AF_PROJECT_ROOT" => root},
        RbConfig.ruby, File.join(ROOT, "bin", "af-workspace"),
        "context", "fleet", "A", "--json", "--registry", REGISTRY_PATH,
        chdir: ROOT
      )
      assert json_status.success?, json_stderr
      parsed = JSON.parse(json)
      assert_equal File.join(root, "runpod-ollama-fleet-production"),
                   parsed.dig("rpof", "repository_root")
    end
  end

  def test_registry_rejects_non_reciprocal_association
    data = checked_in_data
    data.dig("contexts", "fleet", "A", "associated_batches").clear

    Dir.mktmpdir do |dir|
      path = File.join(dir, "contexts.yml")
      File.write(path, data.to_yaml)
      error = assert_raises(AdventureFinderWorkspace::Error) do
        registry(path:, workspace_root: dir)
      end
      assert_match(/association is not reciprocal/, error.message)
    end
  end

  private

  def registry(path: REGISTRY_PATH, workspace_root:)
    AdventureFinderWorkspace::ProductionContextRegistry.new(path, workspace_root:)
  end

  def checked_in_data
    YAML.safe_load(File.read(REGISTRY_PATH), permitted_classes: [], aliases: false)
  end

  def path_values(data)
    batch = data.dig("contexts", "batch", "39")
    fleet = data.dig("contexts", "fleet", "A")
    %w[repository_root workload_root plan_path].map { |key| batch.dig("afw", key) } +
      %w[repository_root output_root].map { |key| batch.dig("wlo", key) } +
      [batch.dig("local_workers", "repository_root")] +
      %w[repository_root campaign_path budget_path state_root binding_path].map do |key|
        fleet.dig("rpof", key)
      end
  end

  def verify_fleet(fixture)
    registry(path: fixture.fetch(:registry), workspace_root: fixture.fetch(:root)).verify("fleet", "A")
  end

  def mutate_json(path)
    value = JSON.parse(File.read(path))
    yield value
    File.write(path, JSON.pretty_generate(value) + "\n")
  end

  def with_fixture_workspace
    Dir.mktmpdir do |root|
      campaign_id = "campaign-39"
      afw_root = File.join(root, "afw")
      workload_root = File.join(afw_root, "workloads", campaign_id)
      plan_path = File.join(workload_root, "execution-plan.json")
      wlo_root = File.join(root, "wlo")
      output_root = File.join(wlo_root, "output", campaign_id)
      rpof_root = File.join(root, "rpof")
      declaration_root = File.join(rpof_root, "output", campaign_id)
      state_root = File.join(rpof_root, "output", "runpod-fleets")
      binding_path = File.join(state_root, "campaign-budgets", Digest::SHA256.hexdigest(campaign_id), "binding.json")
      [workload_root, output_root, declaration_root, File.dirname(binding_path)].each { |path| FileUtils.mkdir_p(path) }

      File.write(plan_path, JSON.generate("plan_id" => campaign_id))
      campaign = campaign_document(campaign_id)
      campaign_path = File.join(declaration_root, "campaign.json")
      File.write(campaign_path, JSON.pretty_generate(campaign) + "\n")
      budget = budget_document(campaign)
      budget_path = File.join(declaration_root, "budget.json")
      File.write(budget_path, JSON.pretty_generate(budget) + "\n")
      binding_sha256 = Digest::SHA256.hexdigest(JSON.generate(budget))
      File.write(
        binding_path,
        JSON.pretty_generate(
          "contract_version" => "rpof-capacity-campaign-budget-state/v0.1",
          "binding_sha256" => binding_sha256,
          "binding" => budget
        ) + "\n"
      )

      data = {
        "schema_version" => AdventureFinderWorkspace::PRODUCTION_CONTEXT_SCHEMA_VERSION,
        "contexts" => {
          "batch" => {
            "39" => {
              "production_batch_id" => campaign_id,
              "afw" => {
                "repository_root" => "afw",
                "workload_root" => "afw/workloads/#{campaign_id}",
                "plan_path" => "afw/workloads/#{campaign_id}/execution-plan.json"
              },
              "wlo" => {
                "repository_root" => "wlo",
                "output_root" => "wlo/output/#{campaign_id}"
              },
              "plan" => {
                "plan_id" => campaign_id,
                "sha256" => Digest::SHA256.file(plan_path).hexdigest,
                "authority" => "fixture"
              },
              "associated_fleets" => ["A"]
            }
          },
          "fleet" => {
            "A" => {
              "campaign_id" => campaign_id,
              "rpof" => {
                "repository_root" => "rpof",
                "campaign_path" => "rpof/output/#{campaign_id}/campaign.json",
                "budget_path" => "rpof/output/#{campaign_id}/budget.json",
                "state_root" => "rpof/output/runpod-fleets",
                "binding_path" => Pathname(binding_path).relative_path_from(Pathname(root)).to_s
              },
              "associated_batches" => ["39"]
            }
          }
        }
      }
      registry_path = File.join(root, "contexts.yml")
      File.write(registry_path, data.to_yaml)
      yield(
        root:, registry: registry_path, plan_path:, campaign_path:, budget_path:, binding_path:
      )
    end
  end

  def campaign_document(campaign_id)
    {
      "contract_version" => "rpof-capacity-campaign/v0.1",
      "campaign_id" => campaign_id,
      "max_workers" => 1,
      "max_hourly_rate_usd" => 1.0,
      "profiles" => [
        {
          "profile_id" => "qwen",
          "model" => "qwen:test",
          "expected_digest" => "a" * 64,
          "required_context_length" => 131_072,
          "require_fully_gpu_resident" => true,
          "min_workers" => 1,
          "desired_workers" => 1,
          "max_workers" => 1
        }
      ]
    }
  end

  def budget_document(campaign)
    campaign_sha256 = Digest::SHA256.hexdigest(JSON.generate(campaign))
    identity = {
      "contract_version" => "rpof-capacity-campaign-identity/v0.1",
      "campaign_id" => campaign.fetch("campaign_id"),
      "campaign_sha256" => campaign_sha256,
      "hardware_qualification_sha256" => "b" * 64
    }
    {
      "contract_version" => "rpof-capacity-campaign-budget/v0.1",
      "campaign_identity" => identity,
      "campaign_identity_sha256" => Digest::SHA256.hexdigest(JSON.generate(identity)),
      "budget_id" => "budget-39",
      "max_cumulative_compute_usd" => 10.0,
      "max_aggregate_hourly_rate_usd" => 1.0,
      "max_workers" => 1,
      "max_runtime_seconds" => 3600.0,
      "guardian_poll_seconds" => 5.0,
      "orchestrator_heartbeat_timeout_seconds" => 30.0,
      "teardown_reserve_seconds" => 120.0
    }
  end
end
