# frozen_string_literal: true

require "open3"
require "pathname"
require "rbconfig"
require_relative "adventure_finder_workspace"

module AdventureFinderWorkspace
  class OperatorAcceptance
    Scenario = Struct.new(:name, :description, :repository, :test_file, keyword_init: true)
    Result = Struct.new(:scenario, :output, :status, keyword_init: true) do
      def success?
        status.success?
      end
    end

    SCENARIOS = [
      Scenario.new(
        name: "production-context",
        description: "registered batch/fleet resolution and fail-closed verification",
        repository: "adventure-finder",
        test_file: "test/production_context_test.rb"
      ),
      Scenario.new(
        name: "wlo-dynamic-cli",
        description: "real WLO CLI run/start/pause/resume and malformed-source failure",
        repository: "workload-orchestrator",
        test_file: "test/dynamic_cli_test.rb"
      ),
      Scenario.new(
        name: "wlo-ready-workers",
        description: "READY-only heterogeneous local dispatch with no provider fallback",
        repository: "workload-orchestrator",
        test_file: "test/dynamic_local_dispatch_test.rb"
      ),
      Scenario.new(
        name: "wlo-rpof-publication",
        description: "late fake RPOF capacity publication consumed by WLO",
        repository: "workload-orchestrator",
        test_file: "test/dw28_late_capacity_integration_test.rb"
      ),
      Scenario.new(
        name: "wlo-process-ownership",
        description: "WLO work-owner, observer, pause and paid-capacity boundaries",
        repository: "workload-orchestrator",
        test_file: "test/operator_ux_test.rb"
      ),
      Scenario.new(
        name: "rpof-campaign-cli",
        description: "real campaign CLI surface with stubbed lifecycle mutations",
        repository: "runpod-ollama-fleet",
        test_file: "test/rpof_campaign_cli_test.rb"
      ),
      Scenario.new(
        name: "rpof-campaign-lifecycle",
        description: "campaign plan/start/status/stop through fake provider admission",
        repository: "runpod-ollama-fleet",
        test_file: "test/campaign_lifecycle_test.rb"
      ),
      Scenario.new(
        name: "rpof-worker-publication",
        description: "READY/NOT_READY/UNAVAILABLE publication and identity failures",
        repository: "runpod-ollama-fleet",
        test_file: "test/dynamic_worker_registry_producer_test.rb"
      ),
      Scenario.new(
        name: "process-ownership",
        description: "FO-02 observer, pause, work-owner and teardown help boundaries",
        repository: "runpod-ollama-fleet",
        test_file: "test/operator_process_ownership_test.rb"
      )
    ].freeze

    CREDENTIAL_NAMES = %w[
      RUNPOD_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY GOOGLE_API_KEY
      AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    ].freeze

    class SubprocessRunner
      Status = Struct.new(:exitstatus) do
        def success?
          exitstatus.zero?
        end
      end

      def capture(argv, chdir:, env:)
        output, status = Open3.capture2e(env, *argv, chdir: chdir)
        [output, Status.new(status.exitstatus)]
      end
    end

    attr_reader :scenarios

    def initialize(workspace_root: nil, manifest_path: nil, component_roots: {},
                   runner: SubprocessRunner.new, out: $stdout, err: $stderr)
      @repository_root = File.expand_path("..", __dir__)
      @manifest_path = File.expand_path(manifest_path || File.join(@repository_root, "repos.yml"))
      @manifest = Manifest.new(@manifest_path)
      @workspace_root = File.expand_path(
        workspace_root || ENV["AF_PROJECT_ROOT"] || @manifest.workspace_root_default
      )
      @component_roots = component_roots.transform_keys(&:to_s).transform_values { |path| File.expand_path(path) }
      @runner = runner
      @out = out
      @err = err
      @network_guard = File.join(@repository_root, "test", "support", "offline_network_guard.rb")
      @scenarios = SCENARIOS
    end

    def run(only: [])
      selected = select_scenarios(only)
      roots = resolve_roots
      validate!(selected, roots)
      @out.puts "AdventureFinder offline operator acceptance"
      @out.puts "Network/provider/inference access: blocked"
      roots.sort.each { |name, path| @out.puts "#{name}: #{path}" }

      results = selected.map.with_index(1) do |scenario, index|
        @out.puts "[#{index}/#{selected.length}] #{scenario.name}: #{scenario.description}"
        result = run_scenario(scenario, roots)
        stream_result(result)
        result
      end

      passed = results.count(&:success?)
      @out.puts "Acceptance summary: #{passed}/#{results.length} scenarios passed"
      passed == results.length
    end

    private

    def select_scenarios(names)
      return scenarios if names.empty?

      requested = names.uniq
      unknown = requested - scenarios.map(&:name)
      raise Error, "unknown acceptance scenario(s): #{unknown.join(', ')}" unless unknown.empty?

      scenarios.select { |scenario| requested.include?(scenario.name) }
    end

    def resolve_roots
      registered = @manifest.repositories.to_h { |repository| [repository.fetch("name"), repository] }
      %w[workload-orchestrator runpod-ollama-fleet].each do |name|
        raise Error, "acceptance component is not registered in repos.yml: #{name}" unless registered.key?(name)
      end

      {
        "adventure-finder" => @repository_root,
        "workload-orchestrator" => component_root("workload-orchestrator", "WLO_REPO_ROOT"),
        "runpod-ollama-fleet" => component_root("runpod-ollama-fleet", "RPOF_REPO_ROOT")
      }
    end

    def component_root(name, environment_name)
      File.expand_path(@component_roots[name] || ENV[environment_name] || File.join(@workspace_root, name))
    end

    def validate!(selected, roots)
      raise Error, "offline network guard is missing: #{@network_guard}" unless File.file?(@network_guard)

      selected.each do |scenario|
        root = roots.fetch(scenario.repository)
        raise Error, "#{scenario.repository} checkout is missing: #{root}" unless File.directory?(root)

        test_path = File.join(root, scenario.test_file)
        raise Error, "acceptance scenario file is missing: #{test_path}" unless File.file?(test_path)

        next if scenario.repository == "adventure-finder"

        gemfile = File.join(root, "Gemfile")
        raise Error, "component Gemfile is missing: #{gemfile}" unless File.file?(gemfile)
      end
    end

    def run_scenario(scenario, roots)
      root = roots.fetch(scenario.repository)
      argv = scenario_argv(scenario)
      output, status = @runner.capture(argv, chdir: root, env: scenario_environment(scenario, roots))
      Result.new(scenario:, output:, status:)
    end

    def scenario_argv(scenario)
      ruby = RbConfig.ruby
      return [ruby, "-Ilib", "-Itest", scenario.test_file] if scenario.repository == "adventure-finder"

      ["bundle", "exec", ruby, "-Ilib", "-Itest", scenario.test_file]
    end

    def scenario_environment(scenario, roots)
      inherited_rubyopt = ENV["RUBYOPT"].to_s.strip
      rubyopt = ["-r#{@network_guard}", inherited_rubyopt].reject(&:empty?).join(" ")
      environment = CREDENTIAL_NAMES.to_h { |name| [name, nil] }.merge(
        "AF_OPERATOR_ACCEPTANCE_OFFLINE" => "1",
        "RPOF_REPO_ROOT" => roots.fetch("runpod-ollama-fleet"),
        "RUBYOPT" => rubyopt
      )
      if scenario.repository == "adventure-finder"
        environment["BUNDLE_GEMFILE"] = nil
      else
        environment["BUNDLE_GEMFILE"] = File.join(roots.fetch(scenario.repository), "Gemfile")
      end
      environment
    end

    def stream_result(result)
      destination = result.success? ? @out : @err
      destination.write(result.output)
      destination.puts unless result.output.empty? || result.output.end_with?("\n")
      destination.puts(result.success? ? "PASS #{result.scenario.name}" : "FAIL #{result.scenario.name}")
    end
  end
end
