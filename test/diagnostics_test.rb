# frozen_string_literal: true

require "json"
require "fileutils"
require "minitest/autorun"
require "stringio"
require "tmpdir"
require "adventure_finder_workspace"
require "adventure_finder_diagnostics"

class DiagnosticsTest < Minitest::Test
  Status = Struct.new(:successful) { def success? = successful }
  Result = Struct.new(:stdout, :stderr, :status, keyword_init: true)

  class Runner
    attr_reader :calls

    def initialize(*documents)
      @documents = documents
      @calls = []
    end

    def capture(argv, chdir:, env:)
      @calls << { argv:, chdir:, env: }
      document = @documents.shift
      Result.new(stdout: JSON.generate(document), stderr: "", status: Status.new(true))
    end
  end

  def setup
    @root = Dir.mktmpdir("af-diagnostics-")
    @registry = File.expand_path("../config/production_contexts.yml", __dir__)
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_job_context_delegates_to_wlo_and_maps_exact_worker_to_pod
    job = diagnosis("job", "0946-openness", "worker_eligibility",
                    "inspect_pod" => { "worker_id" => "worker-2" })
    pod = diagnosis("pod", "A2", "bootstrap", "inspect_bootstrap_log" => {})
    runner = Runner.new(job, pod)

    result = diagnostics(runner).call("job", %w[39 0946-openness])

    assert_equal "bin/af-doctor pod A2", result.dig("next_action", "command")
    assert_equal "workload-orchestrator-production", File.basename(runner.calls.first.fetch(:chdir))
    assert_includes runner.calls.first.fetch(:argv), "bin/wlo"
    assert_includes runner.calls.last.fetch(:argv), "worker-2"
    assert_equal "runpod-ollama-fleet-production", File.basename(runner.calls.last.fetch(:chdir))
  end

  def test_job_logs_are_delegated_without_diagnostic_reclassification
    logs = {
      "subject" => { "type" => "job", "handle" => "0946-openness", "id" => "canonical" },
      "metadata" => { "attempt" => 1 },
      "stderr" => { "path" => "runs/job/stderr.log", "lines" => ["failed"] },
      "stdout" => { "path" => "runs/job/stdout.log", "lines" => [] }
    }
    runner = Runner.new(logs)

    assert_equal logs, diagnostics(runner).call("job", %w[39 0946-openness], logs: true, lines: 12)
    assert_includes runner.calls.first.fetch(:argv), "logs"
    assert_includes runner.calls.first.fetch(:argv), "12"
  end

  def test_pod_and_campaign_resolve_fleet_context_and_translate_actions
    pod_runner = Runner.new(diagnosis("pod", "A2", "bootstrap", "inspect_bootstrap_log" => {}))
    pod = diagnostics(pod_runner).call("pod", ["A2"])
    assert_equal "bin/af-doctor pod A2 --logs", pod.dig("next_action", "command")
    assert_includes pod_runner.calls.first.fetch(:argv), "--state-root"

    campaign_runner = Runner.new(diagnosis("campaign", nil, "guardian", "inspect_campaign_status" => {}))
    campaign = diagnostics(campaign_runner).call("campaign", ["A"])
    assert_equal "bin/af-doctor campaign A", campaign.dig("next_action", "command")
    assert_includes campaign_runner.calls.first.fetch(:argv), "--campaign"
    assert_includes campaign_runner.calls.first.fetch(:argv), "--budget"
  end

  def test_short_pod_handle_and_argument_errors_fail_closed
    instance = diagnostics(Runner.new)
    assert_raises(AdventureFinderWorkspace::Error) { instance.call("pod", ["worker-2"]) }
    assert_raises(AdventureFinderWorkspace::Error) { instance.call("job", ["39"]) }
    assert_raises(AdventureFinderWorkspace::Error) { instance.call("fleet", ["A"], logs: true) }
  end

  def test_human_output_is_compact_and_json_remains_full
    out = StringIO.new
    result = diagnosis("job", "0946-openness", "command_failure", "inspect_job_logs" => {})
    instance = diagnostics(Runner.new(result), out:)
    translated = instance.call("job", %w[39 0946-openness])
    instance.render(translated)

    assert out.string.lines.all? { |line| line.chomp.length <= 72 }
    assert_includes out.string, "Stage: command failure"
    assert_includes out.string, "bin/af-doctor job 39 0946-openness --logs"
    assert_equal "retained fixture evidence", translated.fetch("summary")
  end

  private

  def diagnostics(runner, out: StringIO.new)
    AdventureFinderWorkspace::Diagnostics.new(
      registry_path: @registry, workspace_root: @root, runner:, out:
    )
  end

  def diagnosis(type, handle, stage, action)
    action_id, extra = action.first
    subject = { "type" => type }
    subject["handle"] = handle if handle
    subject["id"] = "campaign-39" unless handle
    {
      "subject" => subject, "stage" => stage, "status" => "blocked",
      "summary" => "retained fixture evidence",
      "evidence" => [{ "kind" => "fixture", "revision" => 41 }],
      "next_action" => { "action" => action_id }.merge(extra)
    }
  end
end
