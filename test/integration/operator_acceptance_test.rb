# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "stringio"
require "tmpdir"
require "adventure_finder_operator_acceptance"

class OperatorAcceptanceTest < Minitest::Test
  FakeStatus = Struct.new(:successful) do
    def success?
      successful
    end
  end

  class Runner
    attr_reader :calls

    def initialize(fail: nil)
      @fail = fail
      @calls = []
    end

    def capture(argv, chdir:, env:)
      @calls << {argv:, chdir:, env:}
      name = File.basename(argv.last, ".rb")
      failed = @fail && argv.last.include?(@fail)
      ["fixture #{name}\n", FakeStatus.new(!failed)]
    end
  end

  def setup
    @tmp = Dir.mktmpdir("af-operator-acceptance-")
    @wlo = File.join(@tmp, "workload-orchestrator")
    @rpof = File.join(@tmp, "runpod-ollama-fleet")
    @pipeline = File.join(@tmp, "af-data-pipeline")
    @scorer = File.join(@tmp, "af-cli-scoring-utility")
    @low = File.join(@tmp, "local-ollama-workers")
    @afw = File.join(@tmp, "af-workloads")
    build_component(@low, ["lib/local_ollama_workers/cli.rb"])
    build_component(@afw, %w[
      test/support/afw_wlo_v0_3_contract.rb
      test/staged_selection_test.rb
      test/workload_evidence_manifest_test.rb
    ])
    build_component(@wlo, %w[
      bin/wlo
      test/dynamic_cli_test.rb
      test/dynamic_local_dispatch_test.rb
      test/dw28_late_capacity_integration_test.rb
      test/foreground_cancellation_test.rb
      test/multi_source_worker_test.rb
      test/operator_ux_test.rb
      test/retry_test.rb
      test/worker_registry_poller_test.rb
    ])
    build_component(@rpof, %w[
      test/campaign_lifecycle_test.rb
      test/campaign_safety_gate_test.rb
      test/dynamic_worker_registry_producer_test.rb
      test/operator_process_ownership_test.rb
      test/rpof_campaign_cli_test.rb
      test/runpod_budget_guardian_test.rb
    ])
    build_component(@pipeline, ["test/standing_bulk_score_release_test.rb"])
    build_component(@scorer, ["bin/af-score"])
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_runs_registered_scenarios_with_credentials_removed_and_network_guarded
    runner = Runner.new
    out = StringIO.new
    harness = build_harness(runner:, out:)

    assert harness.run
    assert_equal AdventureFinderWorkspace::OperatorAcceptance::SCENARIOS.length, runner.calls.length
    assert_includes out.string, "Network/provider/inference access: blocked"
    assert_includes out.string, "Acceptance summary: 23/23 scenarios passed"
    assert_includes out.string, "Offline proof: fake providers only; inference calls: 0; paid resources: $0"
    runner.calls.each do |call|
      assert_nil call.dig(:env, "RUNPOD_API_KEY")
      assert_nil call.dig(:env, "OPENAI_API_KEY")
      assert call.fetch(:env).key?("BUNDLE_LOCKFILE")
      assert_nil call.dig(:env, "BUNDLE_LOCKFILE")
      assert_equal "1", call.dig(:env, "AF_OPERATOR_ACCEPTANCE_OFFLINE")
      assert_includes call.dig(:env, "RUBYOPT"), "offline_network_guard.rb"
      assert_equal @wlo, call.dig(:env, "WLO_REPO_ROOT")
      assert_equal @low, call.dig(:env, "LOW_REPO_ROOT")
      assert_equal @afw, call.dig(:env, "AF_AFW_SOURCE_ROOT")
      assert_equal @rpof, call.dig(:env, "RPOF_REPO_ROOT")
      assert_equal @pipeline, call.dig(:env, "AF_IG19B_PIPELINE_SOURCE_ROOT")
      assert_equal @pipeline, call.dig(:env, "AF_DATA_PIPELINE_ROOT")
      assert_equal @scorer, call.dig(:env, "AF_SCORER_ROOT")
    end
  end

  def test_local_multi_model_requires_real_component_seams_before_execution
    runner = Runner.new
    harness = build_harness(runner:)
    assert harness.run(only: ["local-multi-model"])
    assert_equal "test/integration/local_ingest_execution_test.rb", runner.calls.first.fetch(:argv).last
    File.delete(File.join(@low, "lib/local_ollama_workers/cli.rb"))
    error = assert_raises(AdventureFinderWorkspace::Error) { harness.run(only: ["local-multi-model"]) }
    assert_includes error.message, "acceptance public seam is missing"
    assert_equal 1, runner.calls.length
  end

  def test_only_selects_named_scenario_and_preserves_component_bundle
    runner = Runner.new
    harness = build_harness(runner:)

    assert harness.run(only: ["wlo-rpof-publication"])
    assert_equal 1, runner.calls.length
    call = runner.calls.first
    assert_equal @wlo, call.fetch(:chdir)
    assert_equal ["bundle", "exec"], call.fetch(:argv).first(2)
    assert_equal File.join(@wlo, "Gemfile"), call.dig(:env, "BUNDLE_GEMFILE")
  end

  def test_operator_lifecycle_is_a_named_listable_scenario
    scenario = AdventureFinderWorkspace::OperatorAcceptance::SCENARIOS.find do |entry|
      entry.name == "operator-lifecycle"
    end

    refute_nil scenario
    assert_equal "test/integration/operator_lifecycle_test.rb", scenario.test_file
  end

  def test_batch_front_door_is_a_named_offline_scenario
    scenario = AdventureFinderWorkspace::OperatorAcceptance::SCENARIOS.find do |entry|
      entry.name == "batch-front-door"
    end

    refute_nil scenario
    assert_equal "adventure-finder", scenario.repository
    assert_equal "test/batch_front_door_test.rb", scenario.test_file
  end

  def test_ig19b_source_and_boundary_matrices_use_pipeline_bundle
    expected = {
      "ig19b-source-exceptions" => "acceptance/ig19b_source_exception_matrix.rb",
      "ig19b-boundary-exceptions" => "acceptance/ig19b_boundary_exception_matrix.rb"
    }

    expected.each do |name, test_file|
      scenario = AdventureFinderWorkspace::OperatorAcceptance::SCENARIOS.find { |entry| entry.name == name }
      refute_nil scenario
      assert_equal "adventure-finder", scenario.repository
      assert_equal "af-data-pipeline", scenario.bundle_repository
      assert_equal test_file, scenario.test_file
    end
  end

  def test_ig19c_exception_matrices_are_unbundled_front_door_scenarios
    expected = {
      "ig19c-execution-exceptions" => "acceptance/ig19c_execution_exception_matrix.rb",
      "ig19c-evidence-review-exceptions" => "acceptance/ig19c_evidence_review_exception_matrix.rb"
    }

    expected.each do |name, test_file|
      scenario = AdventureFinderWorkspace::OperatorAcceptance::SCENARIOS.find { |entry| entry.name == name }
      refute_nil scenario
      assert_equal "adventure-finder", scenario.repository
      assert_nil scenario.bundle_repository
      assert_equal test_file, scenario.test_file
    end
  end

  def test_audited_recovery_is_a_named_offline_scenario
    scenario = AdventureFinderWorkspace::OperatorAcceptance::SCENARIOS.find do |entry|
      entry.name == "audited-recovery"
    end

    refute_nil scenario
    assert_equal "workload-orchestrator", scenario.repository
    assert_equal "test/retry_test.rb", scenario.test_file
  end

  def test_multi_source_registry_is_a_named_offline_scenario
    scenario = AdventureFinderWorkspace::OperatorAcceptance::SCENARIOS.find do |entry|
      entry.name == "wlo-multi-source-registry"
    end

    refute_nil scenario
    assert_equal "workload-orchestrator", scenario.repository
    assert_equal "test/multi_source_worker_test.rb", scenario.test_file
  end

  def test_foreground_cancellation_is_a_named_offline_scenario
    scenario = AdventureFinderWorkspace::OperatorAcceptance::SCENARIOS.find do |entry|
      entry.name == "wlo-foreground-cancellation"
    end

    refute_nil scenario
    assert_equal "test/foreground_cancellation_test.rb", scenario.test_file
  end

  def test_rpof_safety_gate_is_a_named_network_guarded_scenario
    scenario = AdventureFinderWorkspace::OperatorAcceptance::SCENARIOS.find do |entry|
      entry.name == "rpof-safety-gate"
    end

    refute_nil scenario
    assert_equal "runpod-ollama-fleet", scenario.repository
    assert_equal "test/campaign_safety_gate_test.rb", scenario.test_file
  end

  def test_aggregates_failure_without_skipping_later_scenarios
    runner = Runner.new(fail: "campaign_lifecycle")
    out = StringIO.new
    err = StringIO.new
    harness = build_harness(runner:, out:, err:)

    refute harness.run
    assert_equal AdventureFinderWorkspace::OperatorAcceptance::SCENARIOS.length, runner.calls.length
    assert_includes err.string, "FAIL rpof-campaign-lifecycle"
    assert_includes out.string, "Acceptance summary: 22/23 scenarios passed"
  end

  def test_operator_lifecycle_uses_rpof_bundle_while_running_from_workspace_repo
    runner = Runner.new
    harness = build_harness(runner:)

    assert harness.run(only: ["operator-lifecycle"])
    call = runner.calls.fetch(0)
    assert_equal File.expand_path("../..", __dir__), call.fetch(:chdir)
    assert_equal ["bundle", "exec"], call.fetch(:argv).first(2)
    assert_equal File.join(@rpof, "Gemfile"), call.dig(:env, "BUNDLE_GEMFILE")
  end

  def test_unknown_scenario_and_missing_component_fail_closed_before_execution
    runner = Runner.new
    harness = build_harness(runner:)

    error = assert_raises(AdventureFinderWorkspace::Error) { harness.run(only: ["unknown"]) }
    assert_includes error.message, "unknown acceptance scenario"
    assert_empty runner.calls

    File.delete(File.join(@wlo, "test", "dynamic_cli_test.rb"))
    error = assert_raises(AdventureFinderWorkspace::Error) { harness.run }
    assert_includes error.message, "acceptance scenario file is missing"
    assert_empty runner.calls
  end

  private

  def build_harness(runner:, out: StringIO.new, err: StringIO.new)
    AdventureFinderWorkspace::OperatorAcceptance.new(
      workspace_root: @tmp,
      component_roots: {
        "af-data-pipeline" => @pipeline,
        "af-cli-scoring-utility" => @scorer,
        "local-ollama-workers" => @low,
        "af-workloads" => @afw,
        "workload-orchestrator" => @wlo,
        "runpod-ollama-fleet" => @rpof
      },
      runner:, out:, err:
    )
  end

  def build_component(root, files)
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "Gemfile"), "source \"https://rubygems.org\"\n")
    files.each do |relative|
      path = File.join(root, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "# fixture\n")
    end
  end
end
