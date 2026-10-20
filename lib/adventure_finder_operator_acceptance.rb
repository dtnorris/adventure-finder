# frozen_string_literal: true

require "open3"
require "pathname"
require "rbconfig"
require_relative "adventure_finder_workspace"

module AdventureFinderWorkspace
  class OperatorAcceptance
    Scenario = Struct.new(:name, :description, :repository, :test_file, :bundle_repository, :required_paths, keyword_init: true)
    Result = Struct.new(:scenario, :output, :status, keyword_init: true) do
      def success?
        status.success?
      end
    end

    SCENARIOS = [
      Scenario.new(
        name: "ig19d-restart-promotion",
        description: "fresh-process durable source, boundary, standing-release and exact promotion proof",
        repository: "adventure-finder",
        test_file: "acceptance/ig19d_restart_promotion_test.rb",
        bundle_repository: "af-data-pipeline",
        required_paths: {"af-data-pipeline" => "bin/af-final-release-adoption"}
      ),
      Scenario.new(
        name: "ig19d-staleness",
        description: "staged/shared-head concurrency, frozen workload, execution and release predicates",
        repository: "adventure-finder",
        test_file: "acceptance/ig19d_staleness_matrix.rb",
        required_paths: {"af-data-pipeline" => "test/staged_scoring_authority_stale_base_acceptance_test.rb"}
      ),
      Scenario.new(
        name: "ig19a-entry-contract",
        description: "IG-19A public start, conversion receipt, durable binding and restart/replay",
        repository: "adventure-finder",
        test_file: "acceptance/ig19a_entry_contract.rb",
        bundle_repository: "af-data-pipeline",
        required_paths: {"af-data-pipeline" => "bin/af-ingest-next"}
      ),
      Scenario.new(
        name: "local-multi-model",
        description: "IG-15C3/IG-15D one-worker capability transition, interruption and explicit recovery proof",
        repository: "adventure-finder",
        test_file: "test/integration/local_ingest_execution_test.rb",
        required_paths: {
          "local-ollama-workers" => "lib/local_ollama_workers/cli.rb",
          "af-workloads" => "test/support/afw_wlo_v0_3_contract.rb",
          "workload-orchestrator" => "bin/wlo"
        }
      ),
      Scenario.new(
        name: "batch-front-door",
        description: "frozen Batch 39 foreground start/resume with no remanifest or provider mutation",
        repository: "adventure-finder",
        test_file: "test/batch_front_door_test.rb"
      ),
      Scenario.new(
        name: "batch-dynamic-sources",
        description: "continuous synthetic batch resume, default optional and explicit required publishers, exact evidence and failure-bearing accounting",
        repository: "adventure-finder",
        test_file: "test/integration/batch_dynamic_sources_test.rb",
        required_paths: {
          "workload-orchestrator" => "bin/wlo",
          "af-workloads" => "workloads/production-batch-039-fresh-20260930/execution-plan.json"
        }
      ),
      Scenario.new(
        name: "ig19b-source-exceptions",
        description: "source, conversion, identity, registry, restart, and correction exception matrix",
        repository: "adventure-finder",
        test_file: "acceptance/ig19b_source_exception_matrix.rb",
        bundle_repository: "af-data-pipeline"
      ),
      Scenario.new(
        name: "ig19b-boundary-exceptions",
        description: "editorial approval, frozen boundary, staged successor, and replay exception matrix",
        repository: "adventure-finder",
        test_file: "acceptance/ig19b_boundary_exception_matrix.rb",
        bundle_repository: "af-data-pipeline"
      ),
      Scenario.new(
        name: "final-promotion",
        description: "exact release review, catalog adoption, stale refusal, replay, and scoped Git handoff",
        repository: "adventure-finder",
        test_file: "acceptance/ig18c_final_promotion_matrix.rb",
        bundle_repository: "af-data-pipeline",
        required_paths: {
          "af-data-pipeline" => "bin/af-final-release-adoption"
        }
      ),
      Scenario.new(
        name: "ig19c-execution-exceptions",
        description: "standing-ingestion eligibility, local capability, WLO execution, and explicit recovery matrix",
        repository: "adventure-finder",
        test_file: "acceptance/ig19c_execution_exception_matrix.rb",
        required_paths: {
          "local-ollama-workers" => "lib/local_ollama_workers/cli.rb",
          "af-workloads" => "test/staged_selection_test.rb",
          "workload-orchestrator" => "test/retry_test.rb"
        }
      ),
      Scenario.new(
        name: "ig19c-evidence-review-exceptions",
        description: "current evidence, complete accounting, standing authority, and review-routing matrix",
        repository: "adventure-finder",
        test_file: "acceptance/ig19c_evidence_review_exception_matrix.rb",
        required_paths: {
          "af-workloads" => "test/workload_evidence_manifest_test.rb",
          "af-data-pipeline" => "test/standing_bulk_score_release_test.rb",
          "af-cli-scoring-utility" => "bin/af-score"
        }
      ),
      Scenario.new(
        name: "wlo-multi-source-registry",
        description: "local-only, remote-only, mixed, namespace-preserving scheduling and scoped loss",
        repository: "workload-orchestrator",
        test_file: "test/multi_source_worker_test.rb"
      ),
      Scenario.new(
        name: "local-capacity-bootstrap",
        description: "explicit frozen-plan requirement handoff to LOW with no implicit bootstrap",
        repository: "adventure-finder",
        test_file: "test/local_capacity_test.rb"
      ),
      Scenario.new(
        name: "audited-recovery",
        description: "selected retry preview, evidence archive, durable audit, and fail-closed repair",
        repository: "workload-orchestrator",
        test_file: "test/retry_test.rb"
      ),
      Scenario.new(
        name: "production-context",
        description: "registered batch/fleet resolution and fail-closed verification",
        repository: "adventure-finder",
        test_file: "test/production_context_test.rb"
      ),
      Scenario.new(
        name: "operator-lifecycle",
        description: "one coherent portable-context, campaign, publication, WLO, and teardown replay",
        repository: "adventure-finder",
        test_file: "test/integration/operator_lifecycle_test.rb",
        bundle_repository: "runpod-ollama-fleet"
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
        name: "wlo-foreground-cancellation",
        description: "scoped child-tree cancellation contrasted with graceful pause draining",
        repository: "workload-orchestrator",
        test_file: "test/foreground_cancellation_test.rb"
      ),
      Scenario.new(
        name: "wlo-registry-failures",
        description: "stale, replayed, changed, and future-dated registry rejection",
        repository: "workload-orchestrator",
        test_file: "test/worker_registry_poller_test.rb"
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
        name: "rpof-safety-gate",
        description: "finite crash liability, guardian identity, billing scope, and fail-closed paid start",
        repository: "runpod-ollama-fleet",
        test_file: "test/campaign_safety_gate_test.rb"
      ),
      Scenario.new(
        name: "rpof-worker-publication",
        description: "READY/NOT_READY/UNAVAILABLE publication and identity failures",
        repository: "runpod-ollama-fleet",
        test_file: "test/dynamic_worker_registry_producer_test.rb"
      ),
      Scenario.new(
        name: "rpof-teardown",
        description: "guardian teardown retry, provider-absence proof, and final CLOSED transition",
        repository: "runpod-ollama-fleet",
        test_file: "test/runpod_budget_guardian_test.rb"
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
      complete = !results.empty? && passed == results.length
      @out.puts "Offline proof: fake providers only; inference calls: 0; paid resources: $0" if complete
      complete
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
      %w[af-data-pipeline workload-orchestrator runpod-ollama-fleet af-cli-scoring-utility].each do |name|
        raise Error, "acceptance component is not registered in repos.yml: #{name}" unless registered.key?(name)
      end

      {
        "adventure-finder" => @repository_root,
        "local-ollama-workers" => component_root("local-ollama-workers", "LOW_REPO_ROOT"),
        "af-workloads" => component_root("af-workloads", "AF_AFW_SOURCE_ROOT"),
        "af-data-pipeline" => component_root("af-data-pipeline", "AF_DATA_PIPELINE_ROOT"),
        "af-cli-scoring-utility" => component_root("af-cli-scoring-utility", "AF_SCORER_ROOT"),
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
        (scenario.required_paths || {}).each do |repository, relative|
          path = File.join(roots.fetch(repository), relative)
          raise Error, "acceptance public seam is missing: #{path}" unless File.file?(path)
        end
        root = roots.fetch(scenario.repository)
        raise Error, "#{scenario.repository} checkout is missing: #{root}" unless File.directory?(root)

        test_path = File.join(root, scenario.test_file)
        raise Error, "acceptance scenario file is missing: #{test_path}" unless File.file?(test_path)

        bundle_repository = scenario.bundle_repository ||
                            (scenario.repository unless scenario.repository == "adventure-finder")
        next unless bundle_repository

        gemfile = File.join(roots.fetch(bundle_repository), "Gemfile")
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
      unless scenario.bundle_repository || scenario.repository != "adventure-finder"
        return [ruby, "-Ilib", "-Itest", scenario.test_file]
      end

      ["bundle", "exec", ruby, "-Ilib", "-Itest", scenario.test_file]
    end

    def scenario_environment(scenario, roots)
      inherited_rubyopt = ENV["RUBYOPT"].to_s.strip
      rubyopt = ["-r#{@network_guard}", inherited_rubyopt].reject(&:empty?).join(" ")
      environment = CREDENTIAL_NAMES.to_h { |name| [name, nil] }.merge(
        "AF_OPERATOR_ACCEPTANCE_OFFLINE" => "1",
        "BUNDLE_LOCKFILE" => nil,
        "AF_IG19B_PIPELINE_SOURCE_ROOT" => roots.fetch("af-data-pipeline"),
        "AF_DATA_PIPELINE_ROOT" => roots.fetch("af-data-pipeline"),
        "AF_SCORER_ROOT" => roots.fetch("af-cli-scoring-utility"),
        "WLO_REPO_ROOT" => roots.fetch("workload-orchestrator"),
        "LOW_REPO_ROOT" => roots.fetch("local-ollama-workers"),
        "AF_AFW_SOURCE_ROOT" => roots.fetch("af-workloads"),
        "RPOF_REPO_ROOT" => roots.fetch("runpod-ollama-fleet"),
        "RUBYOPT" => rubyopt
      )
      bundle_repository = scenario.bundle_repository ||
                          (scenario.repository unless scenario.repository == "adventure-finder")
      if bundle_repository.nil?
        environment["BUNDLE_GEMFILE"] = nil
      else
        environment["BUNDLE_GEMFILE"] = File.join(roots.fetch(bundle_repository), "Gemfile")
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
