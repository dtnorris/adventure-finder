# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "stringio"
require "timeout"
require "tmpdir"
require "yaml"
require "adventure_finder_local_capability_plan"
require "adventure_finder_local_execution"

class LocalIngestExecutionTest < Minitest::Test
  # Keep foreground execution and state changes in child processes. Repeated
  # read-only observations exercise the same public WLO CLI without paying for
  # a fresh Ruby process on every coordinator poll.
  class PublicReadRunner < AdventureFinderWorkspace::LocalExecution::CommandRunner
    Status = Struct.new(:exitstatus) do
      def success? = exitstatus.zero?
    end

    def capture(environment, *argv, chdir:)
      return super unless File.basename(argv.first) == "wlo" &&
                          %w[action-check consumer-demand status].include?(argv[1])

      stdout = StringIO.new
      stderr = StringIO.new
      exitstatus = WorkloadOrchestrator::CLI.new(argv.drop(1), out: stdout, err: stderr, root: chdir).run
      AdventureFinderWorkspace::LocalExecution::Result.new(
        stdout: stdout.string, stderr: stderr.string, status: Status.new(exitstatus)
      )
    end
  end

  ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  WORKLOAD = "operation-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  MODEL_A = "fixture-a:latest"
  MODEL_B = "fixture-b:latest"
  DIGEST_A = "a" * 64
  DIGEST_B = "b" * 64

  def setup
    @wlo = ENV["WLO_REPO_ROOT"] || ENV["WLO_REPOSITORY_ROOT"]
    @real_low = ENV["LOW_REPO_ROOT"]
    skip "set WLO_REPO_ROOT and LOW_REPO_ROOT for the real public-seam integration" unless @wlo && @real_low
    @wlo = File.expand_path(@wlo)
    @real_low = File.expand_path(@real_low)
    require File.join(@wlo, "lib", "workload_orchestrator")

    @root = Dir.mktmpdir("local-ingest-execution-")
    @front = directory("front")
    @components = directory("components")
    @afw = directory("components/af-workloads")
    @low = directory("components/local-ollama-workers")
    @low_state = directory("low-state")
    @manifest = directory("components/af-workloads/workloads/#{WORKLOAD}")
    write_low_fixture
    write_job_fixture
    # The end-to-end case proves four retained attempts and ordering. Other
    # scenarios need one real job per capability to exercise transitions.
    full_workload = name == "test_real_low_and_wlo_public_seams_complete_two_capabilities_in_one_execution"
    write_workload(jobs_per_pool: full_workload ? 2 : 1)
    @capability_plan = AdventureFinderWorkspace::LocalCapabilityPlan.new(
      front_door_root: @front, project_root: @components,
      env: {"AF_AFW_ROOT" => @afw, "WLO_REPO_ROOT" => @wlo},
      plan_class: WorkloadOrchestrator::Plan,
      capability_request_class: WorkloadOrchestrator::OllamaCapabilityRequest
    ).call(operation_id: ID)
    @environment = {
      "AF_AFW_ROOT" => @afw, "LOW_REPO_ROOT" => @low, "LOW_STATE_ROOT" => @low_state,
      "WLO_REPO_ROOT" => @wlo
    }
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def test_real_low_and_wlo_public_seams_complete_two_capabilities_in_one_execution
    service = coordinator
    assert_equal 0, service.start(operation_id: ID, selected_by: "David", capability_plan: @capability_plan)

    output = File.join(@front, "output/local-ingest-executions/v0.1", ID, "wlo")
    execution = JSON.parse(File.binread(File.join(output, "execution.json")))
    jobs = JSON.parse(File.binread(File.join(output, "jobs.json"))).fetch("jobs")
    assert_equal "completed", execution.fetch("status")
    cli_stdout, cli_stderr, cli_status = Open3.capture3(
      File.join(@wlo, "bin/wlo"), "status", @plan_path, "--output", output, "--json", chdir: @wlo
    )
    assert cli_status.success?, cli_stderr
    assert_equal execution.fetch("status"), JSON.parse(cli_stdout).fetch("status")
    assert_equal 4, jobs.count { |row| row.fetch("status") == "complete" }
    assert jobs.all? { |row| row.fetch("attempt") == 1 }
    assert_equal 1, jobs.map { |row| row.fetch("worker") }.uniq.length
    assert_equal 4, File.readlines(File.join(@afw, "job-order.log"), chomp: true).length
    assert_equal %w[a a b b], File.readlines(File.join(@afw, "job-order.log"), chomp: true).map { |row| row.split(":").first }

    intent = JSON.parse(File.binread(File.join(@front, "output/local-ingest-executions/v0.1", ID, "intent.json")))
    state = JSON.parse(File.binread(File.join(@front, "output/local-ingest-executions/v0.1", ID, "state.json")))
    assert_equal "local_only", intent.dig("authority", "mode")
    assert_equal "completed", state.fetch("phase")
    assert_equal WORKLOAD, JSON.parse(File.binread(File.join(output, "plan.json"))).fetch("plan_id")
    refute File.exist?(File.join(output, "recovery.json"))

    snapshot = low("workers", "--json")
    worker = snapshot.fetch("workers").fetch(0)
    assert_equal "READY", worker.fetch("state")
    assert_equal "fixture-local", worker.fetch("worker_id")
    assert_equal [MODEL_A, MODEL_B], worker.dig("capabilities", "ollama", "models").map { |row| row.fetch("model") }

    sources = YAML.safe_load(File.binread(File.join(@front, "output/local-ingest-executions/v0.1", ID,
                                                    "worker-sources.yml")))
    assert_equal ["local"], sources.fetch("sources").map { |row| row.fetch("name") }
    assert_equal "required", sources.dig("sources", 0, "policy")

    assert_equal 0, coordinator.resume(operation_id: ID, capability_plan: @capability_plan)
    jobs_after_resume = JSON.parse(File.binread(File.join(output, "jobs.json"))).fetch("jobs")
    assert jobs_after_resume.all? { |row| row.fetch("attempt") == 1 }
    assert_equal 4, File.readlines(File.join(@afw, "job-order.log"), chomp: true).length

    out = StringIO.new
    status = coordinator(out:).status(operation_id: ID, capability_plan: @capability_plan)
    assert_equal 0, status
    assert_includes out.string, "Execution: completed"
    assert_includes out.string, "After evidence_complete=true: bin/af-catalog resume #{ID}"
  end

  def test_existing_operator_pause_is_not_cleared_or_reclassified_as_coordinator_drain
    paths = execution_paths
    store = WorkloadOrchestrator::ExecutionStore.new(
      plan: WorkloadOrchestrator::Plan.load(@plan_path), workdir: @afw, output_dir: paths.fetch(:output)
    )
    store.prepare!
    store.pause!
    AdventureFinderWorkspace::LocalExecutionIntentStore.new(
      root: File.join(@front, "output/local-ingest-executions/v0.1")
    ).capture!(
      operation_id: ID, selected_by: "David", capability_plan: @capability_plan,
      components: {"afw" => @afw, "low" => @low, "wlo" => @wlo},
      workdir: @afw, output: paths.fetch(:output)
    )

    error = assert_raises(AdventureFinderWorkspace::LocalExecution::Failure) do
      coordinator.resume(operation_id: ID, capability_plan: @capability_plan)
    end
    assert_equal "OPERATOR_PAUSE", error.code
    assert store.paused?
    assert_equal "paused", store.status

    assert_equal 0, coordinator.resume(
      operation_id: ID, capability_plan: @capability_plan, continue_operator_pause: true
    )
    assert_equal "completed", store.status
  end

  def test_foreground_interrupt_reaches_wlo_and_retains_interrupted_evidence
    log = File.join(@afw, "job-order.log")
    output = File.join(@front, "output/local-ingest-executions/v0.1", ID, "wlo")
    pid = fork do
      ENV["LOCAL_FIXTURE_JOB_SLEEP"] = "30"
      begin
        coordinator.start(operation_id: ID, selected_by: "David", capability_plan: @capability_plan)
        exit! 0
      rescue AdventureFinderWorkspace::LocalExecution::Failure
        exit! 2
      end
    end

    Timeout.timeout(10) do
      sleep 0.02 until File.file?(log) && !File.zero?(log)
    end
    Process.kill("INT", pid)
    status = Timeout.timeout(10) do
      loop do
        waited = Process.waitpid2(pid, Process::WNOHANG)
        break waited.last if waited
        sleep 0.02
      end
    end
    pid = nil
    assert_equal 2, status.exitstatus
    execution = JSON.parse(File.binread(File.join(output, "execution.json")))
    jobs = JSON.parse(File.binread(File.join(output, "jobs.json"))).fetch("jobs")
    assert_equal "interrupted", execution.fetch("status")
    assert jobs.any? { |row| row.fetch("status") == "interrupted" }
    assert_equal "INT", execution.dig("interruption", "signal")
  ensure
    if pid
      Process.kill("TERM", pid) rescue Errno::ESRCH
      Process.waitpid(pid) rescue Errno::ECHILD
    end
  end

  def test_fresh_resume_reconstructs_a_persisted_coordinator_drain
    paths = execution_paths
    store = WorkloadOrchestrator::ExecutionStore.new(
      plan: WorkloadOrchestrator::Plan.load(@plan_path), workdir: @afw, output_dir: paths.fetch(:output)
    )
    store.prepare!
    store.pause!
    intent = AdventureFinderWorkspace::LocalExecutionIntentStore.new(
      root: File.join(@front, "output/local-ingest-executions/v0.1")
    ).capture!(
      operation_id: ID, selected_by: "David", capability_plan: @capability_plan,
      components: {"afw" => @afw, "low" => @low, "wlo" => @wlo},
      workdir: @afw, output: paths.fetch(:output)
    )
    File.write(
      File.join(@front, "output/local-ingest-executions/v0.1", ID, "state.json"),
      JSON.pretty_generate(
        "contract_version" => "adventurefinder-local-execution-state/v0.1",
        "intent_id" => intent.fetch("intent_id"), "phase" => "draining", "step" => 1,
        "updated_at" => Time.now.utc.iso8601
      ) + "\n"
    )

    assert_equal 0, coordinator.resume(operation_id: ID, capability_plan: @capability_plan)
    assert_equal "completed", store.status
    jobs = JSON.parse(File.binread(File.join(paths.fetch(:output), "jobs.json"))).fetch("jobs")
    assert(jobs.all? { |row| row.fetch("attempt") == 1 })
  end

  def test_zero_exit_bootstrap_without_independent_ready_publication_is_refused
    with_environment("LOW_FIXTURE_FALSE_BOOTSTRAP" => "1") do
      error = assert_raises(AdventureFinderWorkspace::LocalExecution::Failure) do
        coordinator.start(operation_id: ID, selected_by: "David", capability_plan: @capability_plan)
      end

      assert_equal "LOW_READINESS_FAILED", error.code
      refute File.exist?(File.join(@front, "output/local-ingest-executions/v0.1", ID, "wlo", "execution.json"))
    end
  end

  def test_low_publication_failure_stops_before_wlo_launch
    with_environment("LOW_FIXTURE_PUBLICATION_FAILURE" => "1") do
      error = assert_raises(AdventureFinderWorkspace::LocalExecution::Failure) do
        coordinator.start(operation_id: ID, selected_by: "David", capability_plan: @capability_plan)
      end

      assert_equal "LOW_PUBLICATION_FAILED", error.code
      refute File.exist?(File.join(@front, "output/local-ingest-executions/v0.1", ID, "wlo", "execution.json"))
    end
  end

  def test_wrong_runtime_digest_does_not_establish_readiness
    assert_runtime_mismatch_rejected("LOW_FIXTURE_WRONG_DIGEST")
  end

  def test_wrong_runtime_context_does_not_establish_readiness
    assert_runtime_mismatch_rejected("LOW_FIXTURE_WRONG_CONTEXT")
  end

  def test_partial_runtime_residency_does_not_establish_readiness
    assert_runtime_mismatch_rejected("LOW_FIXTURE_PARTIAL_RESIDENCY")
  end

  def test_stale_public_demand_is_bounded_and_never_authorizes_pause
    service = AdventureFinderWorkspace::LocalExecution.new(
      front_door_root: @front, project_root: @components, env: @environment, out: StringIO.new,
      poll_interval: 0.001, observation_timeout: 0.005
    )
    report = {"status" => "running", "paused" => false, "executor_active" => true,
              "pool_status" => []}
    stale = {"b" => {"fresh" => false, "state" => "active", "runnable_count" => 1,
                     "bound_count" => 0, "uncertain_count" => 0, "quiescent" => true}}
    step = @capability_plan.fetch("sequence").last
    service.define_singleton_method(:execution_report) { |*, **| report }
    service.define_singleton_method(:demands) { |*, **| stale }
    service.define_singleton_method(:demanded_missing_step) { |*, **| step }
    service.define_singleton_method(:pause_wlo) { |*| raise "pause must not be requested from stale demand" }

    error = assert_raises(AdventureFinderWorkspace::LocalExecution::Failure) do
      service.send(:monitor, {}, @capability_plan, {}, {"phase" => "running"}, nil)
    end
    assert_equal "LOCAL_TRANSITION_GATE", error.code
  end

  def test_observed_active_executor_failure_returns_a_recovery_gate
    service = coordinator
    service.define_singleton_method(:execution_report) do |*, **|
      {"status" => "workload_failed", "paused" => false, "executor_active" => false}
    end
    service.define_singleton_method(:demands) { |*, **| raise "terminal execution must not be polled for demand" }

    error = assert_raises(AdventureFinderWorkspace::LocalExecution::Failure) do
      service.send(:monitor, {}, @capability_plan, {}, {"phase" => "running"}, nil)
    end
    assert_equal "WLO_EXECUTION_GATE", error.code
    assert_includes error.message, "workload_failed"
  end

  def test_active_wlo_owner_is_observed_without_a_duplicate_launch
    service = coordinator
    observed_handles = []
    report = {"status" => "running", "paused" => false, "executor_active" => true}
    state = {"phase" => "running", "step" => 1}
    service.define_singleton_method(:validate_binding!) { |*| {} }
    service.define_singleton_method(:with_coordination_lock) { |*, &block| block.call }
    service.define_singleton_method(:prepare_files!) { |*| nil }
    service.define_singleton_method(:execution_report) { |*, **| report }
    service.define_singleton_method(:load_state) { |*| state }
    service.define_singleton_method(:action_check) do |*|
      {"reason" => "executor_active", "execution_status" => nil}
    end
    service.define_singleton_method(:persist_state) { |*, **| state }
    service.define_singleton_method(:spawn_wlo) { |*| raise "duplicate WLO launch" }
    service.define_singleton_method(:monitor) do |*arguments, **|
      observed_handles << arguments.last
      0
    end

    result = service.send(
      :drive, operation_id: ID, capability_plan: @capability_plan,
      intent: {}, continue_operator_pause: false
    )

    assert_equal 0, result
    assert_equal [nil], observed_handles
  end

  def test_operation_coordination_lock_refuses_a_second_driver
    coordination = directory("front/output/local-ingest-executions/v0.1/#{ID}")
    lock_path = File.join(coordination, ".coordination.lock")
    File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
      assert lock.flock(File::LOCK_EX | File::LOCK_NB)
      error = assert_raises(AdventureFinderWorkspace::LocalExecution::Failure) do
        coordinator.send(:with_coordination_lock, {coordination: Pathname(coordination), lock: Pathname(lock_path)}) do
          flunk "second coordinator entered the operation lock"
        end
      end
      assert_equal "LOCAL_EXECUTION_ACTIVE", error.code
    end
  end

  private

  def assert_runtime_mismatch_rejected(variable)
    with_environment(variable => "1") do
      error = assert_raises(AdventureFinderWorkspace::LocalExecution::Failure) do
        coordinator.start(operation_id: ID, selected_by: "David", capability_plan: @capability_plan)
      end
      assert_equal "LOW_BOOTSTRAP_FAILED", error.code
      refute File.exist?(File.join(@front, "output/local-ingest-executions/v0.1", ID, "wlo", "execution.json"))
    end
  end

  def coordinator(out: StringIO.new)
    AdventureFinderWorkspace::LocalExecution.new(
      front_door_root: @front, project_root: @components, env: @environment, out:,
      runner: PublicReadRunner.new,
      poll_interval: 0.02, observation_timeout: 5.0
    )
  end

  def write_workload(jobs_per_pool:)
    pools = [
      pool("a", MODEL_A, DIGEST_A), pool("b", MODEL_B, DIGEST_B)
    ]
    jobs = %w[a b].flat_map do |pool_id|
      (1..jobs_per_pool).map { |number| job("#{pool_id}-#{number}", pool_id) }
    end
    plan = {
      "contract_version" => "wlo-execution-plan/v0.3", "plan_id" => WORKLOAD,
      "failure_policy" => {"max_consecutive_failures" => 2, "max_total_failures" => 4},
      "pools" => pools, "jobs" => jobs
    }
    @plan_path = File.join(@manifest, "execution-plan.json")
    File.write(@plan_path, JSON.pretty_generate(plan) + "\n")
    plan_sha = Digest::SHA256.file(@plan_path).hexdigest
    File.write(File.join(@manifest, "snapshot.yml"), YAML.dump(
      "contract_version" => "afw-workload/v0.1", "workload_id" => WORKLOAD,
      "execution_plan_sha256" => plan_sha, "case_count" => jobs.length,
      "adventure_order" => ["ADV-0001"], "selected_dimensions" => %w[A B]
    ))
    File.write(File.join(@manifest, "staged-scoring.json"), JSON.generate(
      "schema_version" => "afw-staged-scoring-input/v0.1", "validator" => {},
      "binding" => {"schema_version" => "af-staged-scoring-workload-binding/v0.1",
                    "operation_id" => ID, "workload_id" => WORKLOAD, "authority_id" => "authority-fixture",
                    "intended_ids" => ["ADV-0001"], "staged_amc" => {}, "artifacts" => {}}
    ))
    result_dir = directory("front/output/staged-workload-preparations/v0.1/#{ID}")
    File.write(File.join(result_dir, "result.json"), JSON.generate(
      "contract_version" => "adventurefinder-staged-workload-preparation/v0.1", "status" => "PREPARED",
      "operation_id" => ID, "intent_id" => "intent-fixture", "authority_id" => "authority-fixture",
      "workload_id" => WORKLOAD, "plan" => {"path" => @plan_path, "sha256" => plan_sha},
      "qualified_cases" => jobs.length, "metric_denominator" => jobs.length,
      "selected" => [{"adventure_id" => "ADV-0001", "case_count" => jobs.length, "evidence" => "fixture"}],
      "deferred" => [], "execution_authorized" => false, "catalog_adoption_authorized" => false,
      "next_action" => "verify fixture"
    ))
  end

  def pool(id, model, digest)
    {"pool_id" => id, "required_labels" => ["local"], "requirements" => {"ollama" => {
      "model" => model, "expected_digest" => digest, "required_context_length" => 131_072,
      "require_fully_gpu_resident" => true
    }}}
  end

  def job(id, pool_id)
    {"job_id" => id, "pool_id" => pool_id, "group_id" => "ADV-0001",
     "argv" => ["bin/local-fixture-job", pool_id, id], "env" => {}, "depends_on_job_ids" => []}
  end

  def write_job_fixture
    path = File.join(@afw, "bin/local-fixture-job")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, <<~'RUBY')
      #!/usr/bin/env ruby
      path = File.expand_path("../job-order.log", __dir__)
      File.open(path, "a") { |file| file.flock(File::LOCK_EX); file.puts("#{ARGV[0]}:#{ARGV[1]}") }
      sleep Float(ENV.fetch("LOCAL_FIXTURE_JOB_SLEEP", "0.05"))
    RUBY
    File.chmod(0o755, path)
  end

  def write_low_fixture
    path = File.join(@low, "bin/low")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      $LOAD_PATH.unshift #{File.join(@real_low, "lib").inspect}
      %w[
        error contract worker_record capability_evidence_store ollama_capability_request
        capability_bootstrapper local_worker_source publisher_state registry_publisher cli
      ].each { |name| require "local_ollama_workers/\#{name}" }
      class FixtureObserver
        def observe
          {"worker_id" => "fixture-local", "generation_id" => "fixture-generation-1",
           "endpoint" => "http://127.0.0.1:11434"}
        end
      end
      class FixtureHardware
        def gpu_id = "Fixture GPU"
      end
      class FixtureClient
        def initialize(root) = @path = File.join(root, "runtime.json")
        def endpoint = "http://127.0.0.1:11434"
        def version = "fixture-1"
        def installed_models
          [{"model" => #{MODEL_A.inspect}, "digest" => #{DIGEST_A.inspect}},
           {"model" => #{MODEL_B.inspect}, "digest" => #{DIGEST_B.inspect}}]
        end
        def preload!(model:, context_length:)
          File.write(@path, JSON.generate("model" => model, "context_length" => context_length))
        end
        def running_models
          return [] unless File.file?(@path)
          row = JSON.parse(File.binread(@path))
          digest = row.fetch("model") == #{MODEL_A.inspect} ? #{DIGEST_A.inspect} : #{DIGEST_B.inspect}
          digest = "c" * 64 if ENV["LOW_FIXTURE_WRONG_DIGEST"] == "1"
          [{"model" => row.fetch("model"), "digest" => digest,
            "context_length" => ENV["LOW_FIXTURE_WRONG_CONTEXT"] == "1" ? 65_536 : row.fetch("context_length"),
            "fully_gpu_resident" => ENV["LOW_FIXTURE_PARTIAL_RESIDENCY"] != "1",
            "runtime_size_bytes" => 1024, "runtime_size_vram_bytes" => 1024}]
        end
      end
      root = ENV.fetch("LOW_STATE_ROOT")
      if ARGV.first == "bootstrap" && ENV["LOW_FIXTURE_FALSE_BOOTSTRAP"] == "1"
        puts JSON.generate("status" => "ok", "fixture" => "false-success")
        exit 0
      end
      if ARGV.first == "workers" && ENV["LOW_FIXTURE_PUBLICATION_FAILURE"] == "1"
        warn "fixture publication failed"
        exit 7
      end
      components = {observer: FixtureObserver.new, hardware_probe: FixtureHardware.new,
                    client: FixtureClient.new(root)}
      exit LocalOllamaWorkers::CLI.run(ARGV, components: components)
    RUBY
    File.chmod(0o755, path)
  end

  def low(*args)
    stdout, stderr, status = Open3.capture3(
      {"LOW_STATE_ROOT" => @low_state}, File.join(@low, "bin/low"), *args, chdir: @low
    )
    assert status.success?, stderr
    JSON.parse(stdout)
  end

  def execution_paths
    {output: File.join(@front, "output/local-ingest-executions/v0.1", ID, "wlo")}
  end

  def with_environment(values)
    previous = values.to_h { |key, _value| [key, ENV[key]] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def directory(path)
    File.join(@root, path).tap { |value| FileUtils.mkdir_p(value) }
  end
end
