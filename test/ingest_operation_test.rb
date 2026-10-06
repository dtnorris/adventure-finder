# frozen_string_literal: true

require "minitest/autorun"
require "adventure_finder_ingest_operation"

class IngestOperationTest < Minitest::Test
  Contract = AdventureFinderWorkspace::IngestOperation
  Error = AdventureFinderWorkspace::Error
  NOW = "2026-10-06T22:00:00Z"

  def test_initial_operation_is_valid_without_artifacts_or_inferred_semantics
    doc = initial
    original = copy(doc)
    assert Contract.validate!(doc)
    assert_equal original, doc
    assert_empty doc["artifacts"]
    assert_nil doc["policy"]
    assert doc["source_declaration"].values.all?(&:nil?)
    assert doc["future_choices"].values.all?(&:nil?)
    assert_nil doc["coordination"]["route_observation"]
  end

  def test_bound_artifact_and_observation_example
    doc = bound
    assert Contract.validate!(doc)
    assert Contract.validate_revision!(initial, doc)
    assert_equal "pdf-to-llm-md-converter", doc["artifacts"][0]["owner"]
    assert_equal ["input"], doc["artifacts"][0]["inputs"]
    assert doc["future_choices"].values.all?(&:nil?)
  end

  def test_exact_replay_and_sorted_key_digest
    doc = bound
    assert Contract.validate_revision!(doc, copy(doc))
    assert_equal Contract.digest(doc), Contract.digest(doc.to_a.reverse.to_h)
  end

  def test_numeric_policy_representation_cannot_bypass_replay_or_binding
    doc = initial
    doc["policy"] = policy
    doc["policy"]["selected_values"]["threshold"] = 1
    changed = copy(doc)
    changed["policy"]["selected_values"]["threshold"] = 1.0
    refute_equal Contract.digest(doc), Contract.digest(changed)
    assert_raises(Error) { Contract.validate_revision!(doc, changed) }
    changed = advance(doc)
    changed["policy"]["selected_values"]["threshold"] = 1.0
    assert_raises(Error) { Contract.validate_revision!(doc, changed) }
  end

  def test_missing_unknown_and_malformed_identity_fields_fail_closed
    mutations = [
      ->(d) { d.delete("operation_id") },
      ->(d) { d["contract_version"] = "adventurefinder-ingest-operation/v9" },
      ->(d) { d["operation_id"] = "source-from-filename" },
      ->(d) { d["operation_id"] = nil },
      ->(d) { d["created_at"] = "2026-02-30T22:00:00Z" },
      ->(d) { d["input"]["content"]["sha256"] = "A" * 64 },
      ->(d) { d["input"]["content"]["bytes"] = 0 },
      ->(d) { d["source_declaration"].delete("publisher") },
      ->(d) { d["source_declaration"]["source_id"] = choice("") },
      ->(d) { d["base_catalog"] = nil },
      ->(d) { d["execute"] = true },
      ->(d) { d["revision"] = -1 },
      ->(d) { d["previous_revision_sha256"] = "a" * 64 }
    ]
    mutations.each do |mutate|
      doc = initial
      mutate.call(doc)
      assert_raises(Error) { Contract.validate!(doc) }
    end
  end

  def test_unsafe_or_implicit_locator_roots_are_rejected
    ["/tmp/book.pdf", "../book.pdf", "dir/../book.pdf", "dir//book.pdf", "./book.pdf",
     "dir/", "C:\\book.pdf", "book\n.pdf"].each do |path|
      doc = initial
      doc["input"]["content"]["locator"]["path"] = path
      assert_raises(Error) { Contract.validate!(doc) }
    end
    doc = initial
    doc["input"]["content"]["locator"]["root"] = "guess-from-cwd"
    assert_raises(Error) { Contract.validate!(doc) }
  end

  def test_explicit_choices_bind_once_without_replacing_identity
    first = initial
    selected = advance(first)
    selected["source_declaration"]["source_id"] = choice("fixture-source")
    selected["source_declaration"]["edition"] = choice("operator-declared edition")
    selected["source_declaration"]["pagination_authority"] = choice("printed folios")
    selected["source_declaration"]["publisher"] = choice("operator-declared publisher")
    assert Contract.validate_revision!(first, selected)
    Contract::SOURCE_CHOICES.each do |key|
      [nil, choice("replacement")].each do |value|
        changed = advance(selected)
        changed["source_declaration"][key] = value
        assert_raises(Error) { Contract.validate_revision!(selected, changed) }
      end
    end
    assert_equal first["operation_id"], selected["operation_id"]
  end

  def test_future_choices_cannot_become_independent_coordination_truth
    Contract::FUTURE_CHOICES.each do |key|
      doc = initial
      doc["future_choices"][key] = "inferred choice"
      assert_raises(Error) { Contract.validate!(doc) }
    end
  end

  def test_catalog_head_selection_binds_provenance_not_a_live_pointer
    doc = initial
    doc["base_catalog"]["selection"].merge!(
      "method" => "catalog_head",
      "project_state" => {"contract_version" => "adventurefinder-project-state/v0.2",
                          "content" => content("catalog", "PROJECT_STATE.yml", "c")}
    )
    assert Contract.validate!(doc)
    missing = copy(doc)
    missing["base_catalog"]["selection"]["project_state"] = nil
    assert_raises(Error) { Contract.validate!(missing) }
    wrong_version = copy(doc)
    wrong_version["base_catalog"]["selection"]["project_state"]["contract_version"] = "v9"
    assert_raises(Error) { Contract.validate!(wrong_version) }
    changed_head = advance(doc)
    changed_head["base_catalog"]["content"]["sha256"] = "d" * 64
    assert_raises(Error) { Contract.validate_revision!(doc, changed_head) }
    changed_provenance = advance(doc)
    changed_provenance["base_catalog"]["selection"]["project_state"]["content"]["sha256"] = "d" * 64
    assert_raises(Error) { Contract.validate_revision!(doc, changed_provenance) }
  end

  def test_frozen_identity_cannot_change_even_with_valid_new_revision
    mutations = [
      ->(d) { d["operation_id"] = "dddddddd-dddd-4ddd-8ddd-dddddddddddd" },
      ->(d) { d["created_at"] = "2026-10-07T22:00:00Z" },
      ->(d) { d["input"]["content"]["sha256"] = "d" * 64 },
      ->(d) { d["input"]["content"]["bytes"] += 1 },
      ->(d) { d["base_catalog"]["content"]["sha256"] = "d" * 64 }
    ]
    mutations.each do |mutate|
      changed = advance(initial)
      mutate.call(changed)
      assert_raises(Error) { Contract.validate_revision!(initial, changed) }
    end
  end

  def test_policy_selection_is_versioned_inert_and_bound_once
    doc = advance(initial)
    doc["policy"] = policy
    assert Contract.validate_revision!(initial, doc)
    %w[policy_id policy_version definition_sha256 selected_values].each do |key|
      bad = copy(doc)
      bad["policy"].delete(key)
      assert_raises(Error) { Contract.validate!(bad) }
    end
    replacement = advance(doc)
    replacement["policy"]["selected_values"]["profile"] = "different"
    assert_raises(Error) { Contract.validate_revision!(doc, replacement) }
    removed = advance(doc)
    removed["policy"] = nil
    assert_raises(Error) { Contract.validate_revision!(doc, removed) }
    unauthorized = copy(doc)
    unauthorized["coordination"]["execution_authorized"] = true
    assert_raises(Error) { Contract.validate!(unauthorized) }
    refute Contract.respond_to?(:execute)
    refute Contract.respond_to?(:save)
    refute Contract.respond_to?(:route)
  end

  def test_location_only_change_preserves_identity_but_records_revision
    doc = bound
    relocated = advance(doc)
    relocated["input"]["content"]["locator"]["path"] = "relocated/book.pdf"
    relocated["base_catalog"]["content"]["locator"]["path"] = "archive/catalog.xlsx"
    relocated["artifacts"][0]["content"]["locator"]["path"] = "archive/receipt.json"
    assert Contract.validate_revision!(doc, relocated)
    assert_equal Contract.observation_basis(doc), Contract.observation_basis(relocated)
    refute_equal Contract.digest(doc), Contract.digest(relocated)
  end

  def test_append_only_compatible_artifact_advancement
    doc = bound
    successor = advance(doc)
    successor["artifacts"] << receipt("receipt-2", supersedes: "receipt-1")
    assert Contract.validate_revision!(doc, successor)
    assert_equal 2, successor["artifacts"].length
    conflict = copy(successor)
    conflict["artifacts"][1]["supersedes"] = nil
    assert_raises(Error) { Contract.validate!(conflict) }
  end

  def test_bound_artifacts_cannot_disappear_mutate_or_conflict
    doc = bound
    mutations = [
      ->(d) { d["artifacts"] = [] },
      ->(d) { d["artifacts"][0]["content"]["sha256"] = "e" * 64 },
      ->(d) { d["artifacts"][0]["owner"] = "adventure-finder" },
      ->(d) { d["artifacts"][0]["contract_version"] = "v9" },
      ->(d) { d["artifacts"][0]["inputs"] = ["not-bound"] },
      ->(d) { d["artifacts"] << receipt("receipt-1") }
    ]
    mutations.each do |mutate|
      changed = advance(doc)
      mutate.call(changed)
      assert_raises(Error) { Contract.validate_revision!(doc, changed) }
    end
  end

  def test_each_supported_artifact_version_is_an_explicit_owner_reference
    Contract::ARTIFACTS.each do |kind, (owner, versions)|
      versions.each do |version|
        doc = advance(initial)
        ref = receipt("fixture-#{kind}").merge("kind" => kind, "owner" => owner,
                                               "contract_version" => version)
        doc["artifacts"] << ref
        doc["coordination"]["status"] = "open"
        assert Contract.validate!(doc)
      end
    end
  end

  def test_observations_are_advisory_and_invalidated_by_new_bindings
    doc = bound
    changed = advance(doc)
    changed["coordination"]["route_observation"] = copy(doc["coordination"]["route_observation"])
    changed["source_declaration"]["publisher"] = choice("explicit publisher")
    assert_raises(Error) { Contract.validate_revision!(doc, changed) }
    changed["coordination"]["route_observation"] = nil
    assert Contract.validate_revision!(doc, changed)
    unknown_artifact = copy(doc)
    unknown_artifact["coordination"]["route_observation"]["artifact_id"] = "missing"
    assert_raises(Error) { Contract.validate!(unknown_artifact) }
  end

  def test_new_no_artifact_is_distinct_from_erasing_a_bound_artifact
    assert Contract.validate!(initial)
    missing = advance(bound)
    missing["artifacts"] = []
    missing["coordination"]["status"] = "created"
    assert_raises(Error) { Contract.validate_revision!(bound, missing) }
    paused = advance(bound)
    paused["coordination"]["status"] = "paused"
    assert Contract.validate_revision!(bound, paused)
  end

  def test_wrong_or_skipped_revisions_are_rejected
    ["revision", "previous_revision_sha256"].each do |key|
      bad = bound
      bad[key] = key == "revision" ? 2 : "f" * 64
      assert_raises(Error) { Contract.validate_revision!(initial, bad) }
    end
  end

  def test_closing_is_not_promotion_and_cannot_silently_reopen
    doc = bound
    closed = advance(doc)
    closed["coordination"]["status"] = "closed"
    assert Contract.validate_revision!(doc, closed)
    assert Contract.validate_revision!(closed, copy(closed))
    reopened = advance(closed)
    reopened["coordination"]["status"] = "open"
    assert_raises(Error) { Contract.validate_revision!(closed, reopened) }
  end

  private

  # Synthetic declaration fixtures; no real book, policy or component evidence.
  def initial
    {
      "contract_version" => Contract::VERSION,
      "operation_id" => "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "created_at" => NOW,
      "revision" => 0, "previous_revision_sha256" => nil,
      "input" => {"kind" => "digital_book_pdf", "content" => content("input", "book.pdf", "a")},
      "source_declaration" => Contract::SOURCE_CHOICES.to_h { |key| [key, nil] },
      "base_catalog" => {
        "content" => content("catalog", "catalog.xlsx", "b"),
        "selection" => {"method" => "explicit", "selected_by" => "David", "selected_at" => NOW,
                        "project_state" => nil}
      },
      "policy" => nil, "artifacts" => [],
      "future_choices" => Contract::FUTURE_CHOICES.to_h { |key| [key, nil] },
      "coordination" => {"status" => "created", "route_observation" => nil}
    }
  end

  def bound
    doc = advance(initial)
    doc["artifacts"] << receipt("receipt-1")
    doc["coordination"]["status"] = "open"
    doc["coordination"]["route_observation"] = {
      "artifact_id" => "receipt-1", "router_state" => "NEEDS_PAGE_REVIEW", "observed_at" => NOW,
      "basis_sha256" => Contract.observation_basis(doc)
    }
    doc
  end

  def advance(doc)
    copy(doc).tap do |result|
      result["revision"] += 1
      result["previous_revision_sha256"] = Contract.digest(doc)
      result["coordination"]["route_observation"] = nil
    end
  end

  def content(root, path, digit)
    {"sha256" => digit * 64, "bytes" => 100, "locator" => {"root" => root, "path" => path}}
  end

  def choice(value)
    {"value" => value, "selected_by" => "David", "selected_at" => NOW}
  end

  def policy
    {"policy_id" => "fixture-only", "policy_version" => "v1", "definition_sha256" => "e" * 64,
     "selected_values" => {"profile" => "fixture-only"}, "selected_by" => "David", "selected_at" => NOW}
  end

  def receipt(id, supersedes: nil)
    {"artifact_id" => id, "kind" => "conversion_receipt", "owner" => "pdf-to-llm-md-converter",
     "contract_version" => "pdf-to-llm-md/conversion-receipt/v0.1",
     "content" => content("converter", "build/#{id}.json", supersedes ? "d" : "c"),
     "inputs" => ["input"], "supersedes" => supersedes}
  end

  def copy(doc)
    JSON.parse(JSON.generate(doc))
  end
end
