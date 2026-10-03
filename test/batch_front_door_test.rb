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

  def setup
    @root = Dir.mktmpdir("af-batch-front-door-")
    @afw = File.join(@root, "af-workloads-production")
    @wlo = File.join(@root, "workload-orchestrator-production")
    @rpof = File.join(@root, "runpod-ollama-fleet-production")
    @workload = File.join(@afw, "workloads", PLAN_ID)
    @plan_path = File.join(@workload, "execution-plan.json")
    @output = File.join(@wlo, "output", PLAN_ID)
    [@workload, File.join(@wlo, "bin"), File.join(@rpof, "bin"),
     File.join(@rpof, "output", "runpod-fleets")].each { |path| FileUtils.mkdir_p(path) }
    write_executable(File.join(@wlo, "bin", "wlo"), "exit 0")
    write_executable(File.join(@rpof, "bin", "rpof"), "exit 0")
    File.write(File.join(@rpof, "Gemfile"), "source 'https://example.invalid'\n")
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
    assert_option argv, "--worker-source-command", @env
    assert_includes argv, File.join(@rpof, "bin", "rpof")
    assert_includes argv, "workers"
    assert_includes argv, "--worker-source-arg=--json"
    refute argv.any? { |value| value.match?(/build|compile|manifest|retry-failed|acknowledge|campaign|desired/) }
    assert_equal @wlo, call.fetch(:chdir)
    assert_equal File.join(@rpof, "output", "runpod-fleets"),
                 call.dig(:environment, "RPOF_STATE_ROOT")
    assert_includes @out.string, "Ctrl-C: cancel this foreground WLO execution"
    refute_includes @out.string, "[="
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
    refute_match(/Process\.spawn|Open3|system\(/, source)
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

  def front_door
    AdventureFinderWorkspace::BatchFrontDoor.new(
      registry_path: @registry, workspace_root: @root, executor: @executor,
      env_executable: @env, bundle_executable: @bundle, out: @out
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

  def write_registry
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
    normalized = jobs.each_with_index.map do |job, index|
      { "job_id" => "job-#{index + 1}", "pool_id" => "qwen" }.merge(job)
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
end
