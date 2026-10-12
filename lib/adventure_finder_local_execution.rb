# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "securerandom"
require "shellwords"
require "time"
require "yaml"
require_relative "adventure_finder_local_execution_intent"

module AdventureFinderWorkspace
  # Drives one local LOW source and one authoritative WLO execution through the
  # immutable capability sequence bound to a durable ingest operation.
  class LocalExecution
    STATE_VERSION = "adventurefinder-local-execution-state/v0.1"
    SOURCE_VERSION = "wlo-worker-sources/v0.2"
    DEMAND_VERSION = "wlo-consumer-demand/v0.1"
    ACTION_VERSION = "wlo-execution-action-check/v0.1"
    TERMINAL_STATUSES = %w[completed workload_failed interrupted circuit_broken infrastructure_failed cleanup_failed].freeze

    class Failure < Error
      attr_reader :code

      def initialize(code, message)
        @code = code
        super("#{code}: #{message}")
      end
    end

    Result = Struct.new(:stdout, :stderr, :status, keyword_init: true)

    class CommandRunner
      class Handle
        attr_reader :pid

        def initialize(pid:, reader:, thread:)
          @pid = pid
          @reader = reader
          @thread = thread
          @status = nil
        end

        def finished?
          return true if @status
          waited = Process.waitpid2(pid, Process::WNOHANG)
          @status = waited.last if waited
          !@status.nil?
        rescue Errno::ECHILD
          !@status.nil?
        end

        def wait
          _, @status = Process.waitpid2(pid) unless @status
          @thread.value
          @reader.close unless @reader.closed?
          @status
        end

        def signal(name)
          Process.kill(name, -pid)
        rescue Errno::ESRCH
          nil
        end
      end

      def capture(environment, *argv, chdir:)
        stdout, stderr, status = Open3.capture3(environment, *argv, chdir:)
        Result.new(stdout:, stderr:, status:)
      end

      def spawn(environment, *argv, chdir:, out:)
        reader, writer = IO.pipe
        pid = Process.spawn(
          environment, *argv, chdir:, pgroup: true, in: File::NULL,
          out: writer, err: writer
        )
        writer.close
        thread = Thread.new do
          loop do
            out.write(reader.readpartial(4096))
            out.flush
          end
        rescue EOFError
          nil
        end
        Handle.new(pid:, reader:, thread:)
      rescue SystemCallError
        writer&.close unless writer&.closed?
        reader&.close unless reader&.closed?
        raise
      end
    end

    attr_reader :front_door_root, :project_root, :env, :out

    def initialize(front_door_root:, project_root:, env: ENV, out: $stdout,
                   runner: CommandRunner.new, clock: -> { Time.now.utc }, sleeper: ->(seconds) { sleep(seconds) },
                   poll_interval: 1.0, observation_timeout: 30.0)
      @front_door_root = Pathname(front_door_root).expand_path
      @project_root = Pathname(project_root).expand_path
      @env = env
      @out = out
      @runner = runner
      @clock = clock
      @sleeper = sleeper
      @poll_interval = Float(poll_interval)
      @observation_timeout = Float(observation_timeout)
      fail_with("INVALID_LOCAL_EXECUTION_CONFIGURATION", "poll intervals must be positive") unless
        @poll_interval.positive? && @observation_timeout.positive?
    rescue ArgumentError, TypeError
      fail_with("INVALID_LOCAL_EXECUTION_CONFIGURATION", "poll intervals must be positive numbers")
    end

    def start(operation_id:, selected_by:, capability_plan:)
      paths = execution_paths(operation_id)
      intent = intent_store.capture!(
        operation_id:, selected_by:, capability_plan:,
        components: paths.fetch(:components), workdir: paths.fetch(:afw), output: paths.fetch(:output)
      )
      drive(operation_id:, capability_plan:, intent:, continue_operator_pause: false)
    end

    def resume(operation_id:, capability_plan:, continue_operator_pause: false)
      drive(operation_id:, capability_plan:, intent: intent_store.load!(operation_id), continue_operator_pause:)
    end

    def status(operation_id:, capability_plan:)
      intent = intent_store.load!(operation_id)
      paths = validate_binding!(operation_id, capability_plan, intent)
      snapshot = low_snapshot(paths)
      probe = action_check(paths, "run")
      report = if probe.fetch("reason") == "new_execution"
                 nil
               elsif probe.fetch("reason") == "executor_active"
                 execution_report(paths, required: false) ||
                   fail_with("WLO_STATUS_UNAVAILABLE", "active WLO executor has not published readable status")
               elsif probe.fetch("execution_status")
                 execution_report(paths)
               else
                 fail_with("WLO_EXECUTION_GATE", action_message(probe))
               end
      render_status(intent, capability_plan, paths, snapshot, report)
      0
    end

    private

    def drive(operation_id:, capability_plan:, intent:, continue_operator_pause:)
      paths = validate_binding!(operation_id, capability_plan, intent)
      with_coordination_lock(paths) do
        prepare_files!(capability_plan, intent, paths)
        loop do
          probe = action_check(paths, "run")
          report = probe.fetch("execution_status") ? execution_report(paths) : nil
          return finish_complete(intent, capability_plan, paths, report) if report&.fetch("status") == "completed"

          state = load_state(paths, intent)
          if report&.fetch("paused") && !report.fetch("executor_active") && state.fetch("phase") == "draining"
            observed = demands(paths, capability_plan)
            unless drained?(observed)
              fail_with("LOCAL_TRANSITION_GATE", "persisted coordinator drain is not publicly drained")
            end
            state = persist_state(paths, intent, state.merge("phase" => "drained"))
          end
          action = report ? action_check(paths, "resume") : probe
          operator_pause = report&.fetch("paused") && !%w[draining drained resuming].include?(state.fetch("phase"))
          operator_demand = nil
          if operator_pause
            unless continue_operator_pause
              fail_with("OPERATOR_PAUSE", "WLO is operator-paused; continuing requires explicit operator authority")
            end
            operator_demand = demands(paths, capability_plan)
            unless drained?(operator_demand)
              fail_with("OPERATOR_PAUSE", "WLO operator pause is not yet publicly drained and inactive")
            end
          end
          if action.fetch("reason") == "executor_active"
            phase = %w[draining resuming].include?(state.fetch("phase")) ? state.fetch("phase") : "running"
            state = persist_state(paths, intent, state.merge("phase" => phase))
            outcome = monitor(paths, capability_plan, intent, state, nil)
            next if outcome == :drained
            return outcome
          end
          unless action.fetch("disposition") == "execute"
            if action.fetch("disposition") == "already_complete"
              return finish_complete(intent, capability_plan, paths, execution_report(paths))
            end
            fail_with("WLO_EXECUTION_GATE", action_message(action))
          end

          step = step_for_start(capability_plan, state, report)
          step ||= demanded_missing_step(capability_plan, operator_demand, report) if operator_demand
          ensure_ready!(paths, capability_plan, step) if step
          command = report ? "resume" : "run"
          phase = command == "resume" ? "resuming" : "running"
          state = persist_state(paths, intent, state.merge("phase" => phase, "step" => step&.fetch("step")))
          handle = spawn_wlo(paths, command)
          outcome = monitor(paths, capability_plan, intent, state, handle)
          next if outcome == :drained
          return outcome
        end
      end
    rescue LocalExecutionIntentStore::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    end

    def monitor(paths, capability_plan, intent, state, handle)
      unknown_since = nil
      install_forwarding_handlers(handle) do
        loop do
          if handle&.finished?
            process_status = handle.wait
            report = execution_report(paths)
            if report.fetch("status") == "completed" && process_status.success?
              return finish_complete(intent, capability_plan, paths, report)
            end
            if report.fetch("paused") && !report.fetch("executor_active") && state.fetch("phase") == "draining"
              demands = demands(paths, capability_plan)
              unless drained?(demands)
                fail_with("LOCAL_TRANSITION_GATE", "WLO pause returned before public demand proved a drained execution")
              end
              persist_state(paths, intent, state.merge("phase" => "drained"))
              return :drained
            end
            fail_with("WLO_EXECUTION_GATE", "WLO exited #{status_detail(process_status)} with #{report.fetch('status')}")
          end

          report = execution_report(paths, required: false)
          unless report
            unknown_since ||= monotonic_now
            if monotonic_now - unknown_since >= @observation_timeout
              fail_with("WLO_STATUS_UNAVAILABLE", "WLO did not publish retained execution state in time")
            end
            @sleeper.call(@poll_interval)
            next
          end
          if report.fetch("status") == "completed"
            return finish_complete(intent, capability_plan, paths, report) unless handle
            @sleeper.call(@poll_interval)
            next
          end
          if !handle && TERMINAL_STATUSES.include?(report.fetch("status"))
            fail_with("WLO_EXECUTION_GATE", "observed WLO execution ended with #{report.fetch('status')}; review WLO summary")
          end
          if report.fetch("paused") && !report.fetch("executor_active") && state.fetch("phase") == "draining"
            if handle && !handle.finished?
              @sleeper.call(@poll_interval)
              next
            end
            observed = demands(paths, capability_plan)
            unless drained?(observed)
              fail_with("LOCAL_TRANSITION_GATE", "WLO pause is visible but public demand is not safely drained")
            end
            persist_state(paths, intent, state.merge("phase" => "drained"))
            return :drained
          end
          if report.fetch("paused") && state.fetch("phase") == "resuming"
            unknown_since ||= monotonic_now
            if monotonic_now - unknown_since >= @observation_timeout
              fail_with("LOCAL_TRANSITION_GATE", "WLO resume did not clear the coordinator-owned drain")
            end
            @sleeper.call(@poll_interval)
            next
          end
          if report.fetch("paused") && !%w[draining resuming].include?(state.fetch("phase"))
            fail_with("OPERATOR_PAUSE", "WLO was paused outside this coordinator's transition")
          end

          if state.fetch("phase") == "resuming"
            state = persist_state(paths, intent, state.merge("phase" => "running"))
            unknown_since = nil
          end

          observed = demands(paths, capability_plan)
          candidate = demanded_missing_step(capability_plan, observed, report)
          if candidate
            if safe_to_pause?(observed)
              state = persist_state(paths, intent, state.merge("phase" => "draining", "step" => candidate.fetch("step")))
              pause_wlo(paths)
              unknown_since = nil
            elsif observation_unknown?(observed)
              unknown_since ||= monotonic_now
              if monotonic_now - unknown_since >= @observation_timeout
                fail_with("LOCAL_TRANSITION_GATE", "WLO public demand stayed stale or unknown; refusing capability transition")
              end
            else
              unknown_since = nil
            end
          else
            unknown_since = nil
          end
          @sleeper.call(@poll_interval)
        end
      end
    ensure
      if handle
        handle.signal("TERM") unless handle.finished?
        handle.wait
      end
    end

    def demanded_missing_step(capability_plan, observed, report)
      pools = report.fetch("pool_status").to_h { |row| [row.fetch("pool_id"), row] }
      capability_plan.fetch("sequence").each do |step|
        rows = step.fetch("pool_ids").map { |pool| observed.fetch(pool) }
        next unless rows.sum { |row| row.fetch("runnable_count") }.positive?
        accepted_ready = step.fetch("pool_ids").all? do |pool_id|
          pools.fetch(pool_id).dig("workers", "compatible_ready").positive?
        end
        return step unless accepted_ready
      end
      nil
    end

    def step_for_start(capability_plan, state, report)
      if %w[drained resuming].include?(state.fetch("phase"))
        return capability_plan.fetch("sequence").find { |row| row.fetch("step") == state.fetch("step") } ||
          fail_with("STALE_LOCAL_EXECUTION", "stored capability step no longer exists")
      end
      return nil if report

      capability_plan.fetch("sequence").first
    end

    def ensure_ready!(paths, capability_plan, step)
      snapshot = low_snapshot(paths)
      return if ready_for_step?(snapshot, paths, capability_plan, step)

      capability = capability_for(capability_plan, step)
      request_path = request_path(paths, step)
      response = capture(paths.fetch(:low), low_environment(paths), paths.fetch(:low_bin), "bootstrap",
                         "--capability-request", request_path.to_s, "--json")
      fail_with("LOW_BOOTSTRAP_FAILED", command_failure(response)) unless response.status.success?
      parse_json(response.stdout, "LOW bootstrap")
      verified = low_snapshot(paths)
      return if ready_for_step?(verified, paths, capability_plan, step)

      fail_with(
        "LOW_READINESS_FAILED",
        "LOW bootstrap exited successfully but did not publish exact READY capability #{capability.fetch('capability_fingerprint')}"
      )
    end

    def ready_for_step?(snapshot, paths, capability_plan, step)
      load_wlo_contracts!(paths)
      registry = WorkloadOrchestrator::DynamicWorkerRegistry.new(snapshot, now: @clock.call)
      plan = wlo_plan(paths)
      step.fetch("pool_ids").all? do |pool_id|
        pool = plan.pool(pool_id)
        registry.schedulable_workers.any? do |worker|
          WorkloadOrchestrator::CapabilityMatcher.match(
            worker:, required_labels: pool.required_labels,
            ollama_requirement: pool.ollama_requirement
          ).compatible?
        end
      end
    rescue StandardError => e
      raise unless e.class.name == "WorkloadOrchestrator::Error"
      fail_with("LOW_PUBLICATION_INVALID", e.message)
    end

    def demands(paths, capability_plan)
      capability_plan.fetch("sequence").flat_map { |step| step.fetch("pool_ids") }.uniq.to_h do |pool_id|
        response = capture(
          paths.fetch(:wlo), child_environment(paths), paths.fetch(:wlo_bin), "consumer-demand",
          paths.fetch(:plan).to_s, "--workdir", paths.fetch(:afw).to_s,
          "--output", paths.fetch(:output).to_s, "--pool", pool_id
        )
        fail_with("WLO_DEMAND_UNAVAILABLE", command_failure(response)) unless response.status.success?
        document = parse_json(response.stdout, "WLO consumer demand")
        valid = document.is_a?(Hash) && document["contract_version"] == DEMAND_VERSION &&
                document["consumer_id"] == paths.fetch(:consumer_id) &&
                document["plan_sha256"] == paths.fetch(:plan_sha256) && document["pool_id"] == pool_id
        fail_with("STALE_LOCAL_EXECUTION", "WLO consumer-demand identity changed") unless valid
        [pool_id, document]
      end
    end

    def safe_to_pause?(observed)
      rows = observed.values
      rows.all? do |row|
        row.fetch("fresh") == true && row.fetch("state") == "active" &&
          row.fetch("bound_count") == 0 && row.fetch("uncertain_count") == 0 && row.fetch("quiescent") == true
      end
    end

    def observation_unknown?(observed)
      observed.values.any? { |row| row.fetch("fresh") != true || !%w[active paused completed].include?(row.fetch("state")) }
    end

    def drained?(observed)
      observed.values.all? do |row|
        row.fetch("state") == "paused" && row.fetch("bound_count") == 0 &&
          row.fetch("uncertain_count") == 0 && row.fetch("quiescent") == true
      end
    end

    def action_check(paths, action)
      response = capture(
        paths.fetch(:wlo), child_environment(paths), paths.fetch(:wlo_bin), "action-check",
        paths.fetch(:plan).to_s, "--workdir", paths.fetch(:afw).to_s,
        "--output", paths.fetch(:output).to_s, "--action", action, "--json"
      )
      fail_with("WLO_ACTION_CHECK_FAILED", command_failure(response)) unless response.status.success?
      document = parse_json(response.stdout, "WLO action-check")
      valid = document.is_a?(Hash) && document["contract_version"] == ACTION_VERSION && document["action"] == action &&
              %w[execute blocked already_complete].include?(document["disposition"]) &&
              document["reason"].is_a?(String) && document.key?("execution_status")
      fail_with("INVALID_COMPONENT_OUTPUT", "WLO action-check returned an incompatible contract") unless valid
      document
    end

    def execution_report(paths, required: true)
      response = capture(
        paths.fetch(:wlo), child_environment(paths), paths.fetch(:wlo_bin), "status",
        paths.fetch(:plan).to_s, "--output", paths.fetch(:output).to_s, "--json"
      )
      unless response.status.success?
        return nil unless required
        fail_with("WLO_STATUS_UNAVAILABLE", command_failure(response))
      end
      document = parse_json(response.stdout, "WLO status")
      valid = document.is_a?(Hash) && document["plan_id"] == paths.fetch(:plan_id) &&
              document["plan_sha256"] == paths.fetch(:plan_sha256)
      fail_with("STALE_LOCAL_EXECUTION", "WLO status plan identity changed") unless valid
      document
    end

    def pause_wlo(paths)
      response = capture(paths.fetch(:wlo), child_environment(paths), paths.fetch(:wlo_bin),
                         "pause", "--output", paths.fetch(:output).to_s)
      fail_with("WLO_PAUSE_FAILED", command_failure(response)) unless response.status.success?
    end

    def spawn_wlo(paths, command)
      @runner.spawn(
        child_environment(paths), paths.fetch(:wlo_bin).to_s, command, paths.fetch(:plan).to_s,
        "--workdir", paths.fetch(:afw).to_s, "--output", paths.fetch(:output).to_s,
        "--worker-sources-config", paths.fetch(:worker_sources).to_s,
        chdir: paths.fetch(:wlo).to_s, out:
      )
    rescue SystemCallError => e
      fail_with("WLO_LAUNCH_FAILED", e.message)
    end

    def low_snapshot(paths)
      response = capture(paths.fetch(:low), low_environment(paths), paths.fetch(:low_bin), "workers", "--json")
      fail_with("LOW_PUBLICATION_FAILED", command_failure(response)) unless response.status.success?
      document = parse_json(response.stdout, "LOW worker publication")
      fail_with("LOW_PUBLICATION_INVALID", "LOW worker publication must contain workers") unless
        document.is_a?(Hash) && document["workers"].is_a?(Array)
      response.stdout
    end

    def prepare_files!(capability_plan, intent, paths)
      FileUtils.mkdir_p(paths.fetch(:coordination))
      capability_plan.fetch("sequence").each do |step|
        capability = capability_for(capability_plan, step)
        bytes = JSON.generate(capability.fetch("capability_request"))
        expected = capability.fetch("capability_artifact_sha256")
        fail_with("STALE_LOCAL_EXECUTION", "capability request digest changed") unless Digest::SHA256.hexdigest(bytes) == expected
        write_or_verify(request_path(paths, step), bytes)
      end
      source = {
        "contract_version" => SOURCE_VERSION,
        "sources" => [{
          "name" => "local", "command" => paths.fetch(:low_bin).to_s,
          "args" => ["workers", "--json"], "environment" => low_environment(paths),
          "workdir" => paths.fetch(:low).to_s, "policy" => "required"
        }]
      }
      write_or_verify(paths.fetch(:worker_sources), YAML.dump(source))
      load_state(paths, intent)
    end

    def validate_binding!(operation_id, capability_plan, intent)
      paths = execution_paths(operation_id)
      workload = capability_plan.fetch("workload")
      sequence_digest = LocalExecutionIntentStore.digest(
        "capabilities" => capability_plan.fetch("capabilities"), "sequence" => capability_plan.fetch("sequence")
      )
      valid = intent["operation_id"] == operation_id &&
              intent.dig("workload", "workload_id") == workload.fetch("workload_id") &&
              intent.dig("workload", "plan_id") == workload.fetch("plan_id") &&
              intent.dig("workload", "plan_sha256") == workload.fetch("plan_sha256") &&
              intent.dig("workload", "capability_sequence_sha256") == sequence_digest &&
              intent.fetch("components") == paths.fetch(:components) &&
              intent.dig("execution", "workdir") == paths.fetch(:afw).to_s &&
              intent.dig("execution", "output") == paths.fetch(:output).to_s &&
              intent.dig("execution", "consumer_id") == paths.fetch(:consumer_id)
      fail_with("STALE_LOCAL_EXECUTION", "operation, plan, sequence, component roots or execution locator changed") unless valid
      required_executable(paths.fetch(:low_bin), "LOW")
      required_executable(paths.fetch(:wlo_bin), "WLO")
      paths
    end

    def execution_paths(operation_id)
      afw = Pathname(env.fetch("AF_AFW_ROOT", project_root.join("af-workloads").to_s)).expand_path
      low = Pathname(env.fetch("LOW_REPO_ROOT", project_root.join("local-ollama-workers").to_s)).expand_path
      wlo = Pathname(env.fetch("WLO_REPO_ROOT", project_root.join("workload-orchestrator").to_s)).expand_path
      coordination = intent_store.operation_dir(operation_id)
      output = coordination.join("wlo")
      preparation = read_json(
        front_door_root.join("output", "staged-workload-preparations", "v0.1", operation_id, "result.json"),
        "staged workload preparation"
      )
      plan = Pathname(preparation.dig("plan", "path").to_s).expand_path
      plan_sha = Digest::SHA256.file(plan).hexdigest
      fail_with("STALE_LOCAL_EXECUTION", "prepared plan bytes changed") unless plan_sha == preparation.dig("plan", "sha256")
      consumer = Digest::SHA256.hexdigest(JSON.generate([plan_sha, afw.to_s, output.to_s]))
      {
        afw:, low:, wlo:, coordination:, output:, plan:, plan_sha256: plan_sha,
        plan_id: preparation.fetch("workload_id"), consumer_id: consumer,
        worker_sources: coordination.join("worker-sources.yml"),
        state: coordination.join("state.json"), lock: coordination.join(".coordination.lock"),
        low_state: Pathname(env.fetch("LOW_STATE_ROOT", Pathname(Dir.home).join(".local/state/local-ollama-workers").to_s)).expand_path,
        low_bin: low.join("bin", "low"), wlo_bin: wlo.join("bin", "wlo"),
        components: {"afw" => afw.to_s, "low" => low.to_s, "wlo" => wlo.to_s}
      }
    rescue Errno::ENOENT => e
      fail_with("MISSING_LOCAL_EXECUTION_INPUT", e.message)
    end

    def load_state(paths, intent)
      return initial_state(intent) unless paths.fetch(:state).file?
      document = parse_json(File.binread(paths.fetch(:state)), "local execution state")
      valid = document["contract_version"] == STATE_VERSION && document["intent_id"] == intent.fetch("intent_id") &&
              %w[authorized running draining drained resuming completed].include?(document["phase"])
      fail_with("CORRUPT_LOCAL_EXECUTION_STATE", "stored coordinator state is incompatible") unless valid
      document
    end

    def initial_state(intent)
      {"contract_version" => STATE_VERSION, "intent_id" => intent.fetch("intent_id"),
       "phase" => "authorized", "step" => nil, "updated_at" => timestamp}
    end

    def persist_state(paths, intent, state)
      document = initial_state(intent).merge(state.slice("phase", "step"), "updated_at" => timestamp)
      write_atomic(paths.fetch(:state), JSON.pretty_generate(document) + "\n")
      document
    end

    def with_coordination_lock(paths)
      FileUtils.mkdir_p(paths.fetch(:coordination))
      File.open(paths.fetch(:lock), File::RDWR | File::CREAT, 0o600) do |lock|
        fail_with("LOCAL_EXECUTION_ACTIVE", "another coordinator owns this operation") unless
          lock.flock(File::LOCK_EX | File::LOCK_NB)
        yield
      end
    end

    def render_status(intent, capability_plan, paths, snapshot, report)
      document = parse_json(snapshot, "LOW worker publication")
      out.puts "Local ingest execution"
      out.puts "Operation: #{intent.fetch('operation_id')}"
      out.puts "Workload: #{intent.dig('workload', 'workload_id')}"
      out.puts "Execution: #{report ? report.fetch('status') : 'not_started'}"
      out.puts "Executor: #{report&.fetch('executor_active', false) ? 'active' : 'inactive'}"
      out.puts "Selected/deferred: #{preparation_summary(intent.fetch('operation_id'))}"
      out.puts "LOW workers: #{document.fetch('workers').length} published"
      capability_plan.fetch("sequence").each do |step|
        ready = ready_for_step?(snapshot, paths, capability_plan, step)
        out.puts "Capability #{step.fetch('step')}: #{ready ? 'READY' : 'NOT_READY'} pools=#{step.fetch('pool_ids').join(',')}"
      end
      render_next_actions(intent, paths, report)
    end

    def finish_complete(intent, capability_plan, paths, report)
      state = load_state(paths, intent)
      persist_state(paths, intent, state.merge("phase" => "completed", "step" => nil))
      out.puts "WLO execution is terminal: completed"
      out.puts "Selected/deferred: #{preparation_summary(intent.fetch('operation_id'))}"
      out.puts "Execution identity: #{paths.fetch(:consumer_id)}"
      render_next_actions(intent, paths, report)
      0
    end

    def render_next_actions(intent, paths, report)
      workload = intent.dig("workload", "workload_id")
      if report&.fetch("status") == "completed"
        bind = [paths.fetch(:afw).join("bin/afw-bind-scoring-evidence"), workload, paths.fetch(:output)]
        publish = [paths.fetch(:afw).join("bin/afw-workload-evidence"), "publish", workload, paths.fetch(:output)]
        out.puts "Next: #{Shellwords.join(bind.map(&:to_s))}"
        out.puts "Then: #{Shellwords.join(publish.map(&:to_s))}"
        out.puts "After evidence_complete=true: bin/af-catalog resume #{intent.fetch('operation_id')}"
      elsif report&.fetch("executor_active")
        out.puts "Observe: bin/af-catalog local-status #{intent.fetch('operation_id')}"
      elsif report && TERMINAL_STATUSES.include?(report.fetch("status"))
        summary = [paths.fetch(:wlo_bin), "summary", paths.fetch(:plan), "--output", paths.fetch(:output)]
        out.puts "Inspect: #{Shellwords.join(summary.map(&:to_s))}"
        out.puts "Recovery gate: use WLO's explicit doctor/retry-failed controls after review; local-resume grants no retry or breaker acknowledgement."
      elsif report&.fetch("paused")
        out.puts "Operator pause: bin/af-catalog local-resume #{intent.fetch('operation_id')} --continue-operator-pause"
      else
        out.puts "Resume: bin/af-catalog local-resume #{intent.fetch('operation_id')}"
      end
    end

    def preparation_summary(operation_id)
      document = read_json(
        front_door_root.join("output", "staged-workload-preparations", "v0.1", operation_id, "result.json"),
        "staged workload preparation"
      )
      "selected=#{document.fetch('selected').length} deferred=#{document.fetch('deferred').length} " \
        "refused=#{document.fetch('refused', []).length} cases=#{document.fetch('qualified_cases')}"
    end

    def install_forwarding_handlers(handle)
      return yield unless handle && Thread.current == Thread.main
      previous = {}
      %w[INT TERM].each do |signal|
        previous[signal] = Signal.trap(signal) { handle.signal(signal) }
      end
      yield
    ensure
      previous&.each { |signal, handler| Signal.trap(signal, handler) }
    end

    def capability_for(capability_plan, step)
      capability_plan.fetch("capabilities").find do |row|
        row.fetch("capability_fingerprint") == step.fetch("capability_fingerprint")
      end || fail_with("STALE_LOCAL_EXECUTION", "capability sequence references a missing request")
    end

    def request_path(paths, step)
      paths.fetch(:coordination).join(format("capability-%03d.json", step.fetch("step")))
    end

    def wlo_plan(paths)
      load_wlo_contracts!(paths)
      @wlo_plan ||= WorkloadOrchestrator::Plan.load(paths.fetch(:plan).to_s)
    end

    def load_wlo_contracts!(paths)
      return if defined?(WorkloadOrchestrator::DynamicWorkerRegistry)
      require paths.fetch(:wlo).join("lib", "workload_orchestrator").to_s
    rescue LoadError => e
      fail_with("COMPONENT_UNAVAILABLE", e.message)
    end

    def low_environment(paths)
      {"LOW_STATE_ROOT" => paths.fetch(:low_state).to_s}
    end

    def child_environment(paths)
      {"AF_PROJECT_ROOT" => project_root.to_s, "AF_ADVENTURE_FINDER_ROOT" => front_door_root.to_s,
       "AFW_ROOT" => paths.fetch(:afw).to_s}
    end

    def capture(chdir, environment, *argv)
      @runner.capture(environment, *argv.map(&:to_s), chdir: chdir.to_s)
    rescue SystemCallError => e
      fail_with("COMPONENT_COMMAND_FAILED", e.message)
    end

    def write_or_verify(path, bytes)
      return if path.file? && File.binread(path) == bytes
      fail_with("LOCAL_EXECUTION_CONFLICT", "bound coordination artifact changed: #{path}") if path.exist?
      write_atomic(path, bytes)
    end

    def write_atomic(path, bytes)
      FileUtils.mkdir_p(path.dirname)
      temporary = path.dirname.join(".#{path.basename}.tmp-#{Process.pid}-#{SecureRandom.hex(6)}")
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes); file.flush; file.fsync }
      File.rename(temporary, path)
    ensure
      File.delete(temporary) if temporary&.file?
    end

    def required_executable(path, label)
      fail_with("COMPONENT_UNAVAILABLE", "#{label} public executable is unavailable: #{path}") unless path.file? && path.executable?
    end

    def read_json(path, label)
      JSON.parse(File.binread(path))
    rescue Errno::ENOENT, JSON::ParserError => e
      fail_with("MISSING_LOCAL_EXECUTION_INPUT", "#{label}: #{e.message}")
    end

    def parse_json(bytes, label)
      JSON.parse(bytes)
    rescue JSON::ParserError => e
      fail_with("INVALID_COMPONENT_OUTPUT", "#{label}: #{e.message}")
    end

    def action_message(action)
      [action.fetch("reason"), action["message"]].compact.join(": ")
    end

    def command_failure(response)
      detail = response.stderr.to_s.strip
      detail = response.stdout.to_s.strip if detail.empty?
      "exit #{response.status.exitstatus}: #{detail}"
    end

    def status_detail(status)
      status.exitstatus ? "with exit #{status.exitstatus}" : "from signal #{status.termsig}"
    end

    def timestamp
      @clock.call.utc.iso8601(0)
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def intent_store
      @intent_store ||= LocalExecutionIntentStore.new(
        root: LocalExecutionIntentStore.default_root(front_door_root: front_door_root), clock: @clock
      )
    end

    def fail_with(code, message)
      raise Failure.new(code, message)
    end
  end
end
