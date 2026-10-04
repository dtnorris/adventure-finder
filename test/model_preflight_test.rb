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

WLO_ROOT = ENV.fetch(
  "WLO_REPOSITORY_ROOT", File.expand_path("../../workload-orchestrator", __dir__)
) unless defined?(WLO_ROOT)
$LOAD_PATH.unshift(File.join(WLO_ROOT, "lib"))
require "workload_orchestrator/ollama_capability_request"

class ModelPreflightTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DIGEST = "a" * 64
  MODEL_ALIASES = {
    "qwen35" => ["qwen"], "qwen27" => ["qwen27"], "gemma" => ["gemma"], "gptoss" => ["gptoss"]
  }.freeze

  def test_known_alias_preserves_exact_pool_requirement_and_plan_binding
    with_fixture do |fixture|
      result = resolve(fixture, "qwen27")

      request = result.fetch("capability_request")
      provenance = result.fetch("provenance")
      identity = provenance.fetch("capability_request")

      assert_equal "ollama-capability-request/v0.1", request.fetch("contract_version")
      assert_equal exact_ollama, request.fetch("ollama")
      assert_equal "adventurefinder-capability-provenance/v0.1", provenance.fetch("contract_version")
      assert_equal "39", provenance.fetch("batch_handle")
      assert_equal "production-batch-039", provenance.fetch("production_batch_id")
      assert_equal "production-batch-039", provenance.fetch("plan_id")
      assert_equal fixture.fetch(:plan_sha256), provenance.fetch("plan_sha256")
      assert_equal "qwen27", provenance.fetch("operator_alias")
      assert_equal "qwen27", provenance.fetch("pool_id")
      parsed = WorkloadOrchestrator::OllamaCapabilityRequest.new(JSON.generate(request))
      assert_equal parsed.fingerprint, identity.fetch("fingerprint")
      assert_equal Digest::SHA256.hexdigest(JSON.generate(request)), identity.fetch("artifact_sha256")
    end
  end

  def test_af_project_root_override_and_json_output_are_deterministic
    with_fixture do |fixture|
      argv = [
        {
          "AF_PROJECT_ROOT" => fixture.fetch(:root),
          "RUBYLIB" => File.join(WLO_ROOT, "lib"),
          "RUBYOPT" => "-rworkload_orchestrator/ollama_capability_request"
        },
        RbConfig.ruby, File.join(ROOT, "bin", "af-model"),
        "preflight", "batch", "39", "qwen35", "--json", "--registry", fixture.fetch(:registry)
      ]
      first, first_error, first_status = Open3.capture3(*argv, chdir: ROOT)
      second, second_error, second_status = Open3.capture3(*argv, chdir: ROOT)

      assert first_status.success?, first_error
      assert second_status.success?, second_error
      assert_equal first, second
      parsed = JSON.parse(first)
      assert_equal ["qwen35", "qwen"],
                   parsed.fetch("provenance").values_at("operator_alias", "pool_id")
      assert_equal qwen35_ollama, parsed.dig("capability_request", "ollama")
    end
  end

  def test_human_output_is_compact
    with_fixture do |fixture|
      stdout, stderr, status = run_cli(fixture, "qwen35")

      assert status.success?, stderr
      assert_equal 12, stdout.lines.length
      assert_includes stdout, "Alias: qwen35\nPool: qwen\nModel: qwen3.6:35b-a3b\n"
      assert_includes stdout, "Plan SHA: #{fixture.fetch(:plan_sha256)}\n"
      assert_includes stdout, "Capability fingerprint: "
      assert_includes stdout, "Capability artifact SHA: "
    end
  end

  def test_qwen35_preserves_frozen_pool_requirement_and_plan_binding
    with_fixture do |fixture|
      result = resolve(fixture, "qwen35")
      assert_equal MODEL_ALIASES, YAML.safe_load(File.read(File.join(ROOT, "config", "production_contexts.yml")))
                                      .dig("contexts", "batch", "39", "model_aliases")
      assert_equal ["qwen35", "qwen"],
                   result.fetch("provenance").values_at("operator_alias", "pool_id")
      assert_equal qwen35_ollama, result.dig("capability_request", "ollama")
      assert_equal ["production-batch-039", fixture.fetch(:plan_sha256)],
                   result.fetch("provenance").values_at("plan_id", "plan_sha256")
      assert_raises(AdventureFinderWorkspace::Error) { resolve(fixture, "qwen") }
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

  def test_af_production_requires_full_gpu_residency
    with_fixture(
      requirement_mutation: ->(row) { row["require_fully_gpu_resident"] = false }
    ) do |fixture|
      error = assert_raises(AdventureFinderWorkspace::Error) { resolve(fixture, "qwen27") }
      assert_includes error.message, "require_fully_gpu_resident must be true"
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
    AdventureFinderWorkspace::ModelPreflight.new(
      registry:, capability_request_class: WorkloadOrchestrator::OllamaCapabilityRequest
    ).resolve(batch_handle: "39", alias_name:)
  end

  def with_fixture(aliases: MODEL_ALIASES, plan_id: "production-batch-039", requirement_mutation: nil)
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
          {"pool_id" => "qwen", "required_labels" => ["inference"], "requirements" => {"ollama" => qwen35_ollama}},
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

  def qwen35_ollama
    exact_ollama.merge("model" => "qwen3.6:35b-a3b")
  end

  def run_cli(fixture, alias_name)
    Open3.capture3(
      {
        "AF_PROJECT_ROOT" => fixture.fetch(:root),
        "RUBYLIB" => File.join(WLO_ROOT, "lib"),
        "RUBYOPT" => "-rworkload_orchestrator/ollama_capability_request"
      },
      RbConfig.ruby, File.join(ROOT, "bin", "af-model"),
      "preflight", "batch", "39", alias_name, "--registry", fixture.fetch(:registry), chdir: ROOT
    )
  end

  def tree_digest(root)
    files = Dir[File.join(root, "**", "*")].select { |path| File.file?(path) }.sort
    Digest::SHA256.hexdigest(files.map { |path| [path.delete_prefix(root), File.binread(path)] }.flatten.join("\0"))
  end
end
