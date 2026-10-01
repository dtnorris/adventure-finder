# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"
require "yaml"

require "adventure_finder_workspace"
require "adventure_finder_production_context"

class ProductionContextTest < Minitest::Test
  def registry_path
    File.expand_path("../config/production_contexts.yml", __dir__)
  end

  def test_registered_batch_resolves_exact_frozen_identity
    context = AdventureFinderWorkspace::ProductionContextRegistry.new(registry_path).resolve("batch", "39")

    assert_equal "batch 39", context.fetch("handle")
    assert_equal "production-batch-039-fresh-20260930", context.fetch("production_batch_id")
    assert_equal "production-batch-039-fresh-20260930", context.dig("plan", "plan_id")
    assert_equal "0396dadb15bf0ca68238fd4f449ca99e58c3a4ee329dadc8a6e242f5da0ae5d1", context.dig("plan", "sha256")
    assert_equal ["A"], context.fetch("associated_fleets")
    assert Pathname(context.dig("afw", "plan_path")).absolute?
    assert Pathname(context.dig("wlo", "output_root")).absolute?
  end

  def test_registered_fleet_resolves_exact_campaign_context
    context = AdventureFinderWorkspace::ProductionContextRegistry.new(registry_path).resolve("fleet", "A")

    assert_equal "fleet A", context.fetch("handle")
    assert_equal "production-batch-039-fresh-20260930", context.fetch("campaign_id")
    assert_equal ["39"], context.fetch("associated_batches")
    assert_equal "/Users/davidnorris/code/runpod-ollama-fleet-production/output/runpod-fleets", context.dig("rpof", "state_root")
  end

  def test_unknown_handle_fails_closed
    error = assert_raises(AdventureFinderWorkspace::Error) do
      AdventureFinderWorkspace::ProductionContextRegistry.new(registry_path).resolve("batch", "40")
    end

    assert_match(/unknown production context: batch 40/, error.message)
  end

  def test_verifier_checks_plan_and_campaign_identity_without_writes
    Dir.mktmpdir do |dir|
      afw_root = File.join(dir, "afw")
      wlo_root = File.join(dir, "wlo")
      rpof_root = File.join(dir, "rpof")
      workload = File.join(afw_root, "workloads", "batch-39")
      wlo_output = File.join(wlo_root, "output", "batch-39")
      campaign_dir = File.join(rpof_root, "output", "campaign-39")
      state_root = File.join(rpof_root, "output", "runpod-fleets")
      [workload, wlo_output, campaign_dir, state_root].each { |path| FileUtils.mkdir_p(path) }

      plan_path = File.join(workload, "execution-plan.json")
      workload_path = File.join(workload, "workload.yml")
      campaign_path = File.join(campaign_dir, "campaign.json")
      budget_path = File.join(campaign_dir, "budget.json")
      File.write(plan_path, JSON.generate("plan_id" => "batch-39"))
      File.write(workload_path, "---\nworkload_id: batch-39\n")
      File.write(campaign_path, JSON.generate("campaign_id" => "campaign-39"))
      File.write(budget_path, "{}")

      data = {
        "schema_version" => AdventureFinderWorkspace::PRODUCTION_CONTEXT_SCHEMA_VERSION,
        "contexts" => {
          "batch" => {
            "39" => {
              "production_batch_id" => "batch-39",
              "afw" => {"repository_root" => afw_root, "workload_root" => workload, "plan_path" => plan_path},
              "wlo" => {"repository_root" => wlo_root, "output_root" => wlo_output},
              "plan" => {"plan_id" => "batch-39", "sha256" => Digest::SHA256.file(plan_path).hexdigest, "authority" => "fixture"},
              "catalog_provenance" => {"filename" => "catalog.xlsx", "sha256" => "a" * 64, "authority" => "fixture"},
              "associated_fleets" => ["A"]
            }
          },
          "fleet" => {
            "A" => {
              "campaign_id" => "campaign-39",
              "rpof" => {"repository_root" => rpof_root, "campaign_path" => campaign_path, "budget_path" => budget_path, "state_root" => state_root},
              "associated_batches" => ["39"]
            }
          }
        }
      }
      path = File.join(dir, "contexts.yml")
      File.write(path, data.to_yaml)
      registry = AdventureFinderWorkspace::ProductionContextRegistry.new(path)

      assert_empty registry.verify("batch", "39")
      assert_empty registry.verify("fleet", "A")

      File.write(plan_path, JSON.generate("plan_id" => "wrong"))
      failures = registry.verify("batch", "39")
      assert failures.any? { |failure| failure.include?("SHA-256 mismatch") }
      assert failures.any? { |failure| failure.include?("plan_id mismatch") }
    end
  end

  def test_registry_rejects_non_reciprocal_association
    data = YAML.safe_load(File.read(registry_path), permitted_classes: [], aliases: false)
    data.dig("contexts", "fleet", "A", "associated_batches").clear

    Dir.mktmpdir do |dir|
      path = File.join(dir, "contexts.yml")
      File.write(path, data.to_yaml)
      error = assert_raises(AdventureFinderWorkspace::Error) do
        AdventureFinderWorkspace::ProductionContextRegistry.new(path)
      end
      assert_match(/association is not reciprocal/, error.message)
    end
  end
end
