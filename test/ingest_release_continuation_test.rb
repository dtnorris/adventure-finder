# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"
require "adventure_finder_ingest_release_continuation"

class IngestReleaseContinuationTest < Minitest::Test
  ID = "11111111-1111-4111-8111-111111111111"
  WORKLOAD = "operation-11111111-1111-4111-8111-111111111111"

  def setup
    @root = Dir.mktmpdir("ingest-release-continuation-")
    @front = File.join(@root, "front")
    @project = File.join(@root, "components")
    @afw = File.join(@project, "af-workloads")
    @pipeline = File.join(@project, "af-data-pipeline")
    @catalog = File.join(@root, "catalog")
    @calls = []
    @service = AdventureFinderWorkspace::IngestReleaseContinuation.new(
      front_door_root: @front, project_root: @project, pipeline_root: @pipeline,
      catalog_root: @catalog, env: {"AF_AFW_ROOT" => @afw},
      runner: ->(*args, **kwargs) { @calls << [args, kwargs]; raise "owner command must not run" }
    )
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_missing_qualified_workload_never_observes_or_publishes_evidence
    error = assert_raises(AdventureFinderWorkspace::IngestReleaseContinuation::Failure) do
      @service.prepare(operation_id: ID)
    end
    assert_equal "INVALID_RELEASE_INPUT", error.code
    assert_empty @calls
  end

  def test_changed_frozen_plan_never_observes_or_publishes_evidence
    workload = File.join(@afw, "workloads", WORKLOAD)
    FileUtils.mkdir_p(workload)
    plan = File.join(workload, "execution-plan.json")
    File.write(plan, "first frozen plan\n")
    preparation = File.join(@front, "output", "staged-workload-preparations", "v0.1", ID)
    FileUtils.mkdir_p(preparation)
    File.write(File.join(preparation, "result.json"), JSON.generate(
      "operation_id" => ID, "status" => "PREPARED", "qualified_cases" => 1,
      "workload_id" => WORKLOAD,
      "plan" => {"path" => plan, "sha256" => Digest::SHA256.file(plan).hexdigest}
    ))
    File.write(plan, "changed frozen plan\n")

    error = assert_raises(AdventureFinderWorkspace::IngestReleaseContinuation::Failure) do
      @service.prepare(operation_id: ID)
    end
    assert_equal "STALE_WORKLOAD_BINDING", error.code
    assert_empty @calls
    refute Dir.exist?(File.join(@front, "output", "ingest-releases"))
  end
end
