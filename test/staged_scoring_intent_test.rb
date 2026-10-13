# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"
require "adventure_finder_staged_scoring_intent"

class StagedScoringIntentTest < Minitest::Test
  Store = AdventureFinderWorkspace::StagedScoringIntentStore
  OperationStore = AdventureFinderWorkspace::IngestOperationStore
  ID = "11111111-1111-4111-8111-111111111111"
  NOW = Time.iso8601("2026-10-08T20:00:00Z")

  def setup
    @dir = Dir.mktmpdir("ig14a-intent")
    @front = directory("front")
    @input_root = directory("input")
    @catalog_root = directory("catalog")
    @pdf = write(File.join(@input_root, "book.pdf"), "%PDF synthetic\n")
    @catalog = write(File.join(@catalog_root, "5e_Adventure_Master_Catalog_1.0.xlsx"), "synthetic\n")
    @policy = write(File.join(@dir, "policy.json"), JSON.generate(policy_document))
    @operations = OperationStore.new(
      root: File.join(@front, "operations"), roots: {"input" => @input_root, "catalog" => @catalog_root}
    )
    create_operation
    @store = Store.new(
      root: File.join(@front, "intents"), operation_store: @operations,
      policy_path: @policy, clock: -> { NOW }
    )
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_affirmative_choice_publishes_exact_pipeline_intent_and_reuses_it_on_resume
    decision = @store.capture!(
      operation_id: ID, choice: "prepare", selected_by: "David", interaction: "ingest_start"
    )
    intent = @store.intent!(ID)

    assert_equal "prepare", decision.fetch("choice")
    assert_equal "adventurefinder-staged-scoring-intent/v0.1", intent.fetch("schema_version")
    assert_equal "ingest-#{ID}", intent.fetch("workload_id")
    assert_equal "operation-approved-new-records", intent.fetch("scope")
    assert_equal "ingest_start", intent.fetch("interaction")
    assert_equal Store.digest(intent.except("intent_id")), intent.fetch("intent_id")
    assert_equal Digest::SHA256.file(@policy).hexdigest, intent.dig("policy", "sha256")
    assert_equal Digest::SHA256.file(@catalog).hexdigest, intent.dig("base_amc", "sha256")

    before = File.binread(@store.intent_path(ID))
    replay = @store.capture!(
      operation_id: ID, choice: "prepare", selected_by: "David", interaction: "post_boundary_resume"
    )
    assert_equal decision, replay
    assert_equal before, File.binread(@store.intent_path(ID))
  end

  def test_missing_declined_changed_and_inert_policy_choices_fail_closed
    missing = assert_raises(Store::Failure) { @store.intent!(ID) }
    assert_equal "MISSING_SCORING_INTENT", missing.code

    @store.capture!(
      operation_id: ID, choice: "decline", selected_by: "David", interaction: "post_boundary_resume"
    )
    declined = assert_raises(Store::Failure) { @store.intent!(ID) }
    assert_equal "SCORING_DECLINED", declined.code
    conflict = assert_raises(Store::Failure) do
      @store.capture!(
        operation_id: ID, choice: "prepare", selected_by: "David", interaction: "post_boundary_resume"
      )
    end
    assert_equal "SCORING_INTENT_CONFLICT", conflict.code

    other = "22222222-2222-4222-8222-222222222222"
    create_operation(operation_id: other, policy_sha: "f" * 64)
    mismatch = assert_raises(Store::Failure) do
      @store.capture!(
        operation_id: other, choice: "prepare", selected_by: "David", interaction: "ingest_start"
      )
    end
    assert_equal "SCORING_POLICY_MISMATCH", mismatch.code
    refute @store.intent_path(other).exist?
  end

  def test_recorded_intent_rejects_changed_policy_bytes
    @store.capture!(
      operation_id: ID, choice: "prepare", selected_by: "David", interaction: "ingest_start"
    )
    File.binwrite(@policy, JSON.pretty_generate(policy_document) + "\n")

    error = assert_raises(Store::Failure) { @store.intent!(ID) }

    assert_equal "SCORING_POLICY_MISMATCH", error.code
  end

  def test_deferred_choice_rejects_conflicting_selected_values_before_publication
    other = "22222222-2222-4222-8222-222222222222"
    create_operation(operation_id: other, policy_values: {"selection" => "different-selection"})
    error = assert_raises(Store::Failure) do
      @store.capture!(
        operation_id: other, choice: "prepare", selected_by: "David", interaction: "post_boundary_resume"
      )
    end

    assert_equal "SCORING_POLICY_MISMATCH", error.code
    assert_equal({"selection" => "different-selection"},
                 @operations.validate!(other).dig("policy", "selected_values"))
    refute @store.intent_path(other).exist?
  end

  def test_revoked_policy_with_matching_recorded_digest_is_not_supported
    other = "22222222-2222-4222-8222-222222222222"
    File.binwrite(@policy, JSON.generate(policy_document.merge("selection" => "revoked")))
    create_operation(operation_id: other)
    error = assert_raises(Store::Failure) do
      @store.capture!(
        operation_id: other, choice: "prepare", selected_by: "David", interaction: "post_boundary_resume"
      )
    end

    assert_equal "SCORING_POLICY_MISMATCH", error.code
    refute @store.intent_path(other).exist?
  end

  private

  def create_operation(operation_id: ID, policy_sha: Digest::SHA256.file(@policy).hexdigest,
                       policy_values: {"selection" => "afw-qualified-default"})
    selected_at = NOW.strftime("%Y-%m-%dT%H:%M:%SZ")
    choice = ->(value) { {"value" => value, "selected_by" => "David", "selected_at" => selected_at} }
    @operations.create(
      operation_id:, created_at: selected_at,
      input_locator: {"root" => "input", "path" => "book.pdf"},
      base_catalog_locator: {"root" => "catalog", "path" => File.basename(@catalog)},
      catalog_selected_by: "David", catalog_selected_at: selected_at,
      source_declaration: {
        "source_id" => choice.call("Fixture Source"),
        "edition" => choice.call("First printing"),
        "pagination_authority" => choice.call("Printed labels"),
        "publisher" => choice.call("Fixture Publisher")
      },
      policy: {
        "policy_id" => "approved-new-records", "policy_version" => "1",
        "definition_sha256" => policy_sha,
        "selected_values" => policy_values,
        "selected_by" => "David", "selected_at" => selected_at
      }
    )
  end

  def policy_document
    {
      "schema_version" => "af-staged-scoring-input-policy/v0.1",
      "policy_id" => "approved-new-records",
      "policy_version" => "1",
      "scope" => "operation-approved-new-records",
      "selection" => "afw-qualified-default",
      "permissions" => %w[scoring_input workload_preparation]
    }
  end

  def directory(name)
    path = File.join(@dir, name)
    FileUtils.mkdir_p(path)
    path
  end

  def write(path, bytes)
    File.binwrite(path, bytes)
    path
  end
end
