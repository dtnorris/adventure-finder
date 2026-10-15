# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "stringio"
require "timeout"
require "tmpdir"
require "yaml"
require "adventure_finder_local_capability_plan"
require "adventure_finder_local_execution"
require "adventure_finder_operator_acceptance"

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

  # Observes only public CLI results. The FIFO is test payload state, not WLO
  # state: no job can finish until a public bound observation releases it.
  class TraceRunner < PublicReadRunner
    attr_reader :calls, :reports, :demands, :transitions

    def initialize(afw:, wlo:, plan:, output:)
      @afw, @wlo, @plan, @output = afw, wlo, plan, output
      @calls, @reports, @demands, @transitions = [], [], [], []
      @released = []
      @bootstraps = 0
    end

    def capture(environment, *argv, chdir:)
      @calls << argv
      if File.basename(argv.first) == "low" && argv[1] == "bootstrap"
        @bootstraps += 1
        if @bootstraps > 1
          report = public_document("status", @plan, "--output", @output, "--json")
          rows = %w[a b].map do |pool|
            public_document("consumer-demand", @plan, "--output", @output,
                            "--workdir", @afw, "--pool", pool)
          end
          @transitions << {"report" => report, "demands" => rows}
          raise "bootstrap while WLO active" if report.fetch("executor_active") || !report.fetch("paused")
          raise "bootstrap without drained demand" unless rows.all? do |row|
            row.fetch("state") == "paused" && row.fetch("bound_count") == 0 &&
              row.fetch("uncertain_count") == 0 && row.fetch("quiescent")
          end
        end
      end
      result = super
      if File.basename(argv.first) == "wlo" && result.status.success?
        case argv[1]
        when "status"
          @reports << JSON.parse(result.stdout)
        when "consumer-demand"
          row = JSON.parse(result.stdout)
          @demands << row
          release_jobs if row.fetch("bound_count", nil)&.positive?
        end
      end
      result
    end

    def spawn(environment, *argv, **options)
      @calls << argv
      super
    end

    private

    def public_document(*args)
      result = capture({}, File.join(@wlo, "bin/wlo"), *args, chdir: @wlo)
      raise result.stderr unless result.status.success?
      JSON.parse(result.stdout)
    end

    # Release observed bound FIFO payloads; hold the first observation until the
    # next first-pool payload starts. Timeout raises instead of faking readiness.
    def release_jobs
      Dir.glob(File.join(@afw, "barriers/*.started")).each do |path|
        next if @released.include?(path)
        # Nonblocking FIFO open avoids depending on process startup timing.
        begin
          File.open(path.delete_suffix(".started"), File::WRONLY | File::NONBLOCK) { |io| io.write("finish\n") }
          @released << path
          if File.basename(path) == "a-1.started"
            # Keep the first bound observation open until the second first-pool
            # payload owns the worker. This makes the intended four-job trace
            # deterministic without adding unsupported plan dependencies.
            Timeout.timeout(10) do
              sleep 0.005 until File.file?(File.join(@afw, "barriers/a-2.started"))
            end
          end
        rescue Errno::ENXIO
          next
        end
      end
    end
  end

  # Insert a real external public pause at the coordinator's exact request or
  # launch boundary. Command order, rather than sleeps, establishes the overlap.
  class OverlappingPauseRunner < PublicReadRunner
    attr_reader :events

    # Select before/after request or before scoped resume; inputs are public
    # command locators. The command adapter propagates component failures.
    def initialize(ordering:, wlo:, output:)
      @ordering, @wlo, @output = ordering, wlo, output
      @injected = false
      @events = []
    end

    # Interleave one external request around the actual owned-pause command.
    def capture(environment, *argv, chdir:)
      owned = File.basename(argv.first) == "wlo" && argv[1] == "pause" && argv.include?("--owner-token")
      external_pause if owned && @ordering == :before_request && !@injected
      result = super
      @events << {"event" => "owned_request", "time" => Time.now.utc.iso8601(6)} if owned
      external_pause if owned && @ordering == :after_request && !@injected
      result
    end

    # Inject after AF's public ownership check but before WLO's scoped release.
    def spawn(environment, *argv, **options)
      external_pause if argv.include?("--release-pause") && @ordering == :before_resume && !@injected
      super
    end

    private

    # Make a genuine external pause through WLO, never its private storage paths.
    def external_pause
      result = PublicReadRunner.new.capture({}, File.join(@wlo, "bin/wlo"), "pause", "--output", @output, chdir: @wlo)
      raise result.stderr unless result.status.success?
      @injected = true
      @events << {"event" => "external_request", "time" => Time.now.utc.iso8601(6)}
    end
  end

  # Stops one fresh coordinator at an exact public command boundary. The
  # process exits without unwinding so the following invocation must rebuild
  # its next action from durable component facts.
  class ExitBeforeCommandRunner < PublicReadRunner
    def initialize(marker:, executable:, command:, occurrence: 1)
      @marker = marker
      @executable = executable
      @command = command
      @occurrence = occurrence
      @observed = 0
    end

    def capture(environment, *argv, chdir:)
      if File.basename(argv.first) == @executable && argv[1] == @command
        @observed += 1
        if @observed == @occurrence
          File.write(@marker, JSON.generate("argv" => argv, "chdir" => chdir))
          exit! 73
        end
      end
      super
    end
  end

  class ExitBeforeSpawnRunner < PublicReadRunner
    def initialize(marker:)
      @marker = marker
    end

    def spawn(_environment, *argv, chdir:, **)
      File.write(@marker, JSON.generate("argv" => argv, "chdir" => chdir))
      exit! 74
    end
  end

  class RecordingSpawnRunner < PublicReadRunner
    def initialize(marker:)
      @marker = marker
    end

    def spawn(environment, *argv, **options)
      handle = super
      File.write(@marker, handle.pid.to_s)
      handle
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
    full_workload = [
      "test_real_low_and_wlo_public_seams_complete_two_capabilities_in_one_execution",
      "test_breaker_requires_separate_explicit_acknowledgement"
    ].include?(name)
    @barrier_mode = full_workload
    write_workload(jobs_per_pool: full_workload ? 2 : 1)
    if @barrier_mode
      directory("components/af-workloads/barriers")
      %w[a-1 a-2 b-1 b-2].each { |id| File.mkfifo(File.join(@afw, "barriers", id)) }
    end
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
    trace = TraceRunner.new(afw: @afw, wlo: @wlo, plan: @plan_path, output: execution_paths.fetch(:output))
    service = coordinator(runner: trace)
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
    assert_composed_trace(trace, intent, jobs, output)
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
    sentinel = Process.spawn(RbConfig.ruby, "-e", "sleep 30", pgroup: true,
                             out: File::NULL, err: File::NULL)
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
    assert process_alive?(sentinel), "foreground cancellation reached an unrelated sentinel"

    before = retained_output_files
    code, stdout, stderr = public_wlo(
      "action-check", @plan_path, "--workdir", @afw, "--output", output,
      "--action", "resume", "--json"
    )
    assert_equal 0, code, stderr
    assert_equal "interrupted_attempts", JSON.parse(stdout).fetch("reason")
    error = assert_raises(AdventureFinderWorkspace::LocalExecution::Failure) do
      coordinator.resume(operation_id: ID, capability_plan: @capability_plan)
    end
    assert_equal "WLO_EXECUTION_GATE", error.code
    assert_equal before, retained_output_files
  ensure
    if pid
      Process.kill("TERM", pid) rescue Errno::ESRCH
      Process.waitpid(pid) rescue Errno::ECHILD
    end
    if sentinel
      Process.kill("TERM", -sentinel) rescue Errno::ESRCH
      Process.waitpid(sentinel) rescue Errno::ECHILD
    end
  end

  # A fresh service can continue a real retained WLO-owned hold, preserving jobs.
  def test_fresh_resume_reconstructs_a_persisted_coordinator_drain
    paths = execution_paths
    store = WorkloadOrchestrator::ExecutionStore.new(
      plan: WorkloadOrchestrator::Plan.load(@plan_path), workdir: @afw, output_dir: paths.fetch(:output)
    )
    store.prepare!
    store.pause!
    store.clear_pause!
    token = "e" * 64
    code, _stdout, stderr = public_wlo("pause", "--output", paths.fetch(:output), "--owner-token", token)
    assert_equal 0, code, stderr
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
        "pause_token" => token, "updated_at" => Time.now.utc.iso8601
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
      puts "IG-15C3 control: #{JSON.generate('bootstrap_exit' => 0, 'ready' => false, 'gate' => error.code, 'completion' => false)}"
      refute File.exist?(File.join(@front, "output/local-ingest-executions/v0.1", ID, "wlo", "execution.json"))
    end
  end

  def test_real_paused_zero_exit_is_not_workload_completion
    output = execution_paths.fetch(:output)
    store = WorkloadOrchestrator::ExecutionStore.new(
      plan: WorkloadOrchestrator::Plan.load(@plan_path), workdir: @afw, output_dir: output
    )
    store.prepare!
    runner = PublicReadRunner.new
    pause = runner.capture({}, File.join(@wlo, "bin/wlo"), "pause", "--output", output, chdir: @wlo)
    assert pause.status.success?, pause.stderr
    # Use the real CLI with a valid LOW-only source. A paused WLO run exits 0.
    sources = File.join(@root, "paused-sources.yml")
    File.write(sources, YAML.dump(
      "contract_version" => "wlo-worker-sources/v0.2", "sources" => [{
        "name" => "local", "command" => File.join(@low, "bin/low"), "args" => ["workers", "--json"],
        "environment" => {"LOW_STATE_ROOT" => @low_state}, "workdir" => @low, "policy" => "required"
      }]
    ))
    result = runner.capture({}, File.join(@wlo, "bin/wlo"), "run", @plan_path,
                            "--workdir", @afw, "--output", output, "--worker-sources-config", sources, chdir: @wlo)
    assert_equal 0, result.status.exitstatus, result.stderr
    out = StringIO.new
    error = assert_raises(AdventureFinderWorkspace::LocalExecution::Failure) do
      coordinator(out:).start(operation_id: ID, selected_by: "David", capability_plan: @capability_plan)
    end
    assert_equal "OPERATOR_PAUSE", error.code
    refute_includes out.string, "terminal: completed"
    report = runner.capture({}, File.join(@wlo, "bin/wlo"), "status", @plan_path, "--output", output, "--json", chdir: @wlo)
    document = JSON.parse(report.stdout)
    assert_equal "paused", document.fetch("status")
    assert_equal 2, document.dig("counts", "pending")
    assert_equal 0, document.dig("counts", "complete")
    puts "IG-15C3 control: #{JSON.generate('wlo_exit' => result.status.exitstatus, 'wlo_status' => document.fetch('status'), 'gate' => error.code, 'counts' => document.fetch('counts'), 'completion' => false)}"
    refute File.exist?(File.join(@afw, "job-order.log"))
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
      {"disposition" => "blocked", "reason" => "executor_active", "execution_status" => nil}
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

  def test_fresh_process_restart_before_first_capability_request_reconstructs_bootstrap
    marker = File.join(@root, "before-first-bootstrap.json")
    runner = ExitBeforeCommandRunner.new(
      marker:, executable: "low", command: "bootstrap"
    )

    assert_equal 73, coordinator_process(:start, runner:).exitstatus
    assert File.file?(marker)
    refute File.exist?(File.join(@low_state, "runtime.json"))
    refute File.exist?(File.join(execution_paths.fetch(:output), "execution.json"))

    assert_equal 0, coordinator_process(:resume).exitstatus
    assert_completed_once
  end

  def test_fresh_process_restart_after_ready_before_wlo_start_preserves_identity
    marker = File.join(@root, "before-wlo-spawn.json")

    assert_equal 74, coordinator_process(:start, runner: ExitBeforeSpawnRunner.new(marker:)).exitstatus
    assert File.file?(marker)
    assert File.file?(File.join(@low_state, "local-capability-evidence-v1.json"))
    refute File.exist?(File.join(execution_paths.fetch(:output), "execution.json"))
    intent_before = File.binread(intent_path)

    assert_equal 0, coordinator_process(:resume).exitstatus
    assert_equal intent_before, File.binread(intent_path)
    assert_completed_once
  end

  def test_interrupted_capability_establishment_restarts_from_public_low_facts
    fifo = File.join(@root, "establishment.fifo")
    File.mkfifo(fifo)
    pid = coordinator_process(
      :start, wait: false,
      environment: {"LOW_FIXTURE_ESTABLISHMENT_FIFO" => fifo}
    )
    await_file("#{fifo}.started")
    low_pid = Integer(File.binread("#{fifo}.started"))

    Process.kill("KILL", pid)
    assert_equal 9, Process.waitpid2(pid).last.termsig
    Process.kill("TERM", low_pid)
    await { !process_alive?(low_pid) }
    refute File.exist?(File.join(@low_state, "local-capability-evidence-v1.json"))
    refute File.exist?(File.join(execution_paths.fetch(:output), "execution.json"))

    assert_equal 0, coordinator_process(:resume).exitstatus
    assert_completed_once
  ensure
    signal_process("KILL", pid)
    signal_process("KILL", low_pid)
  end

  def test_restart_after_completed_work_reconciles_generation_change_without_replay
    marker = File.join(@root, "before-second-bootstrap.json")
    runner = ExitBeforeCommandRunner.new(
      marker:, executable: "low", command: "bootstrap", occurrence: 2
    )

    first = coordinator_process(
      :start, runner:, environment: {"LOW_FIXTURE_GENERATION" => "fixture-generation-1"}
    )
    assert_equal 73, first.exitstatus
    assert File.file?(marker)
    before = retained_job("a-1")
    assert_equal "complete", before.fetch("status")
    assert_equal 1, before.fetch("attempt")
    assert_equal "fixture-generation-1", before.dig("worker_execution_identity", "generation_id")

    second = coordinator_process(
      :resume, environment: {"LOW_FIXTURE_GENERATION" => "fixture-generation-2"}
    )
    assert_equal 0, second.exitstatus
    after = retained_job("a-1")
    assert_equal before, after
    assert_equal "fixture-generation-2", retained_job("b-1").dig("worker_execution_identity", "generation_id")
    assert_completed_once
  end

  def test_public_operator_pause_remains_a_gate_until_explicit_continue
    result_path = File.join(@root, "operator-pause-result.txt")
    pid = fork do
      ENV["LOCAL_FIXTURE_JOB_SLEEP"] = "1"
      begin
        coordinator.start(operation_id: ID, selected_by: "David", capability_plan: @capability_plan)
        exit! 0
      rescue AdventureFinderWorkspace::LocalExecution::Failure => e
        File.write(result_path, e.code)
        exit! 75
      end
    end
    await_file(File.join(@afw, "job-order.log"))
    code, _stdout, stderr = public_wlo("pause", "--output", execution_paths.fetch(:output))
    assert_equal 0, code, stderr
    assert_equal 75, Timeout.timeout(10) { Process.waitpid2(pid).last.exitstatus }
    pid = nil
    assert_equal "OPERATOR_PAUSE", File.binread(result_path)
    completed_before = retained_job("a-1")

    error = assert_raises(AdventureFinderWorkspace::LocalExecution::Failure) do
      coordinator.resume(operation_id: ID, capability_plan: @capability_plan)
    end
    assert_equal "OPERATOR_PAUSE", error.code
    assert_equal completed_before, retained_job("a-1")

    assert_equal 0, coordinator.resume(
      operation_id: ID, capability_plan: @capability_plan, continue_operator_pause: true
    )
    assert_equal completed_before, retained_job("a-1")
    assert_completed_once
  ensure
    signal_process("KILL", pid)
    reap_process(pid)
  end

  def test_detached_wlo_owner_loss_exposes_orphaned_attempt_without_cleanup_claim
    manager_marker = File.join(@root, "wlo-manager.pid")
    sentinel = Process.spawn(RbConfig.ruby, "-e", "sleep 30", pgroup: true,
                             out: File::NULL, err: File::NULL)
    coordinator_pid = coordinator_process(
      :start, wait: false, runner: RecordingSpawnRunner.new(marker: manager_marker),
      environment: {"LOCAL_FIXTURE_JOB_SLEEP" => "30"}
    )
    await_file(manager_marker)
    await_file(File.join(@afw, "job-a-1.pid"))
    manager_pid = Integer(File.binread(manager_marker))
    job_pid = Integer(File.binread(File.join(@afw, "job-a-1.pid")))

    Process.kill("KILL", manager_pid)
    assert_equal 70, Timeout.timeout(10) { Process.waitpid2(coordinator_pid).last.exitstatus }
    coordinator_pid = nil
    assert process_alive?(job_pid), "manager loss unexpectedly cleaned up an owned job"
    assert process_alive?(sentinel), "manager loss reached an unrelated sentinel"

    output = execution_paths.fetch(:output)
    code, stdout, stderr = public_wlo(
      "action-check", @plan_path, "--workdir", @afw, "--output", output,
      "--action", "resume", "--json"
    )
    assert_equal 0, code, stderr
    check = JSON.parse(stdout)
    assert_equal "blocked", check.fetch("disposition")
    assert_includes %w[inactive_running_state running_attempts], check.fetch("reason")
    error = assert_raises(AdventureFinderWorkspace::LocalExecution::Failure) do
      coordinator.resume(operation_id: ID, capability_plan: @capability_plan)
    end
    assert_includes %w[WLO_EXECUTION_GATE LOCAL_TRANSITION_GATE], error.code
    assert_equal 1, retained_job("a-1").fetch("attempt")
  ensure
    signal_process("KILL", coordinator_pid)
    reap_process(coordinator_pid)
    signal_process("KILL", job_pid, group: true)
    signal_process("TERM", sentinel, group: true)
    reap_process(sentinel)
  end

  def test_failed_work_requires_selected_retry_and_preserves_archived_evidence
    with_environment("LOCAL_FIXTURE_FAIL_ONCE_JOB" => "a-1") do
      error = assert_raises(AdventureFinderWorkspace::LocalExecution::Failure) do
        coordinator.start(operation_id: ID, selected_by: "David", capability_plan: @capability_plan)
      end
      assert_equal "WLO_EXECUTION_GATE", error.code
    end
    output = execution_paths.fetch(:output)
    failed_before = evidence_bytes("a-1")
    b_before = retained_job("b-1")
    invocation_count = job_invocations.length

    error = assert_raises(AdventureFinderWorkspace::LocalExecution::Failure) do
      coordinator.resume(operation_id: ID, capability_plan: @capability_plan)
    end
    assert_equal "WLO_EXECUTION_GATE", error.code
    assert_equal invocation_count, job_invocations.length
    refute Dir.exist?(File.join(output, "attempts"))

    code, _stdout, stderr = public_wlo(
      "retry-failed", @plan_path, "--workdir", @afw, "--output", output,
      "--job", "a-1", "--reason", "reviewed fixture failure"
    )
    assert_equal 0, code, stderr
    assert_equal failed_before, evidence_bytes("a-1", archive: 1)
    assert_equal invocation_count, job_invocations.length, "authorization must not execute work"

    assert_equal 0, coordinator.resume(
      operation_id: ID, capability_plan: @capability_plan, continue_operator_pause: true
    )
    assert_equal 2, retained_job("a-1").fetch("attempt")
    assert_equal b_before, retained_job("b-1")
    assert_equal failed_before, evidence_bytes("a-1", archive: 1)
    assert_equal 1, job_invocations.count("b-1")
    runtime_events = File.readlines(File.join(@low_state, "runtime-events.jsonl")).map { |row| JSON.parse(row) }
    assert_equal [MODEL_A], runtime_events.last.fetch("resident")
  end

  def test_breaker_requires_separate_explicit_acknowledgement
    with_environment("LOCAL_FIXTURE_FAIL_ALWAYS_POOL" => "a") do
      error = assert_raises(AdventureFinderWorkspace::LocalExecution::Failure) do
        coordinator.start(operation_id: ID, selected_by: "David", capability_plan: @capability_plan)
      end
      assert_equal "WLO_EXECUTION_GATE", error.code
    end
    output = execution_paths.fetch(:output)
    state_before = File.binread(File.join(output, "execution.json"))
    evidence_before = %w[a-1 a-2].to_h { |id| [id, evidence_bytes(id)] }

    code, stdout, stderr = public_wlo(
      "action-check", @plan_path, "--workdir", @afw, "--output", output,
      "--action", "resume", "--json"
    )
    assert_equal 0, code, stderr
    check = JSON.parse(stdout)
    assert_equal "blocked", check.fetch("disposition")
    assert_equal "circuit_breaker", check.fetch("reason")

    code, _stdout, stderr = public_wlo(
      "retry-failed", @plan_path, "--workdir", @afw, "--output", output,
      "--job", "a-1", "--reason", "reviewed fixture breaker"
    )
    assert_equal 1, code
    assert_includes stderr, "--acknowledge-circuit-breaker"
    assert_equal state_before, File.binread(File.join(output, "execution.json"))
    evidence_before.each { |id, bytes| assert_equal bytes, evidence_bytes(id) }
    refute Dir.exist?(File.join(output, "attempts"))
  end

  def test_restart_refuses_changed_operation_plan_sequence_and_execution_locator
    marker = File.join(@root, "bound-before-spawn.json")
    assert_equal 74, coordinator_process(:start, runner: ExitBeforeSpawnRunner.new(marker:)).exitstatus
    refute File.exist?(File.join(execution_paths.fetch(:output), "execution.json"))

    changed_authority = deep_copy(@capability_plan)
    changed_authority.fetch("operation")["authority_id"] = "changed-authority"
    changed_operation_intent = deep_copy(@capability_plan)
    changed_operation_intent.fetch("operation")["intent_id"] = "changed-intent"
    changed_sequence = deep_copy(@capability_plan)
    changed_sequence.fetch("sequence").first.fetch("job_ids") << "invented-job"
    changed_request = deep_copy(@capability_plan)
    changed_request.fetch("capabilities").first.fetch("capability_request")["model"] = "changed:latest"
    changed_plan = deep_copy(@capability_plan)
    changed_plan.fetch("workload")["plan_sha256"] = "f" * 64

    [changed_authority, changed_operation_intent, changed_sequence, changed_request, changed_plan].each do |changed|
      error = assert_raises(AdventureFinderWorkspace::LocalExecution::Failure) do
        coordinator.resume(operation_id: ID, capability_plan: changed)
      end
      assert_equal "STALE_LOCAL_EXECUTION", error.code
    end

    moved = @environment.merge("AF_AFW_ROOT" => directory("different-afw"))
    error = assert_raises(AdventureFinderWorkspace::LocalExecution::Failure) do
      AdventureFinderWorkspace::LocalExecution.new(
        front_door_root: @front, project_root: @components, env: moved, out: StringIO.new,
        poll_interval: 0.02, observation_timeout: 1.0
      ).resume(operation_id: ID, capability_plan: @capability_plan)
    end
    assert_equal "STALE_LOCAL_EXECUTION", error.code
    refute File.exist?(File.join(execution_paths.fetch(:output), "execution.json"))
  end

  # A final WLO failure outranks a concurrently visible owned drain marker;
  # the existing recovery gate must not be misreported as an incomplete drain.
  def test_terminal_failure_during_owned_drain_keeps_execution_gate
    service = coordinator
    token = "d" * 64
    report = {"status" => "workload_failed", "paused" => true, "executor_active" => false,
      "pause_control" => {"operator_pause" => false, "request_ids" => [Digest::SHA256.hexdigest(token)]}}
    service.define_singleton_method(:execution_report) { |*, **| report }
    service.define_singleton_method(:demands) do |*, **|
      {"b" => {"state" => "workload_failed", "bound_count" => 0, "uncertain_count" => 0, "quiescent" => true}}
    end
    handle = Object.new
    handle.define_singleton_method(:finished?) { true }
    handle.define_singleton_method(:wait) { PublicReadRunner::Status.new(2) }
    error = assert_raises(AdventureFinderWorkspace::LocalExecution::Failure) do
      service.send(:monitor, {}, @capability_plan, {}, {"phase" => "draining", "pause_token" => token}, handle)
    end
    assert_equal "WLO_EXECUTION_GATE", error.code
  end

  # Public external requests remain effective on either side of an owned pause.
  def test_external_pause_before_owned_request_is_not_cleared
    assert_overlap_is_gated(:before_request)
  end

  # A later operator hold cannot be overwritten by a coordinator's retained phase.
  def test_external_pause_after_owned_request_is_not_cleared
    assert_overlap_is_gated(:after_request)
  end

  # The WLO release operation itself protects a request arriving after AF's check.
  def test_external_pause_at_scoped_resume_is_not_cleared
    assert_overlap_is_gated(:before_resume)
  end

  # A legacy marker plus an asserted drain phase is not proof of ownership.
  def test_legacy_drain_state_does_not_gain_automatic_operator_authority
    paths = execution_paths
    store = WorkloadOrchestrator::ExecutionStore.new(
      plan: WorkloadOrchestrator::Plan.load(@plan_path), workdir: @afw, output_dir: paths.fetch(:output))
    store.prepare!
    store.pause!
    intent = AdventureFinderWorkspace::LocalExecutionIntentStore.new(
      root: File.join(@front, "output/local-ingest-executions/v0.1")).capture!(
        operation_id: ID, selected_by: "David", capability_plan: @capability_plan,
        components: {"afw" => @afw, "low" => @low, "wlo" => @wlo}, workdir: @afw, output: paths.fetch(:output))
    state_path = File.join(File.dirname(paths.fetch(:output)), "state.json")
    document = {"contract_version" => AdventureFinderWorkspace::LocalExecution::STATE_VERSION,
      "intent_id" => intent.fetch("intent_id"), "phase" => "draining", "step" => 1}
    [nil, "a" * 64, "corrupt"].each do |token|
      File.write(state_path, JSON.generate(document.merge("pause_token" => token)))
      before = retained_output_files
      error = assert_raises(AdventureFinderWorkspace::LocalExecution::Failure) do
        coordinator.resume(operation_id: ID, capability_plan: @capability_plan)
      end
      assert_equal token == "corrupt" ? "CORRUPT_LOCAL_EXECUTION_STATE" : "OPERATOR_PAUSE", error.code
      assert_equal before, retained_output_files
      assert_empty job_invocations
    end
    # A missing hold cannot be interpreted as permission after a cold restart.
    store.clear_pause!
    File.write(state_path, JSON.generate(document.merge("pause_token" => "a" * 64)))
    before = retained_output_files
    error = assert_raises(AdventureFinderWorkspace::LocalExecution::Failure) do
      coordinator.resume(operation_id: ID, capability_plan: @capability_plan)
    end
    assert_equal "OPERATOR_PAUSE", error.code
    assert_equal before, retained_output_files
    assert_empty job_invocations
  end

  private

  # Assert the same safety invariant for a deterministic public interleaving;
  # a fresh process must also refuse, and explicit manual continuation completes
  # both jobs once. Component/test errors propagate without retrying the journey.
  def assert_overlap_is_gated(ordering)
    runner = OverlappingPauseRunner.new(ordering: ordering, wlo: @wlo, output: execution_paths.fetch(:output))
    error = assert_raises(AdventureFinderWorkspace::LocalExecution::Failure) do
      coordinator(runner:).start(operation_id: ID, selected_by: "David", capability_plan: @capability_plan)
    end
    assert_equal "OPERATOR_PAUSE", error.code
    puts "PAUSE_INTERLEAVING=#{JSON.generate(ordering: ordering, events: runner.events)}"
    before = retained_job("a-1")
    assert_equal "complete", before.fetch("status")
    pid = fork do
      begin
        coordinator.resume(operation_id: ID, capability_plan: @capability_plan)
        exit! 1
      rescue AdventureFinderWorkspace::LocalExecution::Failure => refusal
        exit! refusal.code == "OPERATOR_PAUSE" ? 0 : 2
      end
    end
    assert_equal 0, Timeout.timeout(10) { Process.waitpid2(pid).last.exitstatus }
    pid = nil
    assert_equal before, retained_job("a-1")
    assert_equal 0, coordinator.resume(operation_id: ID, capability_plan: @capability_plan, continue_operator_pause: true)
    assert_completed_once
  ensure
    signal_process("KILL", pid)
    reap_process(pid)
  end

  # Verify original execution locators, scoped continuation, and all four attempts
  # against captured public evidence; assertion failures expose contract drift.
  def assert_composed_trace(trace, intent, jobs, output)
    require File.join(ENV.fetch("AF_AFW_SOURCE_ROOT"), "test/support/afw_wlo_v0_3_contract")
    validator = Object.new.extend(AfwWloV03Contract)
    validator.send(:validate_contract!, JSON.parse(File.binread(@plan_path)))
    assert_equal %w[a-1 a-2 b-1 b-2], @capability_plan.fetch("sequence").flat_map { |step| step.fetch("job_ids") }
    assert_equal 2, @capability_plan.fetch("accounting").fetch("capability_count")
    assert defined?(AdventureFinderOfflineNetworkGuard), "proof requires the hard offline guard"
    AdventureFinderWorkspace::OperatorAcceptance::CREDENTIAL_NAMES.each { |key| assert_nil ENV[key], "credential inherited: #{key}" }
    assert_equal "authority-fixture", @capability_plan.dig("operation", "authority_id")
    assert_operator trace.transitions.length, :>=, 1
    assert trace.transitions.all? { |row| row.dig("report", "status") == "paused" }
    assert trace.transitions.none? { |row| row.dig("report", "executor_active") }
    assert trace.transitions.all? do |row|
      row.fetch("demands").all? do |demand|
        demand.fetch("bound_count") == 0 && demand.fetch("uncertain_count") == 0 && demand.fetch("quiescent")
      end
    end
    transition = trace.transitions.first
    assert_equal %w[a-1 a-2], transition.fetch("report").fetch("jobs").select { |row| row.fetch("status") == "complete" }.map { |row| row.fetch("job_id") }
    assert_equal %w[b-1 b-2], transition.fetch("report").fetch("jobs").select { |row| row.fetch("status") == "pending" }.map { |row| row.fetch("job_id") }
    identity = intent.dig("execution", "consumer_id")
    assert trace.demands.all? { |row| row.fetch("consumer_id") == identity }
    assert trace.reports.all? { |row| row.fetch("plan_sha256") == @capability_plan.dig("workload", "plan_sha256") }
    assert_equal 1, trace.reports.map { |row| row.dig("counts", "running") }.max
    assert_equal 1, trace.demands.map { |row| row.fetch("bound_count") }.compact.max
    launches = trace.calls.select { |argv| File.basename(argv.first) == "wlo" && %w[run resume].include?(argv[1]) }
    assert_equal "run", launches.first[1]
    assert launches.drop(1).all? { |argv| argv[1] == "resume" }
    assert launches.drop(1).all? { |argv| argv.include?("--release-pause") || argv.include?("--preserve-pauses") }
    locators = launches.map do |argv|
      arguments = argv.drop(2).dup
      arguments.slice!(arguments.index("--release-pause"), 2) if arguments.include?("--release-pause")
      arguments.delete("--preserve-pauses")
      arguments
    end
    assert_equal 1, locators.uniq.length
    refute trace.calls.any? { |argv| argv.any? { |arg| arg.match?(/rpof|runpod|retry-failed|acknowledge-circuit-breaker/) } }

    events = File.readlines(File.join(@low_state, "runtime-events.jsonl")).map { |row| JSON.parse(row) }
    assert_equal [[MODEL_A], [MODEL_B]], events.map { |row| row.fetch("resident") }.chunk_while { |left, right| left == right }.map(&:first)
    assert_nil events.first.fetch("previous")
    first_b = events.find { |row| row.fetch("resident") == [MODEL_B] }
    assert_equal MODEL_A, first_b.dig("previous", "model")
    assert_equal [131_072], events.map { |row| row.fetch("context_length") }.uniq
    publications = File.readlines(File.join(@low_state, "publications.jsonl")).map do |row|
      bytes = JSON.parse(row).fetch("bytes")
      {"sha256" => Digest::SHA256.hexdigest(bytes), "snapshot" => JSON.parse(bytes)}
    end
    assert_empty publications.first.fetch("snapshot").fetch("workers")
    assert_equal 1, publications.map { |row| row.dig("snapshot", "registry_id") }.uniq.length
    assert publications.all? { |row| row.fetch("snapshot").fetch("workers").length <= 1 }
    bound_rows = jobs.map do |job|
      metadata = JSON.parse(File.binread(File.join(output, "runs", job.fetch("job_id"), "metadata.json")))
      binding = WorkloadOrchestrator::DynamicWorkerBinding.from_metadata(metadata)
      publication = publications.find { |row| row.fetch("sha256") == binding.registry_binding.fetch("registry_snapshot_sha256") }
      refute_nil publication, "attempt must bind an actual LOW public snapshot"
      worker = publication.fetch("snapshot").fetch("workers").fetch(0)
      assert_equal "READY", worker.fetch("state")
      assert_equal binding.execution_identity.fetch("capability_fingerprint"), worker.fetch("capability_fingerprint")
      assert_equal binding.registry_binding.fetch("registry_revision"), publication.dig("snapshot", "revision")
      assert_equal "fixture-local", binding.execution_identity.fetch("worker_id")
      assert_equal "fixture-generation-1", binding.execution_identity.fetch("generation_id")
      assert_equal "complete", metadata.fetch("status")
      assert_equal 0, metadata.fetch("exit_status")
      assert_equal 1, metadata.fetch("attempt")
      refute Dir.exist?(File.join(output, "attempts", job.fetch("job_id")))
      pool = WorkloadOrchestrator::Plan.load(@plan_path).pool(job.fetch("pool_id"))
      registry = WorkloadOrchestrator::DynamicWorkerRegistry.new(JSON.generate(publication.fetch("snapshot")), now: Time.iso8601(publication.dig("snapshot", "published_at")))
      assert WorkloadOrchestrator::CapabilityMatcher.match(worker: registry.schedulable_workers.fetch(0), required_labels: pool.required_labels, ollama_requirement: pool.ollama_requirement).compatible?
      {"job_id" => job.fetch("job_id"), "pool_id" => job.fetch("pool_id"), "attempt" => metadata.fetch("attempt"),
       "status" => metadata.fetch("status"), "worker_identity" => binding.execution_identity,
       "registry_binding" => binding.registry_binding}
    end
    a, b = bound_rows.group_by { |row| row.fetch("pool_id") }.values_at("a", "b")
    assert_equal 1, a.map { |row| row.dig("worker_identity", "capability_fingerprint") }.uniq.length
    assert_equal 1, b.map { |row| row.dig("worker_identity", "capability_fingerprint") }.uniq.length
    refute_equal a.first.dig("worker_identity", "capability_fingerprint"), b.first.dig("worker_identity", "capability_fingerprint")
    assert_operator b.first.dig("registry_binding", "registry_revision"), :>, a.last.dig("registry_binding", "registry_revision")
    assert_equal %w[a-1 a-2 b-1 b-2], File.readlines(File.join(@afw, "job-order.log"), chomp: true).map { |row| row.split(":").last }.sort
    final = trace.reports.last
    assert_equal "completed", final.fetch("status")
    assert_equal({"complete" => 4, "failed" => 0, "running" => 0, "pending" => 0}, final.fetch("counts"))
    assert final.fetch("pool_status").all? { |row| row.fetch("reason") == "COMPLETE" }
    # Both pools are compatible with LOW's retained evidence, but the barrier
    # and nonblocking slot lock prove they cannot execute simultaneously.
    assert_equal [1, 1], final.fetch("pool_status").map { |row| row.dig("workers", "compatible_ready") }
    puts "IG-15C3 evidence: #{JSON.generate(
      'operation_id' => ID, 'workload' => @capability_plan.fetch('workload'),
      'execution' => intent.fetch('execution'), 'capabilities' => @capability_plan.fetch('capabilities'),
      'launch_commands' => launches.map { |argv| argv[1] },
      'consumer_id' => identity, 'sequence_sha256' => intent.dig('workload', 'capability_sequence_sha256'),
      'sequence' => @capability_plan.fetch('sequence'), 'transition_status' => transition.dig('report', 'status'),
      'transition_demands' => transition.fetch('demands'), 'runtime_residency' => events,
      'max_running' => 1, 'sole_source' => 'local', 'attempts' => bound_rows, 'final_counts' => final.fetch('counts')
    )}"
  end

  def assert_runtime_mismatch_rejected(variable)
    with_environment(variable => "1") do
      error = assert_raises(AdventureFinderWorkspace::LocalExecution::Failure) do
        coordinator.start(operation_id: ID, selected_by: "David", capability_plan: @capability_plan)
      end
      assert_equal "LOW_BOOTSTRAP_FAILED", error.code
      refute File.exist?(File.join(@front, "output/local-ingest-executions/v0.1", ID, "wlo", "execution.json"))
    end
  end

  def coordinator(out: StringIO.new, runner: PublicReadRunner.new)
    AdventureFinderWorkspace::LocalExecution.new(
      front_door_root: @front, project_root: @components, env: @environment, out:,
      runner:,
      poll_interval: 0.02, observation_timeout: 5.0
    )
  end

  def coordinator_process(action, runner: PublicReadRunner.new, environment: {}, wait: true)
    error_path = File.join(@root, "coordinator-process-error.txt")
    pid = fork do
      environment.each { |key, value| ENV[key] = value }
      begin
        status = if action == :start
                   coordinator(runner:).start(
                     operation_id: ID, selected_by: "David", capability_plan: @capability_plan
                   )
                 else
                   coordinator(runner:).resume(operation_id: ID, capability_plan: @capability_plan)
                 end
        exit! status
      rescue Exception => e # rubocop:disable Lint/RescueException -- child must report before exit!
        File.write(error_path, "#{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}")
        exit! 70
      end
    end
    return pid unless wait

    status = Timeout.timeout(15) { Process.waitpid2(pid).last }
    flunk File.binread(error_path) if status.exitstatus == 70 && File.file?(error_path)
    status
  end

  def assert_completed_once
    output = execution_paths.fetch(:output)
    assert_equal "completed", JSON.parse(File.binread(File.join(output, "execution.json"))).fetch("status")
    %w[a-1 b-1].each do |job_id|
      metadata = retained_job(job_id)
      assert_equal "complete", metadata.fetch("status")
      assert_equal 1, metadata.fetch("attempt")
      assert_equal 1, job_invocations.count(job_id)
    end
  end

  def retained_job(job_id)
    JSON.parse(File.binread(File.join(execution_paths.fetch(:output), "runs", job_id, "metadata.json")))
  end

  def evidence_bytes(job_id, archive: nil)
    root = if archive
             File.join(execution_paths.fetch(:output), "attempts", job_id, "attempt-#{archive}")
           else
             File.join(execution_paths.fetch(:output), "runs", job_id)
           end
    Dir.children(root).sort.to_h { |name| [name, File.binread(File.join(root, name))] }
  end

  def retained_output_files
    output = execution_paths.fetch(:output)
    Dir.glob(File.join(output, "**", "*"), File::FNM_DOTMATCH)
       .select { |path| File.file?(path) }
       .sort
       .to_h { |path| [path.delete_prefix("#{output}/"), File.binread(path)] }
  end

  def job_invocations
    path = File.join(@afw, "job-order.log")
    return [] unless File.file?(path)

    File.readlines(path, chomp: true).map { |row| row.split(":").last }
  end

  def public_wlo(*arguments)
    stdout, stderr, status = Open3.capture3(
      {"AF_PROJECT_ROOT" => @components, "AF_ADVENTURE_FINDER_ROOT" => @front, "AFW_ROOT" => @afw},
      File.join(@wlo, "bin/wlo"), *arguments, chdir: @wlo
    )
    [status.exitstatus, stdout, stderr]
  end

  def intent_path
    File.join(@front, "output/local-ingest-executions/v0.1", ID, "intent.json")
  end

  def deep_copy(value)
    JSON.parse(JSON.generate(value))
  end

  def await_file(path)
    Timeout.timeout(10) do
      sleep 0.01 until File.file?(path) && !File.zero?(path)
    end
  end

  def await
    Timeout.timeout(10) do
      loop do
        return true if yield
        sleep 0.01
      end
    end
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def signal_process(signal, pid, group: false)
    return unless pid

    Process.kill(signal, group ? -pid : pid)
  rescue Errno::ESRCH, TypeError
    nil
  end

  def reap_process(pid)
    Process.waitpid(pid) if pid
  rescue Errno::ECHILD, TypeError
    nil
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
     "argv" => ["bin/local-fixture-job", pool_id, id],
     "env" => {"LOCAL_FIXTURE_RUNTIME" => File.join(@low_state, "runtime.json"),
               "LOCAL_FIXTURE_BARRIER" => @barrier_mode ? "1" : nil}, "depends_on_job_ids" => []}
  end

  def write_job_fixture
    path = File.join(@afw, "bin/local-fixture-job")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, <<~'RUBY')
      #!/usr/bin/env ruby
      require "json"
      root = File.expand_path("..", __dir__)
      File.open(File.join(root, "worker-slot.lock"), "w") do |slot|
        abort "two simultaneous worker slots" unless slot.flock(File::LOCK_EX | File::LOCK_NB)
        File.write(File.join(root, "job-#{ARGV[1]}.pid"), Process.pid.to_s)
        expected = "fixture-#{ARGV[0]}:latest"
        runtime = JSON.parse(File.binread(ENV.fetch("LOCAL_FIXTURE_RUNTIME")))
        abort "model not resident" unless runtime.fetch("model") == expected
        abort "wrong endpoint" unless ENV.fetch("WLO_WORKER_ENDPOINT") == "http://127.0.0.1:11434"
        File.open(File.join(root, "job-order.log"), "a") do |file|
          file.flock(File::LOCK_EX)
          file.puts("#{ARGV[0]}:#{ARGV[1]}")
        end
        fail_once = ENV["LOCAL_FIXTURE_FAIL_ONCE_JOB"] == ARGV[1]
        fail_always = ENV["LOCAL_FIXTURE_FAIL_ALWAYS_POOL"] == ARGV[0]
        failure_marker = File.join(root, ".failed-once-#{ARGV[1]}")
        if fail_always || (fail_once && !File.exist?(failure_marker))
          File.write(failure_marker, "failed\n") if fail_once
          warn "intentional fixture failure for #{ARGV[1]}"
          exit 17
        end
        if ENV["LOCAL_FIXTURE_BARRIER"] == "1"
          abort "offline guard missing from payload" unless defined?(AdventureFinderOfflineNetworkGuard)
          %w[RUNPOD_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY GOOGLE_API_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN].each do |key|
            abort "credential inherited" if ENV[key]
          end
          begin
            TCPSocket.new("127.0.0.1", 11434)
            abort "network guard did not block"
          rescue IOError => e
            abort "unexpected network error" unless e.message == AdventureFinderOfflineNetworkGuard::MESSAGE
          end
          fifo = File.join(root, "barriers", ARGV[1])
          File.write("#{fifo}.started", "started")
          File.open(fifo, "r") { |io| abort "missing release" unless io.gets == "finish\n" }
        else
          sleep Float(ENV.fetch("LOCAL_FIXTURE_JOB_SLEEP", "0.05"))
        end
        abort "runtime changed during attempt" unless JSON.parse(File.binread(ENV.fetch("LOCAL_FIXTURE_RUNTIME"))) == runtime
      end
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
          {"worker_id" => "fixture-local",
           "generation_id" => ENV.fetch("LOW_FIXTURE_GENERATION", "fixture-generation-1"),
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
          File.open(#{File.join(@afw, "worker-slot.lock").inspect}, "w") do |slot|
            raise "bootstrap while payload busy" unless slot.flock(File::LOCK_EX | File::LOCK_NB)
          end
          previous = File.file?(@path) ? JSON.parse(File.binread(@path)) : nil
          File.write(@path, JSON.generate("model" => model, "context_length" => context_length))
          if (fifo = ENV["LOW_FIXTURE_ESTABLISHMENT_FIFO"])
            File.write("\#{fifo}.started", Process.pid.to_s)
            File.open(fifo, "r") { |io| io.gets }
          end
          File.open(File.join(File.dirname(@path), "runtime-events.jsonl"), "a") do |io|
            io.flock(File::LOCK_EX)
            io.puts JSON.generate("previous" => previous, "resident" => [model], "context_length" => context_length)
          end
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
      require "stringio"
      stdout = StringIO.new
      status = LocalOllamaWorkers::CLI.run(ARGV, components: components, stdout: stdout)
      if status == 0 && ARGV.first == "workers"
        File.open(File.join(root, "publications.jsonl"), "a") do |io|
          io.flock(File::LOCK_EX)
          io.puts JSON.generate("bytes" => stdout.string)
        end
      end
      print stdout.string
      exit status
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
