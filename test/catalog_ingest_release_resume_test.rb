# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../lib/adventure_finder_catalog_ingest"

# Isolate operation-level routing from owner validation. A retained package must
# reach FinalPromotion without rebuilding workloads or standing acceptance.
class CatalogIngestReleaseResumeTest < Minitest::Test
  ID = "77777777-7777-4777-8777-777777777777"

  # Supply validated earlier seams; any accidental preparation call fails.
  class Ingest < AdventureFinderWorkspace::CatalogIngest
    attr_accessor :context

    # Return the selected operation context for this routing unit test.
    def load_context(_operation_id) = context
    # Earlier operation-store validation is outside this routing unit test.
    def store_for(_context) = nil
    # Return a non-rejected public source inspection, without continuation.
    def routing_for(*) = self
    # The source inspection does not require new operator input here.
    def source_continuation_input(*) = {}
    # Supply the already-validated inert scoring intent seam.
    def scoring_intent_store_for(*) = self
    # No scoring decision is made by this invocation.
    def decision(*) = nil
    # Fail if resume attempts to reconstruct any earlier workflow stage.
    def continue_or_route(*) = raise("must not reconstruct a released operation")
  end

  # Create only a routing envelope; FinalPromotion remains the validation owner.
  def setup
    @root = Dir.mktmpdir("ingest-release-resume-")
    @ingest = Ingest.new(front_door_root: @root, project_root: @root, out: StringIO.new)
    @ingest.context = {"operation_id" => ID, "front_door_root" => @root,
                       "project_root" => @root, "pipeline_root" => @root}
    @release = File.join(@root, "output/ingest-releases/v0.1", ID)
    FileUtils.mkdir_p(@release)
    @package = File.join(@release, "package.json")
    File.write(@package, JSON.generate("operation" => {"operation_id" => ID}))
  end

  # Remove only this test's disposable routing files.
  def teardown
    FileUtils.remove_entry(@root)
  end

  # Ready-package resume delegates exactly once without rebuilding work or
  # fabricating a decision. Approval/read-only replay remains owner validated.
  def test_retained_operation_package_delegates_directly_to_final_promotion
    calls = []
    @ingest.define_singleton_method(:final_promotion) do |_context, paths, approver|
      calls << paths.merge(approver:)
      0
    end
    assert_equal 0, @ingest.resume(ID, final_approver: "Fixture Operator")
    assert_equal [{inputs_path: File.join(@release, "package-inputs.json"),
                   package_path: @package, approver: "Fixture Operator"}], calls
    assert_equal 1, Dir.children(@release).length
  end

  # Foreign or malformed release routing must fail before calling the owner.
  def test_foreign_or_malformed_package_never_reaches_final_promotion
    [JSON.generate("operation" => {"operation_id" => "different-operation"}),
     JSON.generate("operation" => []), "{broken", "null"].each do |bytes|
      File.write(@package, bytes)
      error = assert_raises(AdventureFinderWorkspace::CatalogIngest::Failure) do
        @ingest.resume(ID, final_approver: "Fixture Operator")
      end
      assert_equal "FINAL_PROMOTION_REFUSED", error.code
      assert_includes error.message, "retained final package belongs to a different operation" unless bytes == "{broken"
      assert_equal bytes, File.read(@package)
    end
  end

  # A missing package must use normal continuation; no premature approval.
  def test_missing_package_does_not_select_final_promotion
    File.unlink(@package)
    error = assert_raises(RuntimeError) { @ingest.resume(ID, final_approver: "Fixture Operator") }
    assert_equal "must not reconstruct a released operation", error.message
  end

  # A legacy frozen operation cannot acquire a new historical binding on resume.
  def test_missing_historical_manifest_never_falls_back_to_live_state
    context = @ingest.context.merge("catalog_root" => @root)
    continuation = File.join(@root, "output/ingest-boundary-continuations/v0.1", ID)
    FileUtils.mkdir_p(continuation)
    %w[approval.json boundary-freeze.yml].each { |name| File.write(File.join(continuation, name), "retained\n") }
    File.write(File.join(@root, "PROJECT_STATE.yml"), "current live bytes\n")
    error = assert_raises(AdventureFinderWorkspace::CatalogIngest::Failure) do
      @ingest.continued_boundary_paths(context, ID, @root)
    end
    assert_equal "BOUNDARY_NOT_READY", error.code
    assert_includes error.message, "retained historical project state is missing"
    assert_equal "current live bytes\n", File.read(File.join(@root, "PROJECT_STATE.yml"))
  end

  # Historical evidence is write-once; neither conflicting bytes nor a symlink
  # can redirect or overwrite its original catalog-adjacent copy.
  def test_retained_history_refuses_changed_bytes_and_symlinks
    service = AdventureFinderWorkspace::IngestBoundaryContinuation.new(
      store: nil, routing: nil, authorization_store: nil, front_door_root: @root,
      project_root: @root, pipeline_root: @root, source_root: @root, catalog_root: @root
    )
    history = AdventureFinderWorkspace::IngestBoundaryContinuation.historical_project_state_path(
      catalog_root: @root, operation_id: ID
    )
    service.send(:retain_project_state, history, "original history\n")
    error = assert_raises(AdventureFinderWorkspace::IngestBoundaryContinuation::Failure) do
      service.send(:retain_project_state, history, "changed history\n")
    end
    assert_equal "BOUNDARY_CONTINUATION_CONFLICT", error.code
    assert_equal "original history\n", File.read(history)
    File.unlink(history)
    target = File.join(@root, "unrelated.yml")
    File.write(target, "unrelated bytes\n")
    File.symlink(target, history)
    assert_raises(AdventureFinderWorkspace::IngestBoundaryContinuation::Failure) do
      service.send(:retain_project_state, history, "new history\n")
    end
    assert_equal "unrelated bytes\n", File.read(target)
    assert File.symlink?(history)
  end
end
