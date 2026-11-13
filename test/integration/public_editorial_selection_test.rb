# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/adventure_finder_catalog_ingest"
require "stringio"
require_relative "../support/ig07c_source_acceptance_fixture"

# Real AF start/resume subprocesses use real pipeline validators and pinned
# public bytes. Only the existing structural converter fixture replaces input
# production; no provider, model or production catalog is used.
class PublicEditorialSelectionTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  PIPELINE = ENV.fetch("AF_IG07C_PIPELINE_SOURCE_ROOT", File.expand_path("../../../af-data-pipeline", __dir__))
  ID = Ig07cSourceAcceptance::Fixture::OPERATION_ID

  # Build a disposable source journey with an independent copy of real public
  # definitions. Missing owner code or genuine inputs fail setup.
  def setup
    @fixture = Ig07cSourceAcceptance::Fixture.new(repository_root: ROOT, pipeline_source_root: PIPELINE)
  end

  # Remove only this test's generated state after each scenario.
  def teardown
    @fixture&.close
  end

  # Explicit start freezes the owner binding in revision zero and the generated
  # bundle. A higher-numbered document cannot influence pinned selection.
  def test_explicit_start_binds_pinned_identities_and_replays_without_writes
    File.write(File.join(@fixture.spec_root, "Adventure_Boundary_Detection_Specification_ABDS_v99.md"), "decoy\n")
    output, error, status = @fixture.start
    assert status.success?, error
    assert_includes output, "Gate: BOUNDARY_EDITORIAL_REVIEW"
    expected = AfDataPipeline::EditorialSpecifications.bind!(@fixture.spec_root)
    assert_equal expected, @fixture.revision_document(0).fetch("editorial_specifications")
    context = JSON.parse(File.binread(File.join(@fixture.editorial_dir, "editorial_context.json")))
    assert_equal expected, context.fetch("public_specifications")
    assert_equal %w[2.0 1.4], expected.fetch("files").map { |file| file.fetch("version") }
    assert_equal "Draft", expected.fetch("files").first.fetch("status")
    @fixture.progress_calls.each do |call|
      argv = call.fetch("argv")
      assert_equal @fixture.spec_root, argv.fetch(argv.index("--spec-root") + 1)
    end
    snapshot = @fixture.operation_snapshot
    output, error, status = @fixture.resume
    assert status.success?, error
    assert_includes output, "Gate: BOUNDARY_EDITORIAL_REVIEW"
    assert_equal snapshot, @fixture.operation_snapshot
    assert_empty @fixture.forbidden_calls
  end

  # Selection is persisted before a refused initialization. Removing the exact
  # disposable partial publication lets a fresh process continue without a flag.
  def test_unselected_gate_and_resume_selection_survive_failure_before_bundle_creation
    output, error, status = start_unselected
    assert status.success?, error
    assert_includes output, "Gate: NEEDS_EDITORIAL_SPECIFICATIONS"
    assert_includes output, "bin/af-catalog resume #{ID} --spec-root ABSOLUTE_PUBLIC_DIR"
    refute Dir.exist?(@fixture.editorial_dir)
    refute @fixture.revision_document.key?("editorial_specifications")
    FileUtils.mkdir_p(@fixture.editorial_dir)
    partial = File.join(@fixture.editorial_dir, "editorial_context.json")
    File.write(partial, "interrupted publication\n")
    output, _error, status = selected_resume
    refute status.success?, output
    assert_includes output, "PARTIAL_CONTINUATION_OUTPUT"
    assert_equal 4, @fixture.latest_revision
    selected = @fixture.revision_document.fetch("editorial_specifications")
    refute File.exist?(File.join(@fixture.editorial_dir, "editorial_decisions.yml"))
    FileUtils.remove_entry(@fixture.editorial_dir)
    output, error, status = @fixture.resume
    assert status.success?, error
    assert_includes output, "Gate: BOUNDARY_EDITORIAL_REVIEW"
    assert_equal selected, @fixture.revision_document.fetch("editorial_specifications")
    assert_equal 5, @fixture.latest_revision
    snapshot = @fixture.operation_snapshot
    output, error, status = selected_resume
    assert status.success?, error
    assert_includes output, "Gate: BOUNDARY_EDITORIAL_REVIEW"
    assert_equal snapshot, @fixture.operation_snapshot
  end

  # All required definitions refuse when missing or changed, before selection
  # and again on approval. Restoration recovers the same operation and binding;
  # an identical definition set at a different root cannot replace it.
  def test_missing_changed_bytes_and_incompatible_reselection_refuse_then_restore
    output, error, status = start_unselected
    assert status.success?, error
    files = ["documents.json", *AfDataPipeline::EditorialSpecifications::DOCUMENTS.map { |file| file.fetch("filename") }]
    files.each do |filename|
      path = File.join(@fixture.spec_root, filename)
      bytes = File.binread(path)
      File.unlink(path)
      [nil, bytes + "changed\n"].each do |replacement|
        File.binwrite(path, replacement) if replacement
        _output, error, status = selected_resume
        refute status.success?, error
        assert_includes error, "EDITORIAL_SPECIFICATIONS_REFUSED"
        refute Dir.exist?(@fixture.editorial_dir)
        assert_equal 3, @fixture.latest_revision
      end
      File.binwrite(path, bytes)
    end
    output, error, status = selected_resume
    assert status.success?, error
    assert_includes output, "Gate: BOUNDARY_EDITORIAL_REVIEW"
    snapshot = @fixture.operation_snapshot
    files.each do |filename|
      path = File.join(@fixture.spec_root, filename)
      bytes = File.binread(path)
      File.unlink(path)
      [nil, bytes + "changed\n"].each do |replacement|
        File.binwrite(path, replacement) if replacement
        output, error, status = @fixture.run_catalog({}, "resume", ID, "--approve-boundary-by", "Fixture Operator")
        refute status.success?, output + error
        assert_includes output + error, "EDITORIAL_SPECIFICATIONS_REFUSED"
        assert_equal snapshot, @fixture.operation_snapshot
        refute File.exist?(File.join(@fixture.front, "output/ingest-boundary-continuations/v0.1", ID, "approval.json"))
      end
      File.binwrite(path, bytes)
      output, error, status = @fixture.resume
      assert status.success?, error
      assert_includes output, "Gate: BOUNDARY_EDITORIAL_REVIEW"
    end
    alternate = File.join(@fixture.root, "alternate-public")
    FileUtils.cp_r(@fixture.spec_root, alternate)
    _output, error, status = @fixture.run_catalog({}, "resume", ID, "--spec-root", alternate)
    refute status.success?, error
    assert_includes error, "selection is already frozen"
    assert_equal snapshot, @fixture.operation_snapshot
    assert_empty @fixture.forbidden_calls
  end

  # An already initialized historical bundle retains its absent public binding.
  # Normal continuation reuses it, and later selection requires a new operation.
  def test_historical_bundle_replay_keeps_absent_selection
    output, error, status = start_unselected
    assert status.success?, error
    assert_includes output, "Gate: NEEDS_EDITORIAL_SPECIFICATIONS"
    require File.join(PIPELINE, "lib/af_data_pipeline/boundary_editorial")
    AfDataPipeline::BoundaryEditorial.init!(dossier_path: @fixture.dossier_path, output_dir: @fixture.editorial_dir)
    output, error, status = @fixture.resume
    assert status.success?, error
    assert_includes output, "Gate: BOUNDARY_EDITORIAL_REVIEW"
    refute @fixture.revision_document.key?("editorial_specifications")
    snapshot = @fixture.operation_snapshot
    _output, error, status = selected_resume
    refute status.success?, error
    assert_includes error, "selection is already frozen"
    assert_equal snapshot, @fixture.operation_snapshot
    FileUtils.remove_entry(@fixture.spec_root)
    output, error, status = @fixture.resume
    assert status.success?, error
    assert_includes output, "Gate: BOUNDARY_EDITORIAL_REVIEW"
    assert_equal snapshot, @fixture.operation_snapshot
  end

  # Optional bindings participate in document identity and immutable revision
  # validation, while the historical projection remains strict and unchanged.
  def test_durable_binding_cannot_be_removed_or_changed_in_a_later_revision
    output, error, status = @fixture.start
    assert status.success?, error + output
    contract = AdventureFinderWorkspace::IngestOperation
    previous = @fixture.revision_document
    [nil, previous.fetch("editorial_specifications").merge("root" => "/different")].each do |selection|
      changed = Marshal.load(Marshal.dump(previous))
      selection ? changed["editorial_specifications"] = selection : changed.delete("editorial_specifications")
      changed["revision"] += 1
      changed["previous_revision_sha256"] = contract.digest(previous)
      assert_raises(AdventureFinderWorkspace::Error) { contract.validate_revision!(previous, changed) }
      refute_equal contract.digest(previous), contract.digest(changed)
      refute_equal contract.observation_basis(previous), contract.observation_basis(changed)
    end
  end

  # The public in-process API and a later CLI process share the same append-only
  # binding. Owner validation refuses changed metadata, unavailable code and bytes.
  def test_public_resume_api_binds_once_and_owner_validation_fails_closed
    output, error, status = start_unselected
    assert status.success?, error + output
    out = StringIO.new
    service = AdventureFinderWorkspace::CatalogIngest.new(
      front_door_root: @fixture.front, project_root: @fixture.components,
      env: @fixture.send(:environment), out:
    )
    assert_equal 0, service.resume(ID, spec_root: @fixture.spec_root)
    assert_includes out.string, "Gate: BOUNDARY_EDITORIAL_REVIEW"
    before = @fixture.operation_snapshot
    assert_equal 0, service.resume(ID, spec_root: @fixture.spec_root)
    assert_equal before, @fixture.operation_snapshot
    selector = AdventureFinderWorkspace::EditorialSpecificationSelection
    failure = AdventureFinderWorkspace::IngestOperationStore::Failure
    binding = @fixture.revision_document.fetch("editorial_specifications")
    changed = binding.merge("revision" => "0" * 40)
    assert_raises(failure) { selector.validate!(changed, pipeline_root: PIPELINE) }
    assert_raises(failure) { selector.bind!(@fixture.spec_root, pipeline_root: File.join(@fixture.root, "unavailable-pipeline")) }
    assert_raises(failure) { selector.bind!(File.join(@fixture.root, "unavailable-definitions"), pipeline_root: PIPELINE) }
    assert_raises(AdventureFinderWorkspace::Error) { AdventureFinderWorkspace::IngestOperation.validate!(nil) }
    output, error, status = @fixture.resume
    assert status.success?, error
    assert_includes output, "Gate: BOUNDARY_EDITORIAL_REVIEW"
    assert_equal before, @fixture.operation_snapshot
  end

  private

  # Start with the same supported argv while deliberately omitting selection.
  def start_unselected
    argv = @fixture.send(:start_arguments)
    argv.slice!(argv.index("--spec-root"), 2)
    @fixture.run_catalog({}, *argv)
  end

  # Resume in a fresh real CLI process with an explicit public root.
  def selected_resume
    @fixture.run_catalog({}, "resume", ID, "--spec-root", @fixture.spec_root)
  end
end
