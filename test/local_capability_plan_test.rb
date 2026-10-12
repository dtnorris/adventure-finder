# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__) unless defined?(ROOT)
require_relative "support/wlo_contract"
require File.join(WLO_ROOT, "lib", "workload_orchestrator", "plan.rb")
require "adventure_finder_local_capability_plan"
require "adventure_finder_catalog_ingest"

class LocalCapabilityPlanTest < Minitest::Test
  ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  WORKLOAD = "operation-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

  def setup
    @temporary = Dir.mktmpdir("local-capability-plan")
    @front = File.join(@temporary, "detached front")
    @components = File.join(@temporary, "components")
    @afw = File.join(@components, "af-workloads")
    @manifest = File.join(@afw, "workloads", WORKLOAD)
    FileUtils.mkdir_p(@manifest)
    write_fixture
  end

  def teardown
    FileUtils.remove_entry(@temporary) if @temporary && File.exist?(@temporary)
  end

  def test_groups_only_exact_capabilities_and_preserves_every_pool_job_and_constraint
    document = planner.call(operation_id: ID)

    assert_equal "adventurefinder-local-capability-plan/v0.1", document.fetch("contract_version")
    assert_equal ID, document.dig("operation", "operation_id")
    assert_equal WORKLOAD, document.dig("workload", "workload_id")
    assert_equal @plan_sha, document.dig("workload", "plan_sha256")
    assert_equal({"capability_count" => 5, "pool_count" => 6, "job_count" => 7},
                 document.fetch("accounting"))

    capabilities = document.fetch("capabilities")
    shared = capabilities.first
    assert_equal %w[shared-a shared-b], shared.fetch("pools").map { |pool| pool.fetch("pool_id") }
    assert_equal [["local", "large"], ["local", "batch"]],
                 shared.fetch("pools").map { |pool| pool.fetch("required_labels") }
    assert_equal %w[job-1 job-3 job-7], document.dig("sequence", 0, "job_ids")
    assert_equal %w[job-1 job-2 job-3 job-4 job-5 job-6 job-7],
                 document.fetch("sequence").flat_map { |step| step.fetch("job_ids") }.sort

    exact_requests = capabilities.map { |row| row.dig("capability_request", "ollama") }
    assert_includes exact_requests.map { |row| row.fetch("model") }, "unfamiliar-local-model:latest"
    assert_includes exact_requests.map { |row| row.fetch("required_context_length") }, 65_536
    assert_includes exact_requests.map { |row| row["required_gpu_id"] }, "GPU-exact-01"
    assert_equal 5, capabilities.map { |row| row.fetch("capability_fingerprint") }.uniq.length
    capabilities.each do |row|
      generic = JSON.generate(row.fetch("capability_request"))
      %w[operation_id workload_id authority_id pool_id required_labels].each do |field|
        refute_includes generic, field
      end
    end
    assert_equal [true, true, false, false, false], %w[
      planning_only read_only readiness_observed execution_authorized provider_authorized
    ].map { |key| document.fetch(key) }
  end

  def test_replay_is_identical_across_instances_and_working_directories_and_reads_only
    before = input_snapshot
    first = planner.bytes(operation_id: ID)
    elsewhere = Dir.mktmpdir("capability-plan-cwd")
    second = Dir.chdir(elsewhere) { planner.bytes(operation_id: ID) }

    assert_equal first, second
    assert_equal before, input_snapshot
    assert_equal JSON.parse(first), planner.call(operation_id: ID)

    write_context
    process_env = {
      "AF_PROJECT_ROOT" => @components,
      "AF_ADVENTURE_FINDER_ROOT" => @front,
      "AF_AFW_ROOT" => @afw,
      "WLO_REPO_ROOT" => WLO_ROOT
    }
    command = [RbConfig.ruby, File.join(ROOT, "bin", "af-catalog"),
               "plan-local-capabilities", ID, "--json"]
    process_first, process_first_error, process_first_status = Open3.capture3(
      process_env, *command, chdir: @front
    )
    process_second, process_second_error, process_second_status = Open3.capture3(
      process_env, *command, chdir: elsewhere
    )
    assert process_first_status.success?, process_first_error
    assert process_second_status.success?, process_second_error
    assert_equal first, process_first
    assert_equal process_first, process_second
    assert_equal before, input_snapshot
  ensure
    FileUtils.remove_entry(elsewhere) if elsewhere && File.exist?(elsewhere)
  end

  def test_public_catalog_command_emits_only_the_deterministic_json_document
    write_context
    out = StringIO.new
    err = StringIO.new
    status = AdventureFinderWorkspace::CatalogIngestCLI.run(
      ["plan-local-capabilities", ID, "--json"],
      front_door_root: @front,
      project_root: @components,
      out:,
      err:,
      env: {"AF_AFW_ROOT" => @afw, "WLO_REPO_ROOT" => WLO_ROOT}
    )

    assert_equal 0, status
    assert_empty err.string
    assert_equal planner.call(operation_id: ID), JSON.parse(out.string)
  end

  def test_v02_preparation_requires_final_afw_reuse_and_empty_refused_ledger
    result = JSON.parse(File.binread(@result_path))
    result.merge!(
      "contract_version" => "adventurefinder-staged-workload-preparation/v0.2",
      "selection_contract_version" => "afw-staged-selection/v0.1",
      "selection_id" => "c" * 64,
      "decision" => {"code" => "VERIFIED_REUSE"},
      "inspection" => {
        "contract_version" => "afw-workload-inspection/v0.1", "workload_id" => WORKLOAD,
        "action" => "reuse", "reason_code" => "VERIFIED_REUSE", "observed" => {}
      },
      "refused" => []
    )
    File.write(@result_path, JSON.generate(result))
    assert_equal WORKLOAD, planner.call(operation_id: ID).dig("workload", "workload_id")

    result["inspection"]["action"] = "refuse"
    File.write(@result_path, JSON.generate(result))
    error = assert_raises(AdventureFinderWorkspace::LocalCapabilityPlan::Failure) do
      planner.call(operation_id: ID)
    end
    assert_equal "INVALID_PREPARATION_RESULT", error.code
  end

  def test_changed_plan_or_operation_binding_fails_closed
    File.open(@plan_path, "ab") { |file| file.write(" ") }
    error = assert_raises(AdventureFinderWorkspace::LocalCapabilityPlan::Failure) do
      planner.call(operation_id: ID)
    end
    assert_equal "STALE_WORKLOAD_BINDING", error.code

    write_fixture
    staged = JSON.parse(File.binread(@staged_path))
    staged.fetch("binding")["operation_id"] = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    File.write(@staged_path, JSON.generate(staged))
    error = assert_raises(AdventureFinderWorkspace::LocalCapabilityPlan::Failure) do
      planner.call(operation_id: ID)
    end
    assert_equal "STALE_WORKLOAD_BINDING", error.code
  end

  def test_missing_exact_requirement_and_weakened_residency_are_rejected_by_public_contracts
    mutate_plan do |plan|
      plan.fetch("pools").first.dig("requirements", "ollama").delete("required_context_length")
    end
    error = assert_raises(AdventureFinderWorkspace::LocalCapabilityPlan::Failure) do
      planner.call(operation_id: ID)
    end
    assert_equal "INVALID_CAPABILITY_INPUT", error.code
    assert_includes error.message, "required_context_length"

    write_fixture
    mutate_plan do |plan|
      plan.fetch("pools").first.dig("requirements", "ollama")["require_fully_gpu_resident"] = false
    end
    error = assert_raises(AdventureFinderWorkspace::LocalCapabilityPlan::Failure) do
      planner.call(operation_id: ID)
    end
    assert_equal "INVALID_WLO_PLAN", error.code
    assert_includes error.message, "require_fully_gpu_resident"
  end

  def test_duplicate_ids_unknown_pools_and_changed_result_identity_fail_closed
    mutate_plan { |plan| plan.fetch("pools")[1]["pool_id"] = "shared-a" }
    error = assert_raises(AdventureFinderWorkspace::LocalCapabilityPlan::Failure) do
      planner.call(operation_id: ID)
    end
    assert_equal "INVALID_WLO_PLAN", error.code
    assert_includes error.message, "duplicate pool_id"

    write_fixture
    mutate_plan { |plan| plan.fetch("jobs").first["pool_id"] = "missing-pool" }
    error = assert_raises(AdventureFinderWorkspace::LocalCapabilityPlan::Failure) do
      planner.call(operation_id: ID)
    end
    assert_equal "INVALID_WLO_PLAN", error.code
    assert_includes error.message, "unknown pool"

    write_fixture
    result = JSON.parse(File.binread(@result_path))
    result["workload_id"] = "different-workload"
    File.write(@result_path, JSON.generate(result))
    error = assert_raises(AdventureFinderWorkspace::LocalCapabilityPlan::Failure) do
      planner.call(operation_id: ID)
    end
    assert_equal "STALE_WORKLOAD_BINDING", error.code
  end

  def test_dependency_plan_is_explicitly_unsupported_instead_of_claiming_one_pass_safety
    mutate_plan do |plan|
      plan.fetch("jobs")[1]["depends_on_job_ids"] = ["job-1"]
    end
    error = assert_raises(AdventureFinderWorkspace::LocalCapabilityPlan::Failure) do
      planner.call(operation_id: ID)
    end

    assert_equal "UNSUPPORTED_DEPENDENCY_SEQUENCE", error.code
    assert_includes error.message, "safe one-pass capability sequence is not established"
  end

  private

  def planner
    AdventureFinderWorkspace::LocalCapabilityPlan.new(
      front_door_root: @front,
      project_root: @components,
      env: {"AF_AFW_ROOT" => @afw},
      plan_class: WorkloadOrchestrator::Plan,
      capability_request_class: WorkloadOrchestrator::OllamaCapabilityRequest
    )
  end

  def write_fixture
    FileUtils.mkdir_p(@manifest)
    @plan_path = File.join(@manifest, "execution-plan.json")
    File.write(@plan_path, JSON.pretty_generate(base_plan) + "\n")
    @plan_sha = Digest::SHA256.file(@plan_path).hexdigest
    File.write(File.join(@manifest, "snapshot.yml"), YAML.dump(
      "contract_version" => "afw-workload/v0.1", "workload_id" => WORKLOAD,
      "execution_plan_sha256" => @plan_sha, "case_count" => 7,
      "adventure_order" => %w[ADV-1001], "selected_dimensions" => ["Fixture metric"]
    ))
    @staged_path = File.join(@manifest, "staged-scoring.json")
    File.write(@staged_path, JSON.generate(
      "schema_version" => "afw-staged-scoring-input/v0.1", "validator" => {},
      "binding" => {
        "schema_version" => "af-staged-scoring-workload-binding/v0.1",
        "operation_id" => ID, "workload_id" => WORKLOAD, "authority_id" => "authority-fixture",
        "intended_ids" => %w[ADV-1001], "staged_amc" => {}, "artifacts" => {}
      }
    ))
    @result_path = File.join(
      @front, "output", "staged-workload-preparations", "v0.1", ID, "result.json"
    )
    FileUtils.mkdir_p(File.dirname(@result_path))
    File.write(@result_path, JSON.generate(
      "contract_version" => "adventurefinder-staged-workload-preparation/v0.1",
      "status" => "PREPARED", "operation_id" => ID, "intent_id" => "intent-fixture",
      "authority_id" => "authority-fixture", "workload_id" => WORKLOAD,
      "plan" => {"path" => @plan_path, "sha256" => @plan_sha},
      "qualified_cases" => 7, "metric_denominator" => 7,
      "selected" => [], "deferred" => [], "execution_authorized" => false,
      "catalog_adoption_authorized" => false, "next_action" => "verify only"
    ))
  end

  def base_plan
    common = requirement
    pools = [
      pool("shared-a", common, %w[local large]),
      pool("shared-b", common, %w[local batch]),
      pool("digest-variant", common.merge("expected_digest" => "b" * 64), ["local"]),
      pool("context-variant", common.merge("required_context_length" => 65_536), ["local"]),
      pool("gpu-variant", common.merge("required_gpu_id" => "GPU-exact-01"), %w[local exact-gpu]),
      pool("unfamiliar", common.merge("model" => "unfamiliar-local-model:latest"), ["local"])
    ]
    jobs = [
      job("job-1", "shared-a"), job("job-2", "digest-variant"),
      job("job-3", "shared-b"), job("job-4", "context-variant"),
      job("job-5", "gpu-variant"), job("job-6", "unfamiliar"), job("job-7", "shared-a")
    ]
    {
      "contract_version" => "wlo-execution-plan/v0.3", "plan_id" => WORKLOAD,
      "failure_policy" => {"max_consecutive_failures" => 2, "max_total_failures" => 3},
      "pools" => pools, "jobs" => jobs
    }
  end

  def requirement
    {
      "model" => "fixture-model:latest", "expected_digest" => "a" * 64,
      "required_context_length" => 131_072, "require_fully_gpu_resident" => true
    }
  end

  def pool(id, ollama, labels)
    {"pool_id" => id, "required_labels" => labels, "requirements" => {"ollama" => ollama}}
  end

  def job(id, pool_id)
    {"job_id" => id, "pool_id" => pool_id, "argv" => ["bin/fixture", id],
     "env" => {}, "depends_on_job_ids" => []}
  end

  def mutate_plan
    plan = JSON.parse(File.binread(@plan_path))
    yield plan
    File.write(@plan_path, JSON.pretty_generate(plan) + "\n")
    update_plan_bindings
  end

  def update_plan_bindings
    sha = Digest::SHA256.file(@plan_path).hexdigest
    snapshot_path = File.join(@manifest, "snapshot.yml")
    snapshot = YAML.safe_load_file(snapshot_path, aliases: false)
    snapshot["execution_plan_sha256"] = sha
    File.write(snapshot_path, YAML.dump(snapshot))
    result = JSON.parse(File.binread(@result_path))
    result.fetch("plan")["sha256"] = sha
    File.write(@result_path, JSON.generate(result))
  end

  def write_context
    roots = %w[input front_door pipeline converter source catalog].to_h do |name|
      path = File.join(@temporary, "context-roots", name)
      FileUtils.mkdir_p(path)
      [name, path]
    end
    context = {
      "contract_version" => "adventurefinder-catalog-ingest-context/v0.1",
      "operation_id" => ID,
      "front_door_root" => @front,
      "project_root" => @components,
      "pipeline_root" => roots.fetch("pipeline"),
      "source_root" => roots.fetch("source"),
      "catalog_root" => roots.fetch("catalog"),
      "roots" => roots
    }
    path = File.join(@front, "output", "ingest-contexts", "v0.1", "#{ID}.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(context))
  end

  def input_snapshot
    [@result_path, @plan_path, File.join(@manifest, "snapshot.yml"), @staged_path].to_h do |path|
      [path, File.binread(path)]
    end
  end
end
