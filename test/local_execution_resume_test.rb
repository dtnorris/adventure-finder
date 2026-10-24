# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "rbconfig"
require "timeout"
require "adventure_finder_local_execution"

# Negative launch boundaries use controlled facts; the real public-lock positive
# regression is in LocalIngestExecutionTest, with real WLO processes and controls.
class LocalExecutionResumeTest < Minitest::Test
  Execution = AdventureFinderWorkspace::LocalExecution
  REFUSAL = "ERROR: execution is active; wait for the runner to exit before retrying or resuming\n"
  TOKEN = "a" * 64
  Status = Struct.new(:exitstatus) do
    # Model ordinary exits, preserving the exit-1-only retry guard.
    def success? = exitstatus == 0
  end
  Handle = Struct.new(:output, :status) do
    # Model a reaped child; any attempt to signal this child is a test error.
    def finished? = true
    # Return the exact child status, including unrelated nonzero exits.
    def wait = status
  end

  # Keep ownership facts separate from child output and process status.
  def setup
    @service = Execution.new(front_door_root: Dir.pwd, project_root: Dir.pwd, out: StringIO.new)
    @report = {"status" => "paused", "paused" => true, "executor_active" => false,
      "pause_control" => {"operator_pause" => false, "request_ids" => [Digest::SHA256.hexdigest(TOKEN)]}}
    report = @report
    @service.define_singleton_method(:execution_report) { |*, **| report }
    @state = {"phase" => "resuming", "pause_token" => TOKEN}
  end

  # Exercise the actual finished-child branch and cleanup for an ordinary exit.
  def monitor(output: REFUSAL, exitstatus: 1, manual_resume: false)
    @service.send(:monitor, {}, {}, {}, @state, Handle.new(output, Status.new(exitstatus)), manual_resume:)
  end

  # Only the exact pre-dispatch banner under exact retained ownership is retryable.
  def test_exact_refusal_keeps_owned_resume_distinct_from_operator_pause
    assert_equal :resume_refused, monitor
  end

  # Neither other failures nor extra/truncated diagnostic output grants retry.
  def test_unrelated_nonzero_children_are_gates
    [["ERROR: unrelated\n", 1], [REFUSAL, 2], [REFUSAL + "additional failure\n", 1], [REFUSAL.chomp, 1]].each do |output, status|
      error = assert_raises(Execution::Failure) { monitor(output: output, exitstatus: status) }
      assert_equal "WLO_EXECUTION_GATE", error.code
    end
  end

  # A zero exit retaining the same hold is not completion or launch contention.
  def test_success_without_releasing_hold_is_a_transition_gate
    error = assert_raises(Execution::Failure) { monitor(output: "", exitstatus: 0) }
    assert_equal "LOCAL_TRANSITION_GATE", error.code
  end

  # Manual and independently owned overlapping holds preserve operator authority.
  def test_manual_and_overlapping_holds_are_never_retryable
    [true, false].each do |manual|
      @report["pause_control"]["operator_pause"] = manual
      @report["pause_control"]["request_ids"] << "b" * 64 unless manual
      error = assert_raises(Execution::Failure) { monitor }
      assert_equal "OPERATOR_PAUSE", error.code
    end
  end

  # Missing/wrong authority and the running phase cannot authorize a scoped retry.
  def test_wrong_or_missing_token_and_phase_remain_operator_gates
    [{"phase" => "resuming"}, {"phase" => "resuming", "pause_token" => "c" * 64},
     {"phase" => "running", "pause_token" => TOKEN}].each do |state|
      @state = state
      error = assert_raises(Execution::Failure) { monitor }
      assert_equal "OPERATOR_PAUSE", error.code
    end
  end

  # Terminal execution failures dominate even an exact lock-refusal diagnostic.
  def test_terminal_failures_cannot_retry_or_complete
    Execution::TERMINAL_STATUSES.each do |status|
      @report["status"] = status
      error = assert_raises(Execution::Failure) { monitor }
      assert_equal "WLO_EXECUTION_GATE", error.code
    end
  end

  # A failure during draining must not be accepted as a successful drain.
  def test_unrelated_drain_failure_remains_a_child_failure
    @state["phase"] = "draining"
    error = assert_raises(Execution::Failure) { monitor(output: "ERROR: unrelated\n") }
    assert_equal "WLO_EXECUTION_GATE", error.code
  end

  # The real process adapter streams all binary bytes but bounds its retained
  # prefix. This verifies the observer used by the exact-refusal classifier.
  def test_real_handle_streams_binary_output_and_retains_a_bounded_prefix
    out = StringIO.new
    handle = Execution::CommandRunner.new.spawn({}, RbConfig.ruby, "-e",
      'STDOUT.binmode; STDOUT.write("text\\n" + "\\x00\\xff".b * 4096)', chdir: Dir.pwd, out: out)
    status = Timeout.timeout(10) { handle.wait }
    assert status.success?
    expected = "text\n".b + "\x00\xff".b * 4096
    assert_equal expected, out.string.b
    assert_equal expected.byteslice(0, 4096), handle.output.b
    assert handle.finished?
  end
  # Control only component seams and monotonic time; the drive loop and finished
  # child classifier are real. Repeated refusals share one finite retry budget.
  class RefusedDrive < Execution
    attr_reader :launches, :elapsed

    # Construct a three-poll observation budget without wall-clock sleeps.
    def initialize
      @launches = 0
      @elapsed = 0.0
      @state = {"phase" => "resuming", "pause_token" => TOKEN}
      super(front_door_root: Dir.pwd, project_root: Dir.pwd, out: StringIO.new,
            observation_timeout: 3, poll_interval: 1, sleeper: ->(seconds) { @elapsed += seconds })
    end

    private

    # Keep the test bound to synthetic in-memory facts without filesystem writes.
    def validate_binding!(*); {}; end
    # Simulate uncontested AF coordination; WLO exclusion has a real-lock test.
    def with_coordination_lock(*) = yield
    # No prepared files are needed for this drive-only negative control.
    def prepare_files!(*) = nil
    # Preserve each transition written by the actual drive implementation.
    def load_state(*) = @state
    # Publish a resumable paused execution on every retry.
    def action_check(*) = {"execution_status" => "paused", "disposition" => "execute", "reason" => "resume_paused_execution"}
    # Keep the sole exact owned hold outstanding; no completion may be claimed.
    def execution_report(*)
      {"status" => "paused", "paused" => true, "executor_active" => false,
       "pause_control" => {"operator_pause" => false, "request_ids" => [Digest::SHA256.hexdigest(TOKEN)]}}
    end
    # Prove public quiescence anew before each attempted scoped retry.
    def demands(*)
      {"synthetic" => {"state" => "paused", "bound_count" => 0, "uncertain_count" => 0, "quiescent" => true}}
    end
    # This fixture needs no capability bootstrap to classify launch refusals.
    def pending_step(*) = nil
    # This fixture needs no capability bootstrap to classify launch refusals.
    def step_for_start(*) = nil
    # Store the actual drive's resuming phase without inventing another hold.
    def persist_state(_paths, _intent, state) = @state = state
    # Return the precise refusal only when drive supplies exact scoped authority.
    def spawn_wlo(_paths, command, pause_token:, manual_resume:)
      raise "wrong resume authority" unless command == "resume" && pause_token == TOKEN && !manual_resume
      @launches += 1
      Handle.new(REFUSAL, Status.new(1))
    end
    # Use the deterministic elapsed observation clock.
    def monotonic_now = @elapsed
  end

  # Exact lock refusals cannot reset the deadline and retry indefinitely.
  def test_repeated_refusals_share_one_bounded_budget
    service = RefusedDrive.new
    error = assert_raises(Execution::Failure) do
      service.send(:drive, operation_id: "synthetic", capability_plan: {}, intent: {}, continue_operator_pause: false)
    end
    assert_equal "LOCAL_TRANSITION_GATE", error.code
    assert_equal 3, service.launches
    assert_equal 3.0, service.elapsed
  end

  # A lock refusal never substitutes for the public drained-demand contract.
  def test_refused_resume_requires_fresh_drained_demand_before_retry
    service = RefusedDrive.new
    service.define_singleton_method(:demands) do |*|
      {"synthetic" => {"state" => "paused", "bound_count" => 1, "uncertain_count" => 0, "quiescent" => false}}
    end
    error = assert_raises(Execution::Failure) do
      service.send(:drive, operation_id: "synthetic", capability_plan: {}, intent: {}, continue_operator_pause: false)
    end
    assert_equal "LOCAL_TRANSITION_GATE", error.code
    assert_equal 1, service.launches
  end

  # Explicit manual continuation uses its own existing error path, never the
  # automatic token-scoped retry path.
  def test_manual_resume_launch_refusal_does_not_gain_automatic_retry
    error = assert_raises(Execution::Failure) { monitor(manual_resume: true) }
    assert_equal "WLO_EXECUTION_GATE", error.code
  end

end
