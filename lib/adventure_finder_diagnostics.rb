# frozen_string_literal: true

require "json"
require "open3"
require_relative "adventure_finder_workspace"
require_relative "adventure_finder_production_context"
require_relative "adventure_finder_job_handle_resolver"

module AdventureFinderWorkspace
  # FO-07 workspace front door. Classification remains in WLO/RPOF; this class
  # resolves FO-01 production contexts, delegates, and translates safe action
  # identifiers into short workspace commands when the mapping is exact.
  class Diagnostics
    SUBJECT_TYPES = %w[job pod fleet campaign].freeze

    class ComponentRunner
      Result = Struct.new(:stdout, :stderr, :status, keyword_init: true)

      def capture(argv, chdir:, env: {})
        stdout, stderr, status = Open3.capture3(env, *argv, chdir:)
        Result.new(stdout:, stderr:, status:)
      end
    end

    def initialize(registry_path:, workspace_root:, runner: ComponentRunner.new, out: $stdout)
      @registry = ProductionContextRegistry.new(registry_path, workspace_root:)
      @runner = runner
      @out = out
    end

    def call(type, arguments, logs: false, lines: nil)
      case type.to_s
      when "job" then job(arguments, logs:, lines:)
      when "pod" then pod(arguments, logs:, lines:)
      when "fleet" then fleet(arguments, logs:)
      when "campaign" then campaign(arguments, logs:)
      else raise Error, "diagnostic subject must be job, pod, fleet, or campaign"
      end
    end

    def render(result, logs: false)
      return render_logs(result) if logs

      subject = result.fetch("subject")
      label = subject.fetch("type").capitalize
      name = subject["handle"] || subject["id"]
      @out.puts compact("#{label}: #{name}")
      @out.puts compact("Stage: #{result.fetch('stage').tr('_', ' ')}")
      @out.puts compact("State: #{result.fetch('status')}")
      @out.puts compact("Problem: #{result.fetch('summary')}")
      evidence = result.fetch("evidence").first
      @out.puts compact("Evidence: #{evidence_label(evidence)}") if evidence
      action = result["next_action"]
      @out.puts compact("Next: #{action ? action['command'] || action.fetch('action').tr('_', ' ') : 'none'}")
    end

    private

    def job(arguments, logs:, lines:)
      batch, handle = exact_arguments!(arguments, 2, "job BATCH JOB")
      context = @registry.resolve("batch", batch)
      root = context.dig("wlo", "repository_root")
      canonical_id = JobHandleResolver.load(context.dig("afw", "plan_path")).resolve(handle)
      command = ["bundle", "exec", "bin/wlo", logs ? "logs" : "doctor",
                 context.dig("afw", "plan_path"), canonical_id,
                 "--output", context.dig("wlo", "output_root"), "--json"]
      command.concat(["--lines", Integer(lines).to_s]) if logs && lines
      result = run_component(command, root)
      result.fetch("subject")["handle"] = handle
      translate_job_action!(result, batch, context) unless logs
      result
    rescue ArgumentError, TypeError
      raise Error, "--lines must be an integer"
    end

    def pod(arguments, logs:, lines:)
      handle, = exact_arguments!(arguments, 1, "pod POD")
      fleet_name = handle[/\A([A-Z]+)\d+\z/, 1]
      raise Error, "pod handle must use the current deterministic alias (for example A2)" unless fleet_name

      invoke_rpof("pod", handle, fleet_name, logs:, lines:)
    end

    def fleet(arguments, logs:)
      raise Error, "--logs is valid only for job or pod" if logs

      handle, = exact_arguments!(arguments, 1, "fleet FLEET")
      invoke_rpof("fleet", handle, handle)
    end

    def campaign(arguments, logs:)
      raise Error, "--logs is valid only for job or pod" if logs

      handle, = exact_arguments!(arguments, 1, "campaign FLEET")
      invoke_rpof("campaign", nil, handle)
    end

    def invoke_rpof(type, handle, fleet_name, logs: false, lines: nil)
      context = @registry.resolve("fleet", fleet_name)
      root = context.dig("rpof", "repository_root")
      command = ["bundle", "exec", "bin/rpof", "doctor", type]
      command << handle if handle
      command.concat(["--state-root", context.dig("rpof", "state_root"),
                      "--repo-root", root])
      if type == "campaign"
        command.concat(["--campaign", context.dig("rpof", "campaign_path"),
                        "--budget", context.dig("rpof", "budget_path")])
      end
      command << "--logs" if logs
      command.concat(["--lines", Integer(lines).to_s]) if logs && lines
      command << "--json"
      result = run_component(command, root)
      translate_rpof_action!(result, fleet_name) unless logs
      result
    rescue ArgumentError, TypeError
      raise Error, "--lines must be an integer"
    end

    def run_component(command, root)
      result = @runner.capture(
        command, chdir: root,
        env: { "BUNDLE_GEMFILE" => File.join(root, "Gemfile") }
      )
      unless result.status.success?
        detail = result.stderr.to_s.strip
        detail = result.stdout.to_s.strip if detail.empty?
        raise Error, "component diagnostic failed: #{detail}"
      end
      JSON.parse(result.stdout)
    rescue JSON::ParserError => e
      raise Error, "component diagnostic returned invalid JSON: #{e.message}"
    end

    def translate_job_action!(result, batch, context)
      action = result["next_action"]
      return result unless action

      handle = result.dig("subject", "handle")
      case action.fetch("action")
      when "inspect_job_logs"
        action["command"] = "bin/af-doctor job #{batch} #{handle} --logs"
      when "inspect_worker"
        fleets = context.fetch("associated_fleets")
        return result unless action["worker_id"] && fleets.length == 1

        pod = invoke_rpof("pod", action.fetch("worker_id"), fleets.first)
        pod_handle = pod.dig("subject", "handle")
        action["handle"] = pod_handle
        action["command"] = "bin/af-doctor pod #{pod_handle}"
      when "inspect_registry"
        fleets = context.fetch("associated_fleets")
        action["command"] = "bin/af-doctor fleet #{fleets.first}" if fleets.length == 1
      end
      result
    end

    def translate_rpof_action!(result, fleet_name)
      action = result["next_action"]
      return result unless action

      handle = result.dig("subject", "handle")
      action["command"] = case action.fetch("action")
                          when "inspect_pod" then "bin/af-doctor pod #{action.fetch('handle')}"
                          when "inspect_bootstrap_log" then "bin/af-doctor pod #{handle} --logs"
                          when "inspect_fleet_status", "inspect_registry_status"
                            "bin/af-doctor fleet #{fleet_name}"
                          when "inspect_campaign_safety", "inspect_campaign_status", "repeat_teardown_status"
                            "bin/af-doctor campaign #{fleet_name}"
                          end
      action.delete("command") unless action["command"]
      result
    end

    def exact_arguments!(arguments, count, usage)
      raise Error, "expected #{usage}" unless arguments.length == count

      arguments
    end

    def render_logs(result)
      subject = result.fetch("subject")
      @out.puts compact("#{subject.fetch('type').capitalize}: #{subject['handle'] || subject['id']}")
      if result.key?("stderr")
        %w[stderr stdout].each do |stream|
          row = result.fetch(stream)
          @out.puts compact("#{stream.capitalize}: #{row.fetch('path')}")
          row.fetch("lines").each { |line| @out.puts line }
        end
      else
        @out.puts compact("Evidence: #{result['source'] || 'none'}")
        result.fetch("lines").each { |line| @out.puts line }
      end
    end

    def evidence_label(evidence)
      facts = evidence.reject { |key, _| key == "kind" }.first(3)
      ([evidence.fetch("kind")] + facts.map { |key, value| "#{key}=#{value}" }).join("; ")
    end

    def compact(text)
      text.length <= 72 ? text : "#{text[0, 71]}…"
    end
  end
end
