# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "stringio"
require "tmpdir"
require "yaml"
require "adventure_finder_batch"

# Run with WLO_REPO_ROOT pointing at the real WLO checkout. Only action-check
# and doctor subprocesses execute; the final work handoff is captured.
class WloActionCheckIntegrationTest < Minitest::Test
  class Handoff
    attr_reader :calls
    def initialize = @calls = []
    def call(environment, argv, chdir:) = @calls << { environment:, argv:, chdir: }
  end

  def setup
    @wlo = ENV["WLO_REPO_ROOT"]
    skip "set WLO_REPO_ROOT to run the real WLO action-check integration" unless @wlo
    @wlo = File.expand_path(@wlo)
    require File.join(@wlo, "lib/workload_orchestrator")
    @tmp = Dir.mktmpdir("af-real-action-check-")
    File.symlink(@wlo, File.join(@tmp, "wlo"))
    @workdir = File.join(@tmp, "work")
    @output = File.join(@tmp, "output")
    @low = File.join(@tmp, "low")
    FileUtils.mkdir_p([@workdir, File.join(@low, "bin")])
    File.write(File.join(@low, "Gemfile"), "")
    File.write(File.join(@low, "bin/low"), "#!/bin/sh\nexit 99\n")
    File.chmod(0o755, File.join(@low, "bin/low"))
    @plan_path = File.join(@workdir, "plan.json")
    @job_id = "production-batch-039-adv0946-structural-openness"
    File.write(@plan_path, JSON.generate(
      "contract_version" => "wlo-execution-plan/v0.3", "plan_id" => "integration-plan",
      "failure_policy" => { "max_consecutive_failures" => 2, "max_total_failures" => 4 },
      "pools" => [{ "pool_id" => "pool" }],
      "jobs" => [{ "job_id" => @job_id, "pool_id" => "pool", "argv" => ["must-not-execute"] }]
    ))
    @registry = File.join(@tmp, "contexts.yml")
    File.write(@registry, YAML.dump(
      "schema_version" => "adventurefinder-production-context/v0.1",
      "contexts" => { "batch" => { "39" => {
        "production_batch_id" => "integration-plan",
        "afw" => { "repository_root" => "work", "workload_root" => "work", "plan_path" => "work/plan.json" },
        "wlo" => { "repository_root" => "wlo", "output_root" => "output" },
        "local_workers" => { "repository_root" => "low" }, "worker_sources" => ["local"],
        "plan" => { "plan_id" => "integration-plan", "sha256" => Digest::SHA256.file(@plan_path).hexdigest },
        "associated_fleets" => []
      } }, "fleet" => {} }
    ))
    @plan = WorkloadOrchestrator::Plan.load(@plan_path)
    @store = WorkloadOrchestrator::ExecutionStore.new(plan: @plan, workdir: @workdir, output_dir: @output)
    @handoff = Handoff.new
    @out = StringIO.new
    @front = AdventureFinderWorkspace::BatchFrontDoor.new(
      registry_path: @registry, workspace_root: @tmp, executor: @handoff, out: @out
    )
  end

  def teardown
    FileUtils.rm_rf(@tmp) if @tmp
  end

  def test_new_run_delegates_and_missing_resume_blocks_using_real_cli
    assert_raises(AdventureFinderWorkspace::Error) { @front.run("resume", "39") }
    assert_empty @handoff.calls
    refute_path_exists @output
    assert_equal 0, @front.run("start", "39")
    assert_includes @handoff.calls.last.fetch(:argv), "run"
    refute_path_exists @output
  end

  def test_paused_run_blocks_and_resume_handoff_leaves_pause_intact
    @store.prepare!
    @store.pause!
    before = evidence
    error = assert_raises(AdventureFinderWorkspace::Error) { @front.run("start", "39") }
    assert_includes error.message, "bin/af-batch resume 39"
    assert_empty @handoff.calls
    assert_equal 0, @front.run("resume", "39")
    assert_includes @handoff.calls.last.fetch(:argv), "resume"
    assert_equal before, evidence
  end

  def test_complete_is_noop_and_unsupported_repair_never_delegates
    terminal("complete")
    @store.finish!
    before = evidence
    assert_equal 0, @front.run("start", "39")
    assert_includes @out.string, "is complete"
    error = assert_raises(AdventureFinderWorkspace::Error) do
      @front.run("repair", "39", reason: "reviewed", dry_run: true)
    end
    assert_includes error.message, "no supported deterministic"
    assert_empty @handoff.calls
    assert_equal before, evidence
  end

  def test_retry_preserves_short_handle_resolution_and_requires_explicit_authorization
    terminal("failed")
    @store.finish!
    before = evidence
    assert_raises(AdventureFinderWorkspace::Error) { @front.run("resume", "39") }
    assert_empty @handoff.calls
    assert_equal 0, @front.run("retry", "39", jobs: ["0946-openness"], reason: "reviewed", dry_run: true)
    argv = @handoff.calls.last.fetch(:argv)
    assert_includes argv, "retry-failed"
    assert_includes argv, @job_id
    assert_includes argv, "--dry-run"
    assert_equal before, evidence
    assert_equal 0, @front.run("recovery", "39")
    assert_includes @handoff.calls.last.fetch(:argv), "recovery"
  end

  def test_active_owner_and_mismatched_evidence_block_real_handoff
    @store.prepare!
    @store.with_execution_lock do
      before = evidence
      error = assert_raises(AdventureFinderWorkspace::Error) { @front.run("start", "39") }
      assert_includes error.message, "active executor"
      assert_equal before, evidence
    end
    File.write(File.join(@output, "plan.json"), "changed")
    assert_raises(AdventureFinderWorkspace::Error) { @front.run("resume", "39") }
    assert_empty @handoff.calls
  end

  def test_frozen_plan_verification_still_precedes_wlo_check
    File.write(@plan_path, "changed")
    error = assert_raises(AdventureFinderWorkspace::Error) { @front.run("start", "39") }
    assert_includes error.message, "registered plan SHA-256 mismatch"
    assert_empty @handoff.calls
    refute_path_exists @output
  end

  private

  def terminal(status)
    @store.prepare!
    worker = WorkloadOrchestrator::Worker.new("fixture", "type" => "command")
    started = @store.record_running!(job: @plan.jobs.first, worker:, environment_keys: [])
    @store.record_terminal!(job: @plan.jobs.first, status:, started_at: started, exit_status: status == "complete" ? 0 : 1)
  end

  def evidence
    Dir.glob(File.join(@output, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
       .to_h { |path| [path, File.binread(path)] }
  end
end
