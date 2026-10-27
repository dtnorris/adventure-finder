# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"
require "adventure_finder_ingest_release_continuation"
require "adventure_finder_staged_workload_preparation"

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

  # Refuses absent, foreign-operation and changed-store locators before any
  # WLO/AFW publication. The original private binding can be read again intact.
  def test_private_store_binding_refusals_precede_owner_commands
    preparation = File.join(@front, "output/staged-workload-preparations/v0.1", ID)
    FileUtils.mkdir_p(preparation)
    File.write(File.join(preparation, "result.json"), JSON.generate(
      "operation_id" => ID, "status" => "PREPARED", "qualified_cases" => 1, "workload_id" => WORKLOAD
    ))
    selected = File.join(@root, "private-data")
    # Exercise binding refusals with valid code/private roots; owner calls remain forbidden.
    FileUtils.mkdir_p([selected, File.join(@pipeline, "bin")])
    command = File.join(@pipeline, "bin", "af-data")
    File.write(command, "#!/bin/sh\nexit 99\n")
    FileUtils.chmod(0o755, command)
    service = AdventureFinderWorkspace::IngestReleaseContinuation.new(
      front_door_root: @front, project_root: @project, pipeline_root: @pipeline,
      catalog_root: @catalog, env: {"AF_DATA_PIPELINE_DATA_ROOT" => selected},
      runner: ->(*args, **kwargs) { @calls << [args, kwargs]; raise "owner command must not run" }
    )
    binding_path = File.join(preparation, "authority-store.json")
    binding = {"operation_id" => ID, "store_root" => File.join(selected, "output/staged-scoring-authority/v0.1")}
    [nil, binding.merge("operation_id" => "another-operation"), binding.merge("store_root" => @pipeline)].each do |document|
      File.write(binding_path, JSON.generate(document)) if document
      error = assert_raises(AdventureFinderWorkspace::IngestReleaseContinuation::Failure) do
        service.prepare(operation_id: ID)
      end
      assert_equal "RELEASE_INPUT_CONFLICT", error.code
      assert_empty @calls
    end
    File.write(binding_path, JSON.generate(binding))
    assert_equal binding.fetch("store_root"), service.send(:authority_store, Pathname(preparation), ID)
    File.symlink(binding_path, File.join(preparation, "saved-link"))
    File.rename(File.join(preparation, "saved-link"), binding_path)
    assert_raises(AdventureFinderWorkspace::IngestReleaseContinuation::Failure) do
      service.prepare(operation_id: ID)
    end
    assert_empty @calls
  end
end

