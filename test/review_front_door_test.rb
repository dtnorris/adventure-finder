# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "stringio"
require "tmpdir"
require "yaml"
require_relative "../lib/adventure_finder_review"

class ReviewFrontDoorTest < Minitest::Test
  FakeStatus = Struct.new(:success?)
  FakeResult = Struct.new(:stdout, :stderr, :status, keyword_init: true)

  class FakeRunner
    attr_reader :calls

    def initialize(receipt_path:, receipt_id:, pipeline_output: nil, failures: {})
      @receipt_path = receipt_path
      @receipt_id = receipt_id
      @pipeline_output = pipeline_output || <<~OUTPUT
        Review package ID: #{"b" * 64}
        Review package: /pipeline/review
        Package reused: false
        Editorial ledger: /pipeline/audit
        Ledger state: pending
        Accepted: 0
        Held: 0
        Rejected: 0
        Pending: 1
        NEXT HUMAN DECISION: edit /pipeline/audit/editorial_decisions.csv and choose ACCEPT/HOLD/REJECT for each pending candidate.
      OUTPUT
      @failures = failures
      @calls = []
    end

    def capture(environment, argv, chdir:)
      component = File.basename(argv.first) == "afw-bind-scoring-evidence" ? :afw : :pipeline
      @calls << { component:, environment:, argv:, chdir: }
      failure = @failures[component]
      return FakeResult.new(stdout: "", stderr: failure, status: FakeStatus.new(false)) if failure

      if component == :afw
        FileUtils.mkdir_p(File.dirname(@receipt_path))
        File.binwrite(@receipt_path, JSON.pretty_generate("receipt_id" => @receipt_id) + "\n")
        FakeResult.new(
          stdout: "Evidence receipt: #{@receipt_path}\n", stderr: "", status: FakeStatus.new(true)
        )
      else
        FakeResult.new(stdout: @pipeline_output, stderr: "", status: FakeStatus.new(true))
      end
    end
  end

  def build_workspace(root, jobs: nil)
    afw = File.join(root, "af-workloads-production")
    workload_id = "production-batch-039-fresh-20260930"
    workload = File.join(afw, "workloads", workload_id)
    wlo = File.join(root, "workload-orchestrator-production")
    output = File.join(wlo, "output", workload_id)
    pipeline = File.join(root, "af-data-pipeline")
    [workload, output, File.join(afw, "bin"), File.join(pipeline, "bin")].each { |path| FileUtils.mkdir_p(path) }
    File.binwrite(File.join(afw, "bin", "afw-bind-scoring-evidence"), "#!/bin/sh\n")
    File.binwrite(File.join(pipeline, "bin", "af-data"), "#!/bin/sh\n")
    FileUtils.chmod(0o755, File.join(afw, "bin", "afw-bind-scoring-evidence"))
    FileUtils.chmod(0o755, File.join(pipeline, "bin", "af-data"))

    jobs ||= [
      { "job_id" => "batch039-adv0941-seriousness", "group_id" => "ADV-0941" },
      { "job_id" => "batch039-adv0942-combat", "group_id" => "ADV-0942" }
    ]
    plan = {
      "contract_version" => "wlo-execution-plan/v0.3",
      "plan_id" => workload_id,
      "jobs" => jobs
    }
    plan_path = File.join(workload, "execution-plan.json")
    plan_bytes = JSON.pretty_generate(plan) + "\n"
    File.binwrite(plan_path, plan_bytes)
    registry_path = File.join(root, "contexts.yml")
    registry = {
      "schema_version" => "adventurefinder-production-context/v0.1",
      "contexts" => {
        "batch" => {
          "39" => {
            "production_batch_id" => workload_id,
            "afw" => {
              "repository_root" => "af-workloads-production",
              "workload_root" => "af-workloads-production/workloads/#{workload_id}",
              "plan_path" => "af-workloads-production/workloads/#{workload_id}/execution-plan.json"
            },
            "wlo" => {
              "repository_root" => "workload-orchestrator-production",
              "output_root" => "workload-orchestrator-production/output/#{workload_id}"
            },
            "plan" => {
              "plan_id" => workload_id,
              "sha256" => Digest::SHA256.hexdigest(plan_bytes),
              "authority" => "fixture"
            },
            "associated_fleets" => []
          }
        },
        "fleet" => {}
      }
    }
    File.binwrite(registry_path, YAML.dump(registry))
    manifest_path = File.join(root, "repos.yml")
    manifest = {
      "schema_version" => "adventurefinder-workspace/v0.1",
      "workspace_root_default" => root,
      "repositories" => [{
        "name" => "af-data-pipeline", "github" => "dtnorris/af-data-pipeline",
        "role" => "review", "lifecycle" => "current", "default" => true
      }]
    }
    File.binwrite(manifest_path, YAML.dump(manifest))
    receipt_path = File.join(afw, "output", "workloads", workload_id, "evidence", "batch039-adv0941-seriousness.json")
    { afw:, workload_id:, wlo:, output:, pipeline:, plan_path:, registry_path:, manifest_path:, receipt_path: }
  end

  def front_door(paths, runner, out: StringIO.new)
    door = AdventureFinderWorkspace::ReviewFrontDoor.new(
      registry_path: paths.fetch(:registry_path), manifest_path: paths.fetch(:manifest_path),
      workspace_root: File.dirname(paths.fetch(:registry_path)), component_runner: runner, out:
    )
    [door, out]
  end

  def test_prepare_resolves_context_and_job_then_delegates_exact_public_commands
    Dir.mktmpdir do |root|
      paths = build_workspace(root)
      runner = FakeRunner.new(receipt_path: paths.fetch(:receipt_path), receipt_id: "a" * 64)
      door, out = front_door(paths, runner)

      assert_equal 0, door.prepare("39", "0941-seriousness")
      assert_equal %i[afw pipeline], runner.calls.map { |call| call.fetch(:component) }
      afw_call, pipeline_call = runner.calls
      assert_equal [
        File.join(paths.fetch(:afw), "bin", "afw-bind-scoring-evidence"),
        paths.fetch(:workload_id), paths.fetch(:output), "batch039-adv0941-seriousness"
      ], afw_call.fetch(:argv)
      assert_equal paths.fetch(:afw), afw_call.fetch(:chdir)
      expected_review = File.join(
        paths.fetch(:pipeline), "output", "adventure-finder-review", paths.fetch(:workload_id),
        "batch039-adv0941-seriousness"
      )
      expected_audit = File.join(
        paths.fetch(:pipeline), "audits", "adventure-finder-review", paths.fetch(:workload_id),
        "batch039-adv0941-seriousness"
      )
      assert_equal [
        File.join(paths.fetch(:pipeline), "bin", "af-data"), "prepare-review", paths.fetch(:receipt_path),
        "--afw-root", paths.fetch(:afw), "--review-dir", expected_review, "--audit-dir", expected_audit
      ], pipeline_call.fetch(:argv)
      assert_equal paths.fetch(:pipeline), pipeline_call.fetch(:chdir)
      assert_includes out.string, "Job: 0941-seriousness -> batch039-adv0941-seriousness"
    end
  end

  def test_invalid_batch_fails_before_delegation
    Dir.mktmpdir do |root|
      paths = build_workspace(root)
      runner = FakeRunner.new(receipt_path: paths.fetch(:receipt_path), receipt_id: "a" * 64)
      door, = front_door(paths, runner)

      assert_raises(AdventureFinderWorkspace::Error) { door.prepare("missing", "0941-seriousness") }
      assert_empty runner.calls
    end
  end

  def test_registered_plan_hash_mismatch_fails_before_delegation
    Dir.mktmpdir do |root|
      paths = build_workspace(root)
      File.open(paths.fetch(:plan_path), "ab") { |file| file.write(" ") }
      runner = FakeRunner.new(receipt_path: paths.fetch(:receipt_path), receipt_id: "a" * 64)
      door, = front_door(paths, runner)

      error = assert_raises(AdventureFinderWorkspace::Error) { door.prepare("39", "0941-seriousness") }
      assert_match(/plan SHA-256 mismatch/, error.message)
      assert_empty runner.calls
    end
  end

  def test_unknown_and_ambiguous_job_handles_fail_before_delegation
    Dir.mktmpdir do |root|
      jobs = [
        { "job_id" => "one-adv0941-seriousness", "group_id" => "ADV-0941" },
        { "job_id" => "two-adv0941-seriousness", "group_id" => "ADV-0941" }
      ]
      paths = build_workspace(root, jobs:)
      runner = FakeRunner.new(receipt_path: paths.fetch(:receipt_path), receipt_id: "a" * 64)
      door, = front_door(paths, runner)

      assert_raises(AdventureFinderWorkspace::Error) { door.prepare("39", "not-a-job") }
      error = assert_raises(AdventureFinderWorkspace::Error) { door.prepare("39", "0941-seriousness") }
      assert_match(/ambiguous/, error.message)
      assert_empty runner.calls
    end
  end

  def test_afw_failure_preserves_owner_reason_and_stops_pipeline_delegation
    Dir.mktmpdir do |root|
      paths = build_workspace(root)
      runner = FakeRunner.new(
        receipt_path: paths.fetch(:receipt_path), receipt_id: "a" * 64,
        failures: { afw: "ERROR: no complete AFSU evidence set belongs to the authoritative WLO attempt" }
      )
      door, = front_door(paths, runner)

      error = assert_raises(AdventureFinderWorkspace::Error) { door.prepare("39", "0941-seriousness") }
      assert_match(/no complete AFSU evidence set/, error.message)
      assert_match(/Next: resolve the reported evidence\/execution problem/, error.message)
      assert_equal [:afw], runner.calls.map { |call| call.fetch(:component) }
    end
  end

  def test_pipeline_conflict_preserves_owner_reason
    Dir.mktmpdir do |root|
      paths = build_workspace(root)
      runner = FakeRunner.new(
        receipt_path: paths.fetch(:receipt_path), receipt_id: "a" * 64,
        failures: { pipeline: "ERROR: existing review package conflicts at candidates.jsonl" }
      )
      door, = front_door(paths, runner)

      error = assert_raises(AdventureFinderWorkspace::Error) { door.prepare("39", "0941-seriousness") }
      assert_match(/existing review package conflicts/, error.message)
      assert_match(/Next: resolve the reported review package\/ledger problem/, error.message)
    end
  end

  def test_pending_output_relays_owner_identity_state_counts_and_next_action
    Dir.mktmpdir do |root|
      paths = build_workspace(root)
      runner = FakeRunner.new(receipt_path: paths.fetch(:receipt_path), receipt_id: "a" * 64)
      door, out = front_door(paths, runner)
      door.prepare("39", "0941-seriousness")

      assert_includes out.string, "AFW receipt: #{paths.fetch(:receipt_path)}"
      assert_includes out.string, "AFW receipt ID: #{'a' * 64}"
      assert_includes out.string, "Review package ID: #{'b' * 64}"
      assert_includes out.string, "Ledger state: pending"
      assert_includes out.string, "Accepted: 0"
      assert_includes out.string, "Pending: 1"
      assert_includes out.string, "choose ACCEPT/HOLD/REJECT"
    end
  end

  def test_decided_output_relays_owner_no_pending_decision_action
    Dir.mktmpdir do |root|
      paths = build_workspace(root)
      output = <<~OUTPUT
        Review package ID: #{"b" * 64}
        Review package: /pipeline/review
        Package reused: true
        Editorial ledger: /pipeline/audit
        Ledger state: decided
        Accepted: 1
        Held: 0
        Rejected: 0
        Pending: 0
        NEXT HUMAN DECISION: none; every candidate already has a preserved editorial decision.
      OUTPUT
      runner = FakeRunner.new(
        receipt_path: paths.fetch(:receipt_path), receipt_id: "a" * 64, pipeline_output: output
      )
      door, out = front_door(paths, runner)
      door.prepare("39", "0941-seriousness")

      assert_includes out.string, "Ledger state: decided"
      assert_includes out.string, "NEXT HUMAN DECISION: none"
    end
  end

  def test_repeated_prepare_uses_same_paths_and_does_not_touch_decisions
    Dir.mktmpdir do |root|
      paths = build_workspace(root)
      ledger = File.join(
        paths.fetch(:pipeline), "audits", "adventure-finder-review", paths.fetch(:workload_id),
        "batch039-adv0941-seriousness", "editorial_decisions.csv"
      )
      FileUtils.mkdir_p(File.dirname(ledger))
      File.binwrite(ledger, "preserved human decision bytes\n")
      runner = FakeRunner.new(receipt_path: paths.fetch(:receipt_path), receipt_id: "a" * 64)
      door, = front_door(paths, runner)

      2.times { assert_equal 0, door.prepare("39", "0941-seriousness") }
      pipeline_calls = runner.calls.select { |call| call.fetch(:component) == :pipeline }
      assert_equal pipeline_calls[0].fetch(:argv), pipeline_calls[1].fetch(:argv)
      assert_equal "preserved human decision bytes\n", File.binread(ledger)
      assert_equal 1, pipeline_calls.map { |call| call.fetch(:argv).fetch(6) }.uniq.length
      assert_equal 1, pipeline_calls.map { |call| call.fetch(:argv).fetch(8) }.uniq.length
    end
  end

  def test_production_source_contains_only_context_delegation_and_presentation
    source = File.binread(File.expand_path("../lib/adventure_finder_review.rb", __dir__))
    forbidden = [
      "execution.json", "jobs.json", ".execution.lock", "attempts/", "assessment CSV",
      "CSV.parse", "Digest::SHA256", "EditorialAudit", "AmcApply", "amc-apply", "editorial_decision"
    ]
    forbidden.each { |term| refute_includes source, term }
  end
end
