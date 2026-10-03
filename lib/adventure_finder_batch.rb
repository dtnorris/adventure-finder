# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "pathname"
require_relative "adventure_finder_workspace"
require_relative "adventure_finder_production_context"

module AdventureFinderWorkspace
  # FO-17 foreground front door. AdventureFinder resolves and verifies the
  # frozen production context; WLO remains the sole execution-state owner.
  class BatchFrontDoor
    PLAN_CONTRACT_VERSION = "wlo-execution-plan/v0.3"
    EXECUTION_CONTRACT_VERSION = "wlo-execution-state/v0.1"
    EXECUTION_ACTIONS = %w[start resume].freeze
    RECOVERY_ACTIONS = %w[retry recovery repair].freeze
    ACTIONS = (EXECUTION_ACTIONS + RECOVERY_ACTIONS).freeze

    class ForegroundExecutor
      def call(environment, argv, chdir:)
        Kernel.exec(environment, *argv, chdir:)
      end
    end

    class ComponentRunner
      Result = Struct.new(:stdout, :stderr, :status, keyword_init: true)

      def capture(environment, argv, chdir:)
        stdout, stderr, status = Open3.capture3(environment, *argv, chdir:)
        Result.new(stdout:, stderr:, status:)
      end
    end

    def initialize(registry_path:, workspace_root:, executor: ForegroundExecutor.new,
                   component_runner: ComponentRunner.new, env_executable: nil,
                   bundle_executable: nil, out: $stdout)
      @registry = ProductionContextRegistry.new(registry_path, workspace_root:)
      @executor = executor
      @component_runner = component_runner
      @env_executable = env_executable
      @bundle_executable = bundle_executable
      @out = out
    end

    def run(action, handle, jobs: [], reason: nil, dry_run: false,
            acknowledge_circuit_breaker: false)
      action = action.to_s
      raise Error, "batch action must be start, resume, retry, recovery, or repair" unless ACTIONS.include?(action)
      if EXECUTION_ACTIONS.include?(action) &&
         (!jobs.empty? || reason || dry_run || acknowledge_circuit_breaker)
        raise Error, "#{action} does not accept recovery jobs or flags"
      end

      context = @registry.resolve("batch", handle)
      plan = verify_frozen_plan!(context)
      fleet = resolve_worker_registry!(context)
      verify_component_paths!(context, fleet)
      retained = retained_execution(context, plan)
      if RECOVERY_ACTIONS.include?(action)
        return run_recovery_action(
          action, handle.to_s, context, plan, fleet, retained,
          jobs:, reason:, dry_run:, acknowledge_circuit_breaker:
        )
      end

      disposition = retained_disposition!(action, handle.to_s, retained)
      return disposition if disposition.is_a?(Integer)

      print_handoff(handle.to_s, context)
      @executor.call(execution_environment(fleet), wlo_argv(action, context, fleet),
                     chdir: context.dig("wlo", "repository_root"))
      0
    end

    private

    def verify_frozen_plan!(context)
      path = context.dig("afw", "plan_path")
      raise Error, "registered frozen plan is missing: #{path}" unless File.file?(path)

      bytes = File.binread(path)
      actual_sha = Digest::SHA256.hexdigest(bytes)
      expected_sha = context.dig("plan", "sha256")
      raise Error, "registered plan SHA-256 mismatch: expected #{expected_sha}, got #{actual_sha}" unless actual_sha == expected_sha

      document = JSON.parse(bytes)
      raise Error, "registered frozen plan must be a JSON object" unless document.is_a?(Hash)
      unless document["plan_id"] == context.dig("plan", "plan_id") &&
             document["plan_id"] == context.fetch("production_batch_id")
        raise Error, "registered frozen plan identity does not match Batch context"
      end
      unless document["contract_version"] == PLAN_CONTRACT_VERSION
        raise Error, "unsupported foreground plan contract #{document['contract_version'].inspect}"
      end

      { "bytes" => bytes, "sha256" => actual_sha, "id" => document.fetch("plan_id"),
        "document" => document }
    rescue JSON::ParserError => e
      raise Error, "registered frozen plan is invalid JSON: #{e.message}"
    end

    def resolve_worker_registry!(context)
      names = context.fetch("associated_fleets")
      raise Error, "Batch has no registered worker-registry fleet" if names.empty?

      fleets = names.map { |name| @registry.resolve("fleet", name) }
      roots = fleets.map { |fleet| fleet.dig("rpof", "repository_root") }.uniq
      state_roots = fleets.map { |fleet| fleet.dig("rpof", "state_root") }.uniq
      unless roots.length == 1 && state_roots.length == 1
        raise Error, "Batch fleets do not share one registered RPOF worker-registry authority"
      end
      fleets.first
    end

    def verify_component_paths!(context, fleet)
      required_directories = {
        "AFW production root" => context.dig("afw", "repository_root"),
        "AFW workload root" => context.dig("afw", "workload_root"),
        "WLO production root" => context.dig("wlo", "repository_root"),
        "RPOF production root" => fleet.dig("rpof", "repository_root")
      }
      required_directories.each do |label, path|
        raise Error, "#{label} is not a directory: #{path}" unless File.directory?(path)
      end
      required_executables = {
        "WLO foreground executable" => File.join(context.dig("wlo", "repository_root"), "bin", "wlo"),
        "RPOF worker-registry executable" => File.join(fleet.dig("rpof", "repository_root"), "bin", "rpof")
      }
      required_executables.each do |label, path|
        raise Error, "#{label} is not executable: #{path}" unless File.executable?(path)
      end
      find_executable!("env", @env_executable)
      find_executable!("bundle", @bundle_executable)
    end

    def retained_execution(context, plan)
      output = context.dig("wlo", "output_root")
      state_path = File.join(output, "execution.json")
      unless File.file?(state_path)
        if File.directory?(output) && !(Dir.children(output) - %w[.execution.lock .state.lock]).empty?
          raise Error, "Batch output exists without retained WLO execution state"
        end
        return nil
      end
      raise Error, "Batch already has an active executor. Next: inspect with bin/af-doctor job" if execution_locked?(output)

      state = read_json(state_path, "retained execution state")
      expected = [EXECUTION_CONTRACT_VERSION, plan.fetch("id"), plan.fetch("sha256"),
                  File.expand_path(context.dig("afw", "repository_root"))]
      actual = [state["contract_version"], state["plan_id"], state["plan_sha256"], state["workdir"]]
      raise Error, "retained execution identity does not match the registered Batch context" unless actual == expected

      retained_plan = File.join(output, "plan.json")
      unless File.file?(retained_plan) && File.binread(retained_plan) == plan.fetch("bytes")
        raise Error, "retained WLO plan is missing or differs from the registered frozen plan"
      end
      jobs = read_json(File.join(output, "jobs.json"), "retained job state").fetch("jobs")
      raise Error, "retained job state must contain a jobs array" unless jobs.is_a?(Array)

      { "state" => state, "jobs" => jobs, "output" => output }
    rescue KeyError => e
      raise Error, "retained execution evidence is incomplete: #{e.message}"
    end

    def retained_disposition!(action, handle, retained)
      if retained.nil?
        raise Error, "Batch #{handle} has no retained execution. Next: bin/af-batch start #{handle}" if action == "resume"
        return nil
      end

      state = retained.fetch("state")
      jobs = retained.fetch("jobs")
      if state.dig("circuit_breaker", "tripped")
        raise Error, "Batch #{handle} circuit breaker is tripped; explicit reviewed recovery is required"
      end
      if state.key?("dispatch_halt")
        raise Error, "Batch #{handle} dispatch is halted; explicit reviewed recovery is required"
      end
      if state["interruption"] || jobs.any? { |job| job["status"] == "interrupted" }
        raise Error, "Batch #{handle} has interrupted work; explicit retry authorization is required"
      end

      status = state.fetch("status").to_s
      case status
      when "completed"
        @out.puts "Batch #{handle} is complete; retained scoring evidence is unchanged."
        return 0
      when "workload_failed"
        raise Error, "Batch #{handle} has failed work; review evidence and use WLO retry-failed explicitly"
      when "interrupted", "circuit_broken", "infrastructure_failed", "cleanup_failed"
        raise Error, "Batch #{handle} requires explicit reviewed recovery (#{status})"
      when "running"
        raise Error, "Batch #{handle} retains running state without an active executor; review before recovery"
      end
      if (status == "paused" || paused?(retained.fetch("output"))) && action == "start"
        raise Error, "Batch #{handle} is paused. Next: bin/af-batch resume #{handle}"
      end
      nil
    end

    def run_recovery_action(action, handle, context, plan, fleet, retained, jobs:, reason:, dry_run:,
                            acknowledge_circuit_breaker:)
      raise Error, "Batch #{handle} has no retained execution; there is nothing to recover" unless retained

      case action
      when "retry"
        raise Error, "retry requires one or more explicit job handles" if jobs.empty?
        raise Error, "retry requires a nonblank --reason" if reason.to_s.strip.empty?
        raise Error, "duplicate job handles" unless jobs.uniq == jobs

        canonical = jobs.map { |job| resolve_job_id!(context, plan, job) }
        raise Error, "selected job handles resolve to duplicate jobs" unless canonical.uniq == canonical
        arguments = canonical.flat_map { |job_id| ["--job", job_id] }
        arguments.concat(["--reason", reason.strip])
        arguments << "--acknowledge-circuit-breaker" if acknowledge_circuit_breaker
        arguments << "--dry-run" if dry_run
        delegate_recovery(context, fleet, "retry-failed", arguments)
      when "recovery"
        raise Error, "recovery does not accept job handles or --reason" unless jobs.empty? && reason.nil?
        raise Error, "recovery does not accept mutation flags" if dry_run || acknowledge_circuit_breaker
        delegate_recovery(context, fleet, "recovery", [])
      when "repair"
        raise Error, "repair does not accept job handles" unless jobs.empty?
        raise Error, "repair requires a nonblank --reason" if reason.to_s.strip.empty?
        raise Error, "repair cannot acknowledge a circuit breaker" if acknowledge_circuit_breaker
        arguments = ["--reason", reason.strip]
        arguments << "--dry-run" if dry_run
        delegate_recovery(context, fleet, "repair", arguments)
      end
    end

    def resolve_job_id!(context, plan, handle)
      root = context.dig("wlo", "repository_root")
      argv = [
        find_executable!("bundle", @bundle_executable), "exec", File.join(root, "bin", "wlo"),
        "doctor", context.dig("afw", "plan_path"), handle.to_s,
        "--output", context.dig("wlo", "output_root"), "--json"
      ]
      result = @component_runner.capture(
        { "BUNDLE_GEMFILE" => File.join(root, "Gemfile") }, argv, chdir: root
      )
      unless result.status.success?
        detail = result.stderr.to_s.strip
        detail = result.stdout.to_s.strip if detail.empty?
        raise Error, "job handle #{handle.inspect} could not be resolved: #{detail}"
      end
      document = JSON.parse(result.stdout)
      id = document.dig("subject", "id")
      job_ids = plan.fetch("document").fetch("jobs").map { |job| job.fetch("job_id") }
      unless job_ids.include?(id)
        raise Error, "job handle #{handle.inspect} resolved outside the frozen Batch plan"
      end

      id
    rescue JSON::ParserError, KeyError => e
      raise Error, "job handle #{handle.inspect} returned invalid WLO diagnostics: #{e.message}"
    end

    def delegate_recovery(context, fleet, command, arguments)
      root = context.dig("wlo", "repository_root")
      argv = [
        find_executable!("bundle", @bundle_executable), "exec", File.join(root, "bin", "wlo"),
        command, context.dig("afw", "plan_path"),
        "--workdir", context.dig("afw", "repository_root"),
        "--output", context.dig("wlo", "output_root"), *arguments
      ]
      @executor.call(execution_environment(fleet), argv, chdir: root)
      0
    end

    def execution_locked?(output)
      path = File.join(output, ".execution.lock")
      return false unless File.file?(path)

      File.open(path, File::RDWR) do |file|
        locked = !file.flock(File::LOCK_EX | File::LOCK_NB)
        file.flock(File::LOCK_UN) unless locked
        locked
      end
    end

    def paused?(output)
      File.file?(File.join(output, "control", "pause"))
    end

    def read_json(path, label)
      value = JSON.parse(File.binread(path))
      raise Error, "#{label} must be a JSON object: #{path}" unless value.is_a?(Hash)

      value
    rescue Errno::ENOENT, JSON::ParserError => e
      raise Error, "invalid #{label} #{path}: #{e.message}"
    end

    def print_handoff(handle, context)
      @out.puts "Batch: #{handle}"
      @out.puts "Plan: #{context.fetch('production_batch_id')}"
      @out.puts "Execution: foreground"
      @out.puts "Output: #{File.basename(context.dig('wlo', 'output_root'))}"
      @out.puts "Ctrl-C: cancel this foreground WLO execution"
      @out.flush if @out.respond_to?(:flush)
    end

    def wlo_argv(action, context, fleet)
      wlo_root = context.dig("wlo", "repository_root")
      rpof_root = fleet.dig("rpof", "repository_root")
      [
        File.join(wlo_root, "bin", "wlo"), action == "start" ? "run" : "resume",
        context.dig("afw", "plan_path"),
        "--workdir", context.dig("afw", "repository_root"),
        "--output", context.dig("wlo", "output_root"),
        "--worker-source-command", find_executable!("env", @env_executable),
        "--worker-source-arg", "BUNDLE_GEMFILE=#{File.join(rpof_root, 'Gemfile')}",
        "--worker-source-arg", find_executable!("bundle", @bundle_executable),
        "--worker-source-arg", "exec",
        "--worker-source-arg", File.join(rpof_root, "bin", "rpof"),
        "--worker-source-arg", "workers",
        "--worker-source-arg=--json"
      ]
    end

    def execution_environment(fleet)
      {
        "RPOF_STATE_ROOT" => fleet.dig("rpof", "state_root"),
        "RPOF_STATE_REPO_ROOT" => fleet.dig("rpof", "repository_root")
      }
    end

    def find_executable!(name, configured)
      return File.expand_path(configured) if configured && File.executable?(configured)

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
        path = File.join(directory, name)
        return path if File.file?(path) && File.executable?(path)
      end
      raise Error, "required executable not found on PATH: #{name}"
    end
  end
end
