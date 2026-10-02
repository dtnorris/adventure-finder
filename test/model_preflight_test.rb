# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

require "adventure_finder_workspace"
require "adventure_finder_production_context"
require "adventure_finder_model_preflight"

class ModelPreflightTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DIGEST = "a" * 64

  def test_known_alias_preserves_exact_pool_requirement_and_plan_binding
    with_fixture do |fixture|
      result = resolve(fixture, "qwen27")

      assert_equal "adventurefinder-model-requirement/v0.1", result.fetch("contract_version")
      assert_equal "39", result.fetch("batch_handle")
      assert_equal "production-batch-039", result.fetch("production_batch_id")
      assert_equal "production-batch-039", result.fetch("plan_id")
      assert_equal fixture.fetch(:plan_sha256), result.fetch("plan_sha256")
      assert_equal "qwen27", result.fetch("pool_id")
      assert_equal %w[inference], result.fetch("required_labels")
      assert_equal exact_ollama, result.fetch("ollama")
    end
  end

  def test_af_project_root_override_and_json_output_are_deterministic
    with_fixture do |fixture|
      argv = [
        {"AF_PROJECT_ROOT" => fixture.fetch(:root)}, RbConfig.ruby, File.join(ROOT, "bin", "af-model"),
        "preflight", "batch", "39", "qwen27", "--json", "--registry", fixture.fetch(:registry)
      ]
      first, first_error, first_status = Open3.capture3(*argv, chdir: ROOT)
      second, second_error, second_status = Open3.capture3(*argv, chdir: ROOT)

      assert first_status.success?, first_error
      assert second_status.success?, second_error
      assert_equal first, second
      assert_equal exact_ollama, JSON.parse(first).fetch("ollama")
    end
  end

  def test_human_output_is_compact
    with_fixture do |fixture|
      stdout, stderr, status = run_cli(fixture, "qwen27")

      assert status.success?, stderr
      assert_equal 9, stdout.lines.length
      assert_includes stdout, "Pool: qwen27\n"
      assert_includes stdout, "Model: qwen3.6:27b\n"
      assert_includes stdout, "Plan SHA: #{fixture.fetch(:plan_sha256)}\n"
    end
  end

  def test_unknown_alias_fails_closed
    with_fixture do |fixture|
      error = assert_raises(AdventureFinderWorkspace::Error) { resolve(fixture, "unknown") }
      assert_includes error.message, "unknown model alias"
    end
  end

  def test_ambiguous_alias_fails_closed
    with_fixture(aliases: {"qwen27" => %w[qwen27 backup]}) do |fixture|
      error = assert_raises(AdventureFinderWorkspace::Error) { resolve(fixture, "qwen27") }
      assert_includes error.message, "is ambiguous"
    end
  end

  def test_absent_pool_fails_closed
    with_fixture(aliases: {"qwen27" => ["missing"]}) do |fixture|
      error = assert_raises(AdventureFinderWorkspace::Error) { resolve(fixture, "qwen27") }
      assert_includes error.message, "absent pool"
    end
  end

  def test_plan_sha_drift_fails_before_resolution
    with_fixture do |fixture|
      File.open(fixture.fetch(:plan), "a") { |file| file.write(" ") }
      error = assert_raises(AdventureFinderWorkspace::Error) { resolve(fixture, "qwen27") }
      assert_includes error.message, "plan SHA-256 mismatch"
    end
  end

  def test_plan_id_mismatch_fails_closed
    with_fixture(plan_id: "wrong-plan") do |fixture|
      error = assert_raises(AdventureFinderWorkspace::Error) { resolve(fixture, "qwen27") }
      assert_includes error.message, "plan_id mismatch"
    end
  end

  def test_malformed_requirements_fail_closed
    mutations = {
      "missing model" => ->(row) { row.delete("model") },
      "invalid digest" => ->(row) { row["expected_digest"] = "abc" },
      "invalid context" => ->(row) { row["required_context_length"] = 0 },
      "missing residency" => ->(row) { row.delete("require_fully_gpu_resident") },
      "unsupported backend" => ->(row) { row.replace("model" => "not-ollama") }
    }

    mutations.each do |label, mutation|
      with_fixture(requirement_mutation: mutation) do |fixture|
        assert_raises(AdventureFinderWorkspace::Error, label) { resolve(fixture, "qwen27") }
      end
    end
  end

  def test_preflight_is_read_only
    with_fixture do |fixture|
      before = tree_digest(fixture.fetch(:root))
      resolve(fixture, "qwen27")
      assert_equal before, tree_digest(fixture.fetch(:root))
    end
  end

  private

  def resolve(fixture, alias_name)
    registry = AdventureFinderWorkspace::ProductionContextRegistry.new(
      fixture.fetch(:registry), workspace_root: fixture.fetch(:root)
    )
    AdventureFinderWorkspace::ModelPreflight.new(registry:).resolve(batch_handle: "39", alias_name:)
  end

  def with_fixture(aliases: {"qwen27" => ["qwen27"]}, plan_id: "production-batch-039", requirement_mutation: nil)
    Dir.mktmpdir("af-model-preflight-") do |root|
      plan_path = File.join(root, "af-workloads-production", "workloads", "production-batch-039", "execution-plan.json")
      FileUtils.mkdir_p(File.dirname(plan_path))
      requirement = exact_ollama
      requirement_mutation&.call(requirement)
      plan = {
        "contract_version" => "wlo-execution-plan/v0.3",
        "plan_id" => plan_id,
        "failure_policy" => {"max_consecutive_failures" => 2, "max_total_failures" => 3},
        "pools" => [
          {"pool_id" => "qwen27", "required_labels" => ["inference"], "requirements" => {"ollama" => requirement}},
          {"pool_id" => "backup", "requirements" => {"ollama" => exact_ollama}}
        ],
        "jobs" => [{"job_id" => "job-1", "pool_id" => "qwen27", "argv" => ["true"]}]
      }
      File.write(plan_path, JSON.pretty_generate(plan) + "\n")
      sha256 = Digest::SHA256.file(plan_path).hexdigest
      registry_path = File.join(root, "contexts.yml")
      File.write(registry_path, YAML.dump(
        "schema_version" => "adventurefinder-production-context/v0.1",
        "contexts" => {
          "batch" => {
            "39" => {
              "production_batch_id" => "production-batch-039",
              "afw" => {
                "repository_root" => "af-workloads-production",
                "workload_root" => "af-workloads-production/workloads/production-batch-039",
                "plan_path" => "af-workloads-production/workloads/production-batch-039/execution-plan.json"
              },
              "wlo" => {"repository_root" => "wlo", "output_root" => "wlo/output/production-batch-039"},
              "plan" => {"plan_id" => "production-batch-039", "sha256" => sha256},
              "model_aliases" => aliases,
              "associated_fleets" => []
            }
          },
          "fleet" => {}
        }
      ))
      yield root:, plan: plan_path, plan_sha256: sha256, registry: registry_path
    end
  end

  def exact_ollama
    {
      "model" => "qwen3.6:27b",
      "expected_digest" => DIGEST,
      "required_context_length" => 131_072,
      "require_fully_gpu_resident" => true,
      "required_gpu_id" => "NVIDIA A40"
    }
  end

  def run_cli(fixture, alias_name)
    Open3.capture3(
      {"AF_PROJECT_ROOT" => fixture.fetch(:root)}, RbConfig.ruby, File.join(ROOT, "bin", "af-model"),
      "preflight", "batch", "39", alias_name, "--registry", fixture.fetch(:registry), chdir: ROOT
    )
  end

  def tree_digest(root)
    files = Dir[File.join(root, "**", "*")].select { |path| File.file?(path) }.sort
    Digest::SHA256.hexdigest(files.map { |path| [path.delete_prefix(root), File.binread(path)] }.flatten.join("\0"))
  end
end
