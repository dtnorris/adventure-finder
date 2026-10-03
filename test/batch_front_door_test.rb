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

require "adventure_finder_batch"

class BatchFrontDoorTest < Minitest::Test
  PLAN_ID = "production-batch-039-fixture"

  class Executor
    attr_reader :calls

    def initialize(result = nil)
      @result = result
      @calls = []
    end

    def call(environment, argv, chdir:)
      @calls << { environment:, argv:, chdir: }
      @result
    end
  end

  Status = Struct.new(:successful) { def success? = successful }
  Result = Struct.new(:stdout, :stderr, :status, keyword_init: true)

  class ComponentRunner
    attr_reader :calls

    def initialize(*results)
      @results = results
      @calls = []
    end

    def capture(environment, argv, chdir:)
      @calls << { environment:, argv:, chdir: }
      @results.shift || raise("unexpected component call")
    end
  end

  def setup
    @root = Dir.mktmpdir("af-batch-front-door-")
    @afw = File.join(@root, "af-workloads-production")
    @wlo = File.join(@root, "workload-orchestrator-production")
    @rpof = File.join(@root, "runpod-ollama-fleet-production")
    @low = File.join(@root, "local-ollama-workers")
    @workload = File.join(@afw, "workloads", PLAN_ID)
    @plan_path = File.join(@workload, "execution-plan.json")
    @output = File.join(@wlo, "output", PLAN_ID)
    [@workload, File.join(@wlo, "bin"), File.join(@rpof, "bin"), File.join(@low, "bin"),
     File.join(@rpof, "output", "runpod-fleets")].each { |path| FileUtils.mkdir_p(path) }
    write_executable(File.join(@wlo, "bin", "wlo"), "exit 0")
    write_executable(File.join(@rpof, "bin", "rpof"), "exit 0")
    write_executable(File.join(@low, "bin", "low"), "exit 0")
    File.write(File.join(@rpof, "Gemfile"), "source 'https://example.invalid'\n")
    File.write(File.join(@low, "Gemfile"), "source 'https://example.invalid'\n")
    write_plan
    write_registry
    @env = write_executable(File.join(@root, "env"), "exit 0")
    @bundle = write_executable(File.join(@root, "bundle"), "exit 0")
    @executor = Executor.new
    @out = StringIO.new
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_bs01_bs03_bs13_bs16_first_start_uses_exact_plan_and_wlo_foreground_only
    assert_equal 0, front_door.run("start", "39")
    call = @executor.calls.fetch(0)
    argv = call.fetch(:argv)

    assert_equal File.join(@wlo, "bin", "wlo"), argv.fetch(0)
    assert_equal "run", argv.fetch(1)
    assert_equal @plan_path, argv.fetch(2)
    assert_option argv, "--workdir", @afw
    assert_option argv, "--output", @output
    config_path = argv.fetch(argv.index("--worker-sources-config") + 1)
    config = YAML.safe_load_file(config_path, aliases: false)
    assert_equal "wlo-worker-sources/v0.1", config.fetch("contract_version")
    assert_equal %w[local remote], config.fetch("sources").map { |source| source.fetch("name") }
    local, remote = config.fetch("sources")
    assert_equal [@bundle, "exec", File.join(@low, "bin", "low"), "workers", "--json"],
                 [local.fetch("command"), *local.fetch("args")]
    assert_equal [@bundle, "exec", File.join(@rpof, "bin", "rpof"), "workers", "--json"],
                 [remote.fetch("command"), *remote.fetch("args")]
    assert_equal File.join(@rpof, "output", "runpod-fleets"),
                 remote.dig("environment", "RPOF_STATE_ROOT")
    refute argv.any? { |value| value.include?("af-workers") }
    refute_includes argv, "bootstrap"
    refute argv.any? { |value| value.match?(/build|compile|manifest|retry-failed|acknowledge|campaign|desired/) }
    assert_equal @wlo, call.fetch(:chdir)
    assert_empty call.fetch(:environment)
    assert_includes @out.string, "Ctrl-C: cancel this foreground WLO execution"
    refute_includes @out.string, "[="
  end

  def test_local_only_source_does_not_require_remote_checkout
    write_registry(worker_sources: ["local"])
    FileUtils.rm_rf(@rpof)

    assert_equal 0, front_door.run("start", "39")
    config = launched_worker_config
    assert_equal ["local"], config.fetch("sources").map { |source| source.fetch("name") }
    assert_equal @low, config.dig("sources", 0, "workdir")
  end

  def test_remote_only_source_does_not_require_local_checkout
    write_registry(worker_sources: ["remote"])
    FileUtils.rm_rf(@low)

    assert_equal 0, front_door.run("start", "39")
    config = launched_worker_config
    assert_equal ["remote"], config.fetch("sources").map { |source| source.fetch("name") }
    assert_equal @rpof, config.dig("sources", 0, "workdir")
  end

  def test_bs02_plan_sha_drift_fails_before_wlo_launch
    File.open(@plan_path, "a") { |file| file.write(" ") }
    error = assert_raises(AdventureFinderWorkspace::Error) { front_door.run("start", "39") }
    assert_includes error.message, "SHA-256 mismatch"
    assert_empty @executor.calls
  end

  def test_plan_identity_and_contract_drift_fail_closed
    write_plan("plan_id" => "wrong")
    update_registered_sha
    assert_raises(AdventureFinderWorkspace::Error) { front_door.run("start", "39") }
    write_plan("contract_version" => "wlo-execution-plan/v9")
    update_registered_sha
    error = assert_raises(AdventureFinderWorkspace::Error) { front_door.run("start", "39") }
    assert_includes error.message, "unsupported foreground plan contract"
  end

  def test_bs04_bs05_completed_batch_is_untouched_and_not_executed
    prepare_retained(status: "completed", jobs: [{ "status" => "complete", "attempt" => 1 }])
    before = evidence

    assert_equal 0, front_door.run("start", "39")

    assert_empty @executor.calls
    assert_equal before, evidence
    assert_includes @out.string, "retained scoring evidence is unchanged"
  end

  def test_bs06_paused_start_refuses_without_clearing_pause
    prepare_retained(status: "paused", jobs: [{ "status" => "pending" }], paused: true)
    error = assert_raises(AdventureFinderWorkspace::Error) { front_door.run("start", "39") }

    assert_includes error.message, "bin/af-batch resume 39"
    assert File.file?(File.join(@output, "control", "pause"))
    assert_empty @executor.calls
  end

  def test_bs07_resume_requires_retained_state_then_delegates_only_to_wlo_resume
    error = assert_raises(AdventureFinderWorkspace::Error) { front_door.run("resume", "39") }
    assert_includes error.message, "no retained execution"
    prepare_retained(status: "paused", jobs: [{ "status" => "pending" }], paused: true)

    assert_equal 0, front_door.run("resume", "39")
    argv = @executor.calls.fetch(0).fetch(:argv)
    assert_equal "resume", argv.fetch(1)
    refute_includes argv, "--acknowledge-circuit-breaker"
    refute_includes argv, "retry-failed"
  end

  def test_bs08_failed_execution_requires_explicit_recovery
    prepare_retained(status: "workload_failed", jobs: [{ "status" => "failed", "attempt" => 1 }])
    before = evidence
    %w[start resume].each do |action|
      error = assert_raises(AdventureFinderWorkspace::Error) { front_door.run(action, "39") }
      assert_includes error.message, "retry-failed explicitly"
    end
    assert_equal before, evidence
    assert_empty @executor.calls
  end

  def test_bs08_failed_jobs_are_preserved_when_pending_work_is_safe
    prepare_retained(
      status: "pending",
      jobs: [{ "status" => "failed", "attempt" => 1 }, { "status" => "pending", "attempt" => nil }]
    )
    before = evidence

    assert_equal 0, front_door.run("start", "39")
    argv = @executor.calls.fetch(0).fetch(:argv)
    refute_includes argv, "retry-failed"
    refute_includes argv, "--resume"
    assert_equal before, evidence
  end

  def test_bs09_interrupted_work_is_never_implicitly_retried_or_unpaused
    prepare_retained(status: "paused", jobs: [{ "status" => "interrupted", "attempt" => 1 }], paused: true)
    before = evidence
    %w[start resume].each do |action|
      error = assert_raises(AdventureFinderWorkspace::Error) { front_door.run(action, "39") }
      assert_includes error.message, "explicit retry authorization"
    end
    assert_equal before, evidence
    assert_empty @executor.calls
  end

  def test_bs10_breaker_is_not_acknowledged_or_pause_cleared
    prepare_retained(
      status: "paused", jobs: [{ "status" => "pending" }], paused: true,
      breaker: { "tripped" => true, "reason" => "limit" }
    )
    before = evidence
    error = assert_raises(AdventureFinderWorkspace::Error) { front_door.run("resume", "39") }
    assert_includes error.message, "circuit breaker is tripped"
    assert_equal before, evidence
    assert_empty @executor.calls
  end

  def test_dispatch_halt_requires_explicit_recovery
    prepare_retained(status: "infrastructure_failed", jobs: [{ "status" => "pending" }],
                     extra: { "dispatch_halt" => { "kind" => "worker_registry" } })
    error = assert_raises(AdventureFinderWorkspace::Error) { front_door.run("start", "39") }
    assert_includes error.message, "dispatch is halted"
    assert_empty @executor.calls
  end

  def test_bs11_active_executor_lock_prevents_second_foreground_owner
    prepare_retained(status: "running", jobs: [{ "status" => "running", "attempt" => 1 }])
    lock_path = File.join(@output, ".execution.lock")
    File.open(lock_path, File::RDWR) do |lock|
      lock.flock(File::LOCK_EX | File::LOCK_NB)
      error = assert_raises(AdventureFinderWorkspace::Error) { front_door.run("start", "39") }
      assert_includes error.message, "active executor"
    end
    assert_empty @executor.calls
  end

  def test_orphaned_running_state_requires_review
    prepare_retained(status: "running", jobs: [{ "status" => "running", "attempt" => 1 }])
    error = assert_raises(AdventureFinderWorkspace::Error) { front_door.run("start", "39") }
    assert_includes error.message, "without an active executor"
  end

  def test_bs12_foreground_executor_is_a_true_exec_handoff
    source = File.read(File.expand_path("../lib/adventure_finder_batch.rb", __dir__))
    assert_includes source, "Kernel.exec(environment, *argv, chdir:)"
    refute_match(/Process\.spawn|system\(/, source)
  end

  def test_ar_batch_retry_resolves_exact_short_handles_and_delegates_selected_jobs
    write_plan("jobs" => [
                 { "job_id" => "production-batch-039-adv0946-structural-openness",
                   "pool_id" => "qwen", "argv" => ["bin/afw-score-job"] },
                 { "job_id" => "production-batch-039-adv0946-ee",
                   "pool_id" => "qwen", "argv" => ["bin/afw-score-job"] }
               ])
    update_registered_sha
    prepare_retained(
      status: "workload_failed",
      jobs: [{ "status" => "failed", "attempt" => 1 }, { "status" => "failed", "attempt" => 1 }]
    )
    before = evidence
    runner = ComponentRunner.new(
      diagnostic_result("0946-openness", "production-batch-039-adv0946-structural-openness"),
      diagnostic_result("0946-ee", "production-batch-039-adv0946-ee")
    )

    assert_equal 0, front_door(component_runner: runner).run(
      "retry", "39", jobs: %w[0946-openness 0946-ee], reason: "confirmed transient timeout",
      dry_run: true, acknowledge_circuit_breaker: true
    )

    argv = @executor.calls.fetch(0).fetch(:argv)
    assert_equal [@bundle, "exec", File.join(@wlo, "bin", "wlo"), "retry-failed"], argv.first(4)
    assert_equal 2, argv.count("--job")
    assert_includes argv, "production-batch-039-adv0946-structural-openness"
    assert_includes argv, "production-batch-039-adv0946-ee"
    assert_option argv, "--reason", "confirmed transient timeout"
    assert_includes argv, "--dry-run"
    assert_includes argv, "--acknowledge-circuit-breaker"
    refute_includes argv, "--all"
    refute_includes argv, File.join(@rpof, "bin", "rpof")
    assert_equal before, evidence
    assert_equal 2, runner.calls.length
  end

  def test_ar_retry_requires_reason_and_fails_closed_on_ambiguous_or_duplicate_handles
    prepare_retained(status: "workload_failed", jobs: [{ "status" => "failed", "attempt" => 1 }])
    assert_raises(AdventureFinderWorkspace::Error) do
      front_door.run("retry", "39", jobs: ["job-1"], reason: " ")
    end
    assert_raises(AdventureFinderWorkspace::Error) do
      front_door.run("retry", "39", jobs: %w[job-1 job-1], reason: "reviewed")
    end

    failed = Result.new(stdout: "", stderr: "ERROR: ambiguous job handle", status: Status.new(false))
    runner = ComponentRunner.new(failed)
    error = assert_raises(AdventureFinderWorkspace::Error) do
      front_door(component_runner: runner).run("retry", "39", jobs: ["0946-openness"], reason: "reviewed")
    end
    assert_includes error.message, "ambiguous"
    assert_empty @executor.calls
  end

  def test_ar_recovery_is_read_only_and_repair_is_a_distinct_fail_closed_delegation
    prepare_retained(status: "workload_failed", jobs: [{ "status" => "failed", "attempt" => 1 }])
    before = evidence

    assert_equal 0, front_door.run("recovery", "39")
    recovery = @executor.calls.pop.fetch(:argv)
    assert_equal "recovery", recovery.fetch(3)
    refute_includes recovery, "retry-failed"

    assert_equal 0, front_door.run(
      "repair", "39", reason: "reviewed retained metadata", dry_run: true
    )
    repair = @executor.calls.pop.fetch(:argv)
    assert_equal "repair", repair.fetch(3)
    assert_option repair, "--reason", "reviewed retained metadata"
    assert_includes repair, "--dry-run"
    refute_includes repair, "retry-failed"
    assert_equal before, evidence
  end

  def test_bs14_unknown_handle_fails_closed
    error = assert_raises(AdventureFinderWorkspace::Error) { front_door.run("start", "40") }
    assert_includes error.message, "unknown production context: batch 40"
    assert_empty @executor.calls
  end

  def test_bs15_binary_honors_af_project_root
    recorder = File.join(@root, "wlo-argv.json")
    write_executable(File.join(@wlo, "bin", "wlo"), <<~RUBY)
      require "json"
      File.write(#{recorder.dump}, JSON.generate(ARGV))
      exit 0
    RUBY
    path = File.expand_path("../bin/af-batch", __dir__)
    _stdout, stderr, status = Open3.capture3(
      { "AF_PROJECT_ROOT" => @root }, RbConfig.ruby, path, "start", "39", "--registry", @registry
    )

    assert status.success?, stderr
    argv = JSON.parse(File.read(recorder))
    assert_equal "run", argv.fetch(0)
    assert_includes argv, @plan_path
    assert_includes argv, @output
  end

  def test_retained_identity_and_plan_copy_mismatch_fail_before_launch
    prepare_retained(status: "pending", jobs: [{ "status" => "pending" }])
    state_path = File.join(@output, "execution.json")
    state = JSON.parse(File.read(state_path)).merge("plan_sha256" => "0" * 64)
    File.write(state_path, JSON.generate(state))
    assert_raises(AdventureFinderWorkspace::Error) { front_door.run("start", "39") }
    File.write(state_path, JSON.generate(execution_state("pending")))
    File.write(File.join(@output, "plan.json"), "changed")
    assert_raises(AdventureFinderWorkspace::Error) { front_door.run("start", "39") }
    assert_empty @executor.calls
  end

  private

  def front_door(component_runner: ComponentRunner.new)
    AdventureFinderWorkspace::BatchFrontDoor.new(
      registry_path: @registry, workspace_root: @root, executor: @executor,
      component_runner:, env_executable: @env, bundle_executable: @bundle, out: @out
    )
  end

  def diagnostic_result(handle, id)
    Result.new(
      stdout: JSON.generate("subject" => { "handle" => handle, "id" => id }), stderr: "",
      status: Status.new(true)
    )
  end

  def write_plan(overrides = {})
    document = {
      "contract_version" => "wlo-execution-plan/v0.3",
      "plan_id" => PLAN_ID,
      "failure_policy" => { "max_consecutive_failures" => 2, "max_total_failures" => 4 },
      "pools" => [{ "pool_id" => "qwen" }],
      "jobs" => [{ "job_id" => "job-1", "pool_id" => "qwen", "argv" => ["bin/afw-score-job"] }]
    }.merge(overrides)
    File.write(@plan_path, JSON.generate(document))
  end

  def write_registry(worker_sources: %w[local remote])
    @registry = File.join(@root, "production_contexts.yml")
    data = {
      "schema_version" => "adventurefinder-production-context/v0.1",
      "contexts" => {
        "batch" => {
          "39" => {
            "production_batch_id" => PLAN_ID,
            "afw" => { "repository_root" => "af-workloads-production",
                       "workload_root" => "af-workloads-production/workloads/#{PLAN_ID}",
                       "plan_path" => "af-workloads-production/workloads/#{PLAN_ID}/execution-plan.json" },
            "wlo" => { "repository_root" => "workload-orchestrator-production",
                       "output_root" => "workload-orchestrator-production/output/#{PLAN_ID}" },
            "local_workers" => { "repository_root" => "local-ollama-workers" },
            "worker_sources" => worker_sources,
            "plan" => { "plan_id" => PLAN_ID, "sha256" => Digest::SHA256.file(@plan_path).hexdigest },
            "associated_fleets" => ["A"]
          }
        },
        "fleet" => {
          "A" => {
            "campaign_id" => PLAN_ID,
            "rpof" => { "repository_root" => "runpod-ollama-fleet-production",
                        "campaign_path" => "runpod-ollama-fleet-production/campaign.json",
                        "budget_path" => "runpod-ollama-fleet-production/budget.json",
                        "state_root" => "runpod-ollama-fleet-production/output/runpod-fleets",
                        "binding_path" => "runpod-ollama-fleet-production/binding.json" },
            "associated_batches" => ["39"]
          }
        }
      }
    }
    File.write(@registry, YAML.dump(data))
  end

  def update_registered_sha
    data = YAML.safe_load_file(@registry, aliases: false)
    data.dig("contexts", "batch", "39", "plan", "sha256").replace(Digest::SHA256.file(@plan_path).hexdigest)
    File.write(@registry, YAML.dump(data))
  end

  def prepare_retained(status:, jobs:, paused: false, breaker: nil, extra: {})
    FileUtils.mkdir_p(@output)
    File.write(File.join(@output, "execution.json"), JSON.generate(
      execution_state(status, breaker:).merge(extra)
    ))
    FileUtils.cp(@plan_path, File.join(@output, "plan.json"))
    plan_jobs = JSON.parse(File.read(@plan_path)).fetch("jobs")
    normalized = jobs.each_with_index.map do |job, index|
      id = plan_jobs[index]&.fetch("job_id") || "job-#{index + 1}"
      { "job_id" => id, "pool_id" => "qwen" }.merge(job)
    end
    File.write(File.join(@output, "jobs.json"), JSON.generate("jobs" => normalized))
    File.write(File.join(@output, "retained.log"), "retained evidence\n")
    if paused
      FileUtils.mkdir_p(File.join(@output, "control"))
      File.write(File.join(@output, "control", "pause"), "requested\n")
    end
    FileUtils.touch(File.join(@output, ".execution.lock"))
  end

  def execution_state(status, breaker: nil)
    {
      "contract_version" => "wlo-execution-state/v0.1",
      "plan_id" => PLAN_ID,
      "plan_sha256" => Digest::SHA256.file(@plan_path).hexdigest,
      "workdir" => @afw,
      "status" => status,
      "circuit_breaker" => breaker || { "tripped" => false, "reason" => nil }
    }
  end

  def evidence
    Dir.glob(File.join(@output, "**", "*"), File::FNM_DOTMATCH)
       .select { |path| File.file?(path) }
       .to_h { |path| [path.delete_prefix("#{@output}/"), File.binread(path)] }
  end

  def write_executable(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#!/usr/bin/env ruby\n#{body}\n")
    FileUtils.chmod(0o755, path)
    path
  end

  def assert_option(argv, name, value)
    index = argv.index(name)
    refute_nil index, "missing #{name}"
    assert_equal value, argv.fetch(index + 1)
  end

  def launched_worker_config
    argv = @executor.calls.last.fetch(:argv)
    path = argv.fetch(argv.index("--worker-sources-config") + 1)
    YAML.safe_load_file(path, aliases: false)
  end
end
