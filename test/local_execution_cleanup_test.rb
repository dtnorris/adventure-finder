# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "stringio"
require "adventure_finder_local_execution"

# Deterministic cleanup races: no real subprocesses or OS signals are needed.
class LocalExecutionCleanupTest < Minitest::Test
  Execution = AdventureFinderWorkspace::LocalExecution

  # Records ownership operations; wait fails immediately if exit is unconfirmed.
  class Handle
    attr_reader :pid, :calls

    # Model either an exited child, successful TERM, or denied TERM with an exit race.
    def initialize(exited: false, denied: false, exit_during_signal: false, wait_error: nil)
      @pid = 43210
      @calls = []
      @exited, @denied, @exit_during_signal, @wait_error = exited, denied, exit_during_signal, wait_error
    end

    # Observe the direct child's simulated status without blocking.
    def finished?
      @calls << :finished
      @exited
    end

    # Record only the owned group; simulate completion or denied delivery.
    def signal(name)
      @calls << [name, -pid]
      @exited = true if @exit_during_signal || !@denied
      raise Errno::EPERM, "simulated group denial" if @denied
    end

    # Account for an exited child; expose any accidental live-child wait.
    def wait
      @calls << :wait
      raise "blocking wait attempted on live child" unless @exited
      raise @wait_error if @wait_error
      :status
    end
  end

  # Exercise monitor's real ensure while controlling only the foreground result.
  class Monitor < Execution
    attr_accessor :application_error

    private

    # Return a normal result or raise the exact supplied application exception.
    def install_forwarding_handlers(_handle)
      raise application_error if application_error
      :completed
    end
  end

  # Construct the coordinator without any component/fixture dependency.
  def setup
    @execution = Monitor.new(front_door_root: Dir.pwd, project_root: Dir.pwd, out: StringIO.new)
    @primary = Execution::Failure.new("WLO_EXECUTION_GATE", "interrupted execution")
    @execution.application_error = @primary
  end

  # Run the cleanup-bearing monitor with the supplied owned handle.
  def monitor(handle)
    @execution.send(:monitor, {}, {}, {}, {}, handle)
  end

  # A disappearing group does not imply successful signaling; confirmed exit allows accounting.
  def test_exit_between_status_and_denied_term_preserves_primary_and_reaps
    handle = Handle.new(denied: true, exit_during_signal: true)
    error = assert_raises(Execution::Failure) { monitor(handle) }
    assert_same @primary, error
    assert_equal "WLO_EXECUTION_GATE", error.code
    assert_equal [:finished, ["TERM", -43210], :finished, :wait], handle.calls
    assert_equal "WLO_CLEANUP_FAILED", error.cleanup_failure.code
    assert_match(/owned PID 43210.*TERM denied.*exit confirmed.*Errno::EPERM/, error.message)
    assert_match(/WLO_EXECUTION_GATE: interrupted execution/, error.message)
    refute_match(/successfully|delivered|terminated/, error.cleanup_failure.message)
  end

  # A live child after denied TERM must remain actionable and must never enter wait.
  def test_denied_term_with_live_child_preserves_primary_without_waiting
    handle = Handle.new(denied: true)
    error = assert_raises(Execution::Failure) { monitor(handle) }
    assert_same @primary, error
    assert_equal [:finished, ["TERM", -43210], :finished], handle.calls
    assert_match(/owned PID 43210.*TERM denied.*exit unconfirmed.*wait skipped.*Errno::EPERM/, error.message)
    assert_match(/operator must check owned child/, error.cleanup_failure.message)
    refute_match(/successfully|delivered|terminated/, error.cleanup_failure.message)
  end

  # A secondary wait error must retain the application exception and its backtrace.
  def test_wait_failure_preserves_original_failure_and_backtrace
    handle = Handle.new(exited: true, wait_error: IOError.new("output read failed"))
    error = assert_raises(Execution::Failure) { monitor(handle) }
    assert_same @primary, error
    assert_match(/install_forwarding_handlers/, error.backtrace.first)
    assert_match(/owned PID 43210; wait: IOError: output read failed/, error.message)
    assert_equal [:finished, :wait], handle.calls
  end

  # Successful TERM still precedes wait and leaves the original message unchanged.
  def test_normal_signal_and_wait
    handle = Handle.new
    error = assert_raises(Execution::Failure) { monitor(handle) }
    assert_same @primary, error
    assert_nil error.cleanup_failure
    assert_equal "WLO_EXECUTION_GATE: interrupted execution", error.message
    assert_equal [:finished, ["TERM", -43210], :wait], handle.calls
  end

  # An already reaped child must never receive another signal.
  def test_already_finished_child_only_waits
    handle = Handle.new(exited: true)
    assert_raises(Execution::Failure) { monitor(handle) }
    assert_equal [:finished, :wait], handle.calls
    assert_nil @primary.cleanup_failure
  end

  # With no application failure, cleanup denial itself must fail the invocation.
  def test_denied_signal_without_primary_failure_is_raised
    @execution.application_error = nil
    handle = Handle.new(denied: true)
    error = assert_raises(Execution::Failure) { monitor(handle) }
    assert_equal "WLO_CLEANUP_FAILED", error.code
    assert_match(/owned PID 43210.*TERM denied.*wait skipped/, error.message)
    assert_equal [:finished, ["TERM", -43210], :finished], handle.calls
  end

  # Successful cleanup must not turn a normal return into an error.
  def test_normal_return_survives_successful_cleanup
    @execution.application_error = nil
    handle = Handle.new
    assert_equal :completed, monitor(handle)
    assert_equal [:finished, ["TERM", -43210], :wait], handle.calls
  end

  # A caller's rescued exception is not a failure of this monitor invocation.
  def test_cleanup_failure_is_not_attached_to_an_unrelated_rescued_error
    @execution.application_error = nil
    begin
      raise @primary
    rescue Execution::Failure
      error = assert_raises(Execution::Failure) { monitor(Handle.new(denied: true)) }
      assert_equal "WLO_CLEANUP_FAILED", error.code
      refute_same @primary, error
      assert_nil @primary.cleanup_failure
    end
  end

  # Non-LocalExecution errors also remain primary, with a separately inspectable cause.
  def test_other_application_error_remains_primary
    original = RuntimeError.new("original application error")
    @execution.application_error = original
    error = assert_raises(RuntimeError) { monitor(Handle.new(denied: true)) }
    assert_same original, error
    assert_equal "original application error", error.message
    assert_equal "WLO_CLEANUP_FAILED", error.cause.code
  end

  # Test the real Handle's exact PID wait/reaping and negative-PID signal contract.
  def test_real_handle_uses_only_owned_pid_and_caches_reaped_status
    reader = StringIO.new
    thread = Struct.new(:value).new(nil)
    handle = Execution::CommandRunner::Handle.new(pid: 43210, reader: reader, thread: thread)
    waits = []
    signals = []
    status = Object.new
    Process.stub(:waitpid2, ->(*args) { waits << args; [43210, status] }) do
      Process.stub(:kill, ->(*args) { signals << args; raise Errno::EPERM }) do
        assert_raises(Errno::EPERM) { handle.signal("TERM") }
        assert handle.finished?
        assert_same status, handle.wait
        assert handle.finished?
        assert_same status, handle.wait
      end
    end
    assert_equal [[43210, Process::WNOHANG]], waits
    assert_equal [["TERM", -43210]], signals
    assert reader.closed?
  end

  # The real WNOHANG recheck independently accounts for exit after denied TERM.
  def test_real_handle_reaps_exit_after_denied_signal
    reader = StringIO.new
    handle = Execution::CommandRunner::Handle.new(
      pid: 43210, reader: reader, thread: Struct.new(:value).new(nil)
    )
    calls = []
    status = Object.new
    Process.stub(:waitpid2, ->(*args) {
      calls << args
      calls.length == 1 ? nil : [43210, status]
    }) do
      Process.stub(:kill, ->(*args) {
        assert_equal ["TERM", -43210], args
        raise Errno::EPERM
      }) do
        error = assert_raises(Execution::Failure) { monitor(handle) }
        assert_same @primary, error
        assert_match(/direct child exit confirmed/, error.cleanup_failure.message)
      end
    end
    assert_equal [[43210, Process::WNOHANG], [43210, Process::WNOHANG]], calls
    assert reader.closed?
  end
end