# Exercises the real AFDP issue/validate process at the two V2 store-binding
# seams. Synthetic editorial evidence comes from the owner's independent
# fixture; this test never runs standing production policy or catalog adoption.
class PrivateStagedScoringAuthoritySeamTest < Minitest::Test
  ID = IngestReleaseContinuationTest::ID
  Response = Struct.new(:stdout, :stderr, :status)

  # Loads owner fixtures only from a qualified disposable source copy. Missing
  # components skip ordinary standalone runs; acceptance must enable this seam.
  def setup
    source = ENV["AF_DATA_PIPELINE_ROOT"]
    skip "qualified disposable pipeline source is unavailable" unless source
    scratch = File.realpath(ENV.fetch("TMPDIR"))
    raise "owner source must be a disposable copy" unless File.realpath(source).start_with?(scratch + "/")
    require File.join(source, "lib/af_data_pipeline")
    require File.join(source, "test/support/staged_scoring_fixture")
    self.class.include StagedScoringFixture unless self.class < StagedScoringFixture
    @root = Dir.mktmpdir("private-authority-seam-")
    @pipeline = File.join(@root, "code")
    FileUtils.cp_r(source, @pipeline)
    @front = File.join(@root, "private", "front")
    @evidence_root = File.join(@root, "evidence")
    FileUtils.mkdir_p([@front, @evidence_root])
    @evidence = build_authority_fixture(@evidence_root, cache_namespace: :private_authority_seam)
    @state = File.join(@evidence_root, "PROJECT_STATE.yml")
  end

  # Removes only this test's disposable world; owner source copies are unchanged.
  def teardown
    FileUtils.remove_entry(@root) if @root
  end

  # Proves both layouts use one owner publication and an exact no-write fresh
  # process replay. Damaged publication/evidence cases are restored before a
  # final positive readback; a retry cannot issue or repair missing authority.
  def test_real_authority_private_and_legacy_replay_and_refusals
    [{"AF_DATA_PIPELINE_DATA_ROOT" => File.join(@root, "private")}, {}].each do |environment|
      front = File.join(@front, environment.empty? ? "legacy" : "dual")
      calls = []
      runner = Object.new
      # Adapt only the CLI's explicit synthetic mode, retaining real owner code,
      # stdout, stderr and process status; no expected authority is fabricated.
      runner.define_singleton_method(:capture) do |child_env, *argv, chdir:|
        calls << argv
        Response.new(*Open3.capture3(child_env, *argv, "--synthetic", chdir:, binmode: true))
      end
      service = AdventureFinderWorkspace::StagedWorkloadPreparation.new(
        front_door_root: front, project_root: @root, pipeline_root: @pipeline,
        afw_root: @root, scorer_root: @root, source_root: @evidence_root,
        catalog_root: @evidence_root, operation_store: nil, intent_store: nil,
        authorization_store: nil, routing: nil, runner:, env: environment
      )
      directory = Pathname(front).join("output/staged-workload-preparations/v0.1", ID)
      store = service.send(:authority_root).to_s
      documents = {
        "operation-input.json" => JSON.parse(File.binread(@evidence.fetch(:operation_input_path))),
        "successor-authorization.json" => JSON.parse(File.binread(@evidence.fetch(:successor_authorization_path))),
        "authority-inputs.json" => {"schema_version" => "af-staged-scoring-evidence-locators/v0.1", "evidence" => @evidence.transform_keys(&:to_s)},
        "authority-store.json" => {"operation_id" => ID, "store_root" => store}
      }
      action = service.send(:persist_preparation_inputs!, ID, documents)
      assert_equal "issue", action
      issued = service.send(:issue_authority!, ID, @state, action:)
      assert_equal ID, issued.dig("authority", "operation", "operation_id")
      assert_equal "synthetic", issued.dig("authority", "mode")
      refute issued.fetch("catalog_adoption_authorized")
      continuation = AdventureFinderWorkspace::IngestReleaseContinuation.new(
        front_door_root: front, project_root: @root, pipeline_root: @pipeline,
        catalog_root: @evidence_root, env: environment
      )
      assert_equal store, continuation.send(:authority_store, directory, ID)
      authority_path = File.join(store, ID, "authority.json")
      publication_path = File.join(store, ID, "publication.json")
      retained = authority_inventory(store)
      replay = service.send(:persist_preparation_inputs!, ID, documents)
      assert_equal "validate", replay
      assert_equal issued, service.send(:issue_authority!, ID, @state, action: replay)
      assert_equal retained, authority_inventory(store)
      damaged_paths = environment.empty? ? [authority_path] :
        [authority_path, publication_path, @evidence.fetch(:approval_path), @state]
      damaged_paths.each do |path|
        bytes = File.binread(path)
        mode = File.stat(path).mode & 0o777
        replacements = [nil, "corrupt\n"]
        replacements << JSON.generate("authority_id" => "a" * 64) if path == publication_path
        replacements.each do |replacement|
          replacement ? File.binwrite(path, replacement) : File.unlink(path)
          before = authority_inventory(store)
          error = assert_raises(AdventureFinderWorkspace::StagedWorkloadPreparation::Failure) do
            service.send(:issue_authority!, ID, @state, action: replay)
          end
          assert_equal "AUTHORITY_REJECTED", error.code
          assert_equal before, authority_inventory(store)
          File.binwrite(path, bytes)
          File.chmod(mode, path)
        end
      end
      unless environment.empty?
        selected = environment.fetch("AF_DATA_PIPELINE_DATA_ROOT")
        link = File.join(@root, "linked-data")
        File.symlink(selected, link)
        ["", File.join(@root, "missing-data"), @pipeline, link].each do |invalid|
          environment["AF_DATA_PIPELINE_DATA_ROOT"] = invalid
          assert_raises(AdventureFinderWorkspace::StagedWorkloadPreparation::Failure) do
            service.send(:issue_authority!, ID, @state, action: replay)
          end
          assert_equal retained, authority_inventory(store)
        end
        environment["AF_DATA_PIPELINE_DATA_ROOT"] = selected
      end
      assert_equal issued, service.send(:issue_authority!, ID, @state, action: replay)
      assert_equal retained, authority_inventory(store)
      assert_equal 1, calls.count { |argv| argv[1] == "issue" }
      assert_equal [ID, "#{ID}.lock"], Dir.children(store).sort
      refute Dir.exist?(File.join(@pipeline, "output/staged-scoring-authority")) unless environment.empty?
    end
  end

  # Returns file bytes and modes to detect persisted replay changes.
  # Symlinks/special files raise rather than escaping the disposable store.
  def authority_inventory(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.to_h do |path|
      raise "unsafe authority entry" if File.symlink?(path) || (!File.file?(path) && !File.directory?(path))
      [path.delete_prefix(root + "/"), File.file?(path) ? [File.binread(path), File.stat(path).mode] : :directory]
    end
  end
end
