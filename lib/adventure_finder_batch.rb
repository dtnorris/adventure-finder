# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "yaml"
require_relative "adventure_finder_workspace"
require_relative "adventure_finder_production_context"
require_relative "adventure_finder_job_handle_resolver"

module AdventureFinderWorkspace
  # FO-17 foreground front door. AdventureFinder resolves and verifies the
  # frozen production context; WLO remains the sole execution-state owner.
  class BatchFrontDoor
    PLAN_CONTRACT_VERSION = "wlo-execution-plan/v0.3"
    ACTION_CHECK_CONTRACT_VERSION = "wlo-execution-action-check/v0.1"
    EXECUTION_ACTIONS = %w[start resume].freeze
    RECOVERY_ACTIONS = %w[retry recovery repair].freeze
    ACTIONS = (EXECUTION_ACTIONS + RECOVERY_ACTIONS).freeze
    WORKER_SOURCES_CONTRACT_VERSION = "wlo-worker-sources/v0.2"

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
      sources = selected_worker_sources(context)
      fleet = sources.include?("remote") ? resolve_remote_registry!(context) : nil
      verify_component_paths!(context, fleet, sources)
      disposition = execution_action_disposition(action, context)
      if disposition.fetch("disposition") == "blocked"
        raise Error, blocked_action_message(action, handle.to_s, disposition)
      end
      if disposition.fetch("disposition") == "already_complete"
        @out.puts "Batch #{handle} is complete; retained scoring evidence is unchanged."
        return 0
      end
      if RECOVERY_ACTIONS.include?(action)
        return run_recovery_action(
          action, context, plan,
          jobs:, reason:, dry_run:, acknowledge_circuit_breaker:
        )
      end

      print_handoff(handle.to_s, context)
      source_config = write_worker_sources_config!(context, fleet, sources)
      @executor.call({}, wlo_argv(action, context, source_config),
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

    def selected_worker_sources(context)
      sources = if context.key?("worker_sources")
                  context.fetch("worker_sources")
                else
                  [].tap do |fallback|
                    fallback << "local" if context.key?("local_workers")
                    fallback << "remote" unless context.fetch("associated_fleets").empty?
                  end
                end
      raise Error, "Batch has no configured worker sources" if sources.empty?

      sources
    end

    def resolve_remote_registry!(context)
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

    def verify_component_paths!(context, fleet, sources)
      required_directories = {
        "AFW production root" => context.dig("afw", "repository_root"),
        "AFW workload root" => context.dig("afw", "workload_root"),
        "WLO production root" => context.dig("wlo", "repository_root")
      }
      if sources.include?("local")
        required_directories["LOW production root"] = context.dig("local_workers", "repository_root")
      end
      if sources.include?("remote")
        required_directories["RPOF production root"] = fleet.dig("rpof", "repository_root")
      end
      required_directories.each do |label, path|
        raise Error, "#{label} is not a directory: #{path}" unless File.directory?(path)
      end
      required_executables = {
        "WLO foreground executable" => File.join(context.dig("wlo", "repository_root"), "bin", "wlo")
      }
      if sources.include?("local")
        required_executables["LOW worker-registry executable"] =
          File.join(context.dig("local_workers", "repository_root"), "bin", "low")
      end
      if sources.include?("remote")
        required_executables["RPOF worker-registry executable"] =
          File.join(fleet.dig("rpof", "repository_root"), "bin", "rpof")
      end
      required_executables.each do |label, path|
        raise Error, "#{label} is not executable: #{path}" unless File.executable?(path)
      end
      sources.each do |source|
        root = if source == "local"
                 context.dig("local_workers", "repository_root")
               else
                 fleet.dig("rpof", "repository_root")
               end
        gemfile = File.join(root, "Gemfile")
        raise Error, "#{source} worker-source Gemfile is not a file: #{gemfile}" unless File.file?(gemfile)
      end
      find_executable!("bundle", @bundle_executable)
    end

    def execution_action_disposition(action, context)
      root = context.dig("wlo", "repository_root")
      wlo_action = { "start" => "run", "resume" => "resume", "retry" => "retry-failed",
                     "recovery" => "recovery", "repair" => "repair" }.fetch(action)
      argv = [
        find_executable!("bundle", @bundle_executable), "exec", File.join(root, "bin", "wlo"),
        "action-check", context.dig("afw", "plan_path"),
        "--workdir", context.dig("afw", "repository_root"),
        "--output", context.dig("wlo", "output_root"), "--action", wlo_action, "--json"
      ]
      result = @component_runner.capture(
        { "BUNDLE_GEMFILE" => File.join(root, "Gemfile"), "BUNDLE_LOCKFILE" => nil }, argv, chdir: root
      )
      unless result.status.success?
        detail = result.stderr.to_s.strip
        detail = result.stdout.to_s.strip if detail.empty?
        raise Error, "WLO action check failed: #{detail}"
      end

      document = JSON.parse(result.stdout)
      unless document["contract_version"] == ACTION_CHECK_CONTRACT_VERSION &&
             document["action"] == wlo_action &&
             %w[execute already_complete blocked].include?(document["disposition"]) &&
             document["reason"].is_a?(String) && !document["reason"].empty?
        raise Error, "WLO action check returned an invalid result"
      end
      if document["disposition"] == "blocked" && document["message"].to_s.strip.empty?
        raise Error, "WLO action check returned a blocked result without detail"
      end

      document
    rescue JSON::ParserError, KeyError => e
      raise Error, "WLO action check returned invalid JSON: #{e.message}"
    end

    def blocked_action_message(action, handle, disposition)
      reason = disposition.fetch("reason")
      if reason == "no_retained_execution" && action == "resume"
        return "Batch #{handle} has no retained execution. Next: bin/af-batch start #{handle}"
      end
      if reason == "paused" && action == "start"
        return "Batch #{handle} is paused. Next: bin/af-batch resume #{handle}"
      end
      if reason == "executor_active"
        return "Batch #{handle} already has an active executor. Next: inspect with bin/af-doctor job"
      end

      "Batch #{handle} #{disposition.fetch('message')}"
    end

    def run_recovery_action(action, context, plan, jobs:, reason:, dry_run:,
                            acknowledge_circuit_breaker:)
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
        delegate_recovery(context, "retry-failed", arguments)
      when "recovery"
        raise Error, "recovery does not accept job handles or --reason" unless jobs.empty? && reason.nil?
        raise Error, "recovery does not accept mutation flags" if dry_run || acknowledge_circuit_breaker
        delegate_recovery(context, "recovery", [])
      when "repair"
        raise Error, "repair does not accept job handles" unless jobs.empty?
        raise Error, "repair requires a nonblank --reason" if reason.to_s.strip.empty?
        raise Error, "repair cannot acknowledge a circuit breaker" if acknowledge_circuit_breaker
        arguments = ["--reason", reason.strip]
        arguments << "--dry-run" if dry_run
        delegate_recovery(context, "repair", arguments)
      end
    end

    def resolve_job_id!(context, plan, handle)
      root = context.dig("wlo", "repository_root")
      id = JobHandleResolver.new(plan.fetch("document")).resolve(handle)
      argv = [
        find_executable!("bundle", @bundle_executable), "exec", File.join(root, "bin", "wlo"),
        "doctor", context.dig("afw", "plan_path"), id,
        "--output", context.dig("wlo", "output_root"), "--json"
      ]
      result = @component_runner.capture(
        { "BUNDLE_GEMFILE" => File.join(root, "Gemfile"), "BUNDLE_LOCKFILE" => nil }, argv, chdir: root
      )
      unless result.status.success?
        detail = result.stderr.to_s.strip
        detail = result.stdout.to_s.strip if detail.empty?
        raise Error, "job handle #{handle.inspect} could not be resolved: #{detail}"
      end
      document = JSON.parse(result.stdout)
      diagnosed_id = document.dig("subject", "id")
      unless diagnosed_id == id
        raise Error, "job handle #{handle.inspect} resolved to inconsistent WLO diagnostics"
      end
      job_ids = plan.fetch("document").fetch("jobs").map { |job| job.fetch("job_id") }
      unless job_ids.include?(id)
        raise Error, "job handle #{handle.inspect} resolved outside the frozen Batch plan"
      end

      id
    rescue JSON::ParserError, KeyError => e
      raise Error, "job handle #{handle.inspect} returned invalid WLO diagnostics: #{e.message}"
    end

    def delegate_recovery(context, command, arguments)
      root = context.dig("wlo", "repository_root")
      argv = [
        find_executable!("bundle", @bundle_executable), "exec", File.join(root, "bin", "wlo"),
        command, context.dig("afw", "plan_path"),
        "--workdir", context.dig("afw", "repository_root"),
        "--output", context.dig("wlo", "output_root"), *arguments
      ]
      @executor.call({}, argv, chdir: root)
      0
    end

    def print_handoff(handle, context)
      @out.puts "Batch: #{handle}"
      @out.puts "Plan: #{context.fetch('production_batch_id')}"
      @out.puts "Execution: foreground"
      @out.puts "Output: #{File.basename(context.dig('wlo', 'output_root'))}"
      @out.puts "Ctrl-C: cancel this foreground WLO execution"
      @out.flush if @out.respond_to?(:flush)
    end

    def wlo_argv(action, context, source_config)
      wlo_root = context.dig("wlo", "repository_root")
      [
        File.join(wlo_root, "bin", "wlo"), action == "start" ? "run" : "resume",
        context.dig("afw", "plan_path"),
        "--workdir", context.dig("afw", "repository_root"),
        "--output", context.dig("wlo", "output_root"),
        "--worker-sources-config", source_config
      ]
    end

    # Persist v0.2 source YAML for WLO, defaulting selected sources to optional
    # only when the validated context has no explicit policy mapping.
    # Returns its content-addressed path; invalid paths/content raise Error.
    def write_worker_sources_config!(context, fleet, sources)
      bundle = find_executable!("bundle", @bundle_executable)
      entries = sources.map { |source| worker_source_entry(source, context, fleet, bundle) }
      policies = context.fetch("worker_source_policies") do
        sources.to_h { |source| [source, "optional"] }
      end
      entries.each { |entry| entry["policy"] = policies.fetch(entry.fetch("name")) }
      bytes = YAML.dump("contract_version" => WORKER_SOURCES_CONTRACT_VERSION, "sources" => entries)
      root = File.join(File.dirname(context.dig("wlo", "output_root")), "worker-sources")
      basename = File.basename(context.dig("wlo", "output_root"))
      path = File.join(root, "#{basename}-#{Digest::SHA256.hexdigest(bytes)[0, 12]}.yml")
      FileUtils.mkdir_p(root)
      if File.file?(path)
        raise Error, "worker-source configuration content mismatch: #{path}" unless File.binread(path) == bytes
        return path
      end

      temporary = "#{path}.tmp-#{Process.pid}"
      File.open(temporary, "wb", 0o600) do |file|
        file.write(bytes)
        file.flush
        file.fsync
      end
      File.rename(temporary, path)
      path
    ensure
      FileUtils.rm_f(temporary) if temporary && File.exist?(temporary)
    end

    # Build one observational publisher invocation from validated context paths.
    # WLO accepts string environments; env -u preserves lockfile removal before
    # component Bundler starts, including a contaminated inherited lockfile.
    # Returns a publisher row before policy is attached; missing env raises Error.
    def worker_source_entry(source, context, fleet, bundle)
      root, executable, environment =
        if source == "local"
          local_root = context.dig("local_workers", "repository_root")
          [local_root, "low", { "BUNDLE_GEMFILE" => File.join(local_root, "Gemfile") }]
        else
          remote_root = fleet.dig("rpof", "repository_root")
          [remote_root, "rpof", {
            "BUNDLE_GEMFILE" => File.join(remote_root, "Gemfile"),
            "RPOF_STATE_ROOT" => fleet.dig("rpof", "state_root"),
            "RPOF_STATE_REPO_ROOT" => remote_root
          }]
        end
      {
        "name" => source,
        "command" => find_executable!("env", @env_executable),
        "args" => ["-u", "BUNDLE_LOCKFILE", bundle, "exec", File.join(root, "bin", executable), "workers", "--json"],
        "environment" => environment,
        "workdir" => root
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
