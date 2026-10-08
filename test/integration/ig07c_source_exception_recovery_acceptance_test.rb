# frozen_string_literal: true

require "minitest/autorun"
require_relative "../support/ig07c_source_acceptance_fixture"

class Ig07cSourceExceptionRecoveryAcceptanceTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path("../..", __dir__)
  PIPELINE_SOURCE_ROOT = ENV.fetch(
    "AF_IG07C_PIPELINE_SOURCE_ROOT",
    File.join(
      ENV.fetch("AF_PROJECT_ROOT", "/Users/davidnorris/code/adventure-finder-components"),
      "af-data-pipeline"
    )
  )

  def setup
    @fixture = Ig07cSourceAcceptance::Fixture.new(
      repository_root: ROOT,
      pipeline_source_root: PIPELINE_SOURCE_ROOT
    )
    capture_owned_inputs
  end

  def teardown
    @fixture&.close
  end

  def test_clean_actual_seam_reaches_boundary_review_and_repeat_is_no_write
    stdout, stderr, status = @fixture.start

    assert status.success?, stderr
    assert_includes stdout, "Gate: BOUNDARY_EDITORIAL_REVIEW"
    assert_includes stdout, "Review workspace: #{@fixture.editorial_dir}"
    assert_equal 4, @fixture.latest_revision
    document = @fixture.revision_document
    assert_equal Ig07cSourceAcceptance::Fixture::OPERATION_ID, document.fetch("operation_id")
    assert_equal Ig07cSourceAcceptance::Fixture::SOURCE_ID,
                 document.dig("source_declaration", "source_id", "value")
    assert_equal Digest::SHA256.file(@fixture.base).hexdigest,
                 document.dig("base_catalog", "content", "sha256")
    assert_equal %w[conversion-receipt.json source_intake.json boundary_dossier.json],
                 @fixture.progress_calls.map { |call| call.fetch("artifact") }
    decisions = YAML.safe_load_file(File.join(@fixture.editorial_dir, "editorial_decisions.yml"))
    assert_empty decisions.fetch("candidates")
    assert_empty @fixture.forbidden_calls
    before = @fixture.operation_snapshot
    calls_before = @fixture.progress_calls

    resumed_out, resumed_err, resumed_status = @fixture.resume

    assert resumed_status.success?, resumed_err
    assert_includes resumed_out, "Gate: BOUNDARY_EDITORIAL_REVIEW"
    assert_equal before, @fixture.operation_snapshot
    assert_equal calls_before, @fixture.progress_calls
    assert_no_fabricated_authority
  end

  def test_page_review_receipt_stops_before_source_progression_with_pipeline_guidance
    stdout, stderr, status = @fixture.start("IG07C_RECEIPT_MODE" => "page_review")

    assert status.success?, stderr
    assert_includes stdout, "Gate: NEEDS_PAGE_REVIEW"
    assert_includes stdout, "Human review:"
    assert_includes stdout, "Resolve every flagged page"
    assert_equal 1, @fixture.latest_revision
    assert_empty @fixture.progress_calls
    refute File.exist?(@fixture.canonical)
    assert_no_fabricated_authority
  end

  def test_non_ready_conversion_stops_without_routine_source_qa_or_later_execution
    stdout, stderr, status = @fixture.start("IG07C_RECEIPT_MODE" => "blocked")

    assert status.success?, stderr
    assert_includes stdout, "Gate: BLOCKED_CONVERSION"
    assert_includes stdout, "Resolve conversion/structural validation"
    assert_equal 1, @fixture.latest_revision
    assert_empty @fixture.progress_calls
    refute File.exist?(@fixture.canonical)
    assert_no_fabricated_authority
  end

  def test_page_mapping_exception_repeats_the_same_focused_gate_without_editorial_work
    stdout, stderr, status = @fixture.start("IG07C_MARKDOWN_MODE" => "unknown_page")

    assert status.success?, stderr
    assert_includes stdout, "Gate: NEEDS_SOURCE_QA_REVIEW"
    assert_includes stdout, "Resolve or explicitly review unknown/ambiguous page mappings"
    assert_equal 3, @fixture.latest_revision
    refute Dir.exist?(@fixture.editorial_dir)
    upstream = @fixture.snapshot(
      @fixture.canonical,
      @fixture.source_intake_path,
      @fixture.source_intake_companion,
      @fixture.dossier_path,
      @fixture.dossier_companion
    )
    operation_before = @fixture.operation_snapshot

    resumed_out, resumed_err, resumed_status = @fixture.resume

    assert resumed_status.success?, resumed_err
    assert_includes resumed_out, "Gate: NEEDS_SOURCE_QA_REVIEW"
    assert_equal upstream, @fixture.snapshot(*upstream.keys)
    assert_equal operation_before, @fixture.operation_snapshot
    refute Dir.exist?(@fixture.editorial_dir)
    assert_empty @fixture.forbidden_calls
    assert_no_fabricated_authority
  end

  def test_conflicting_canonical_markdown_is_a_focused_refusal
    @fixture.precreate_conflicting_canonical
    canonical_before = @fixture.snapshot(@fixture.canonical)

    stdout, _stderr, status = @fixture.start

    assert_refusal stdout, status, "INVALID_CONTINUATION_EVIDENCE"
    assert_includes stdout, "SHA-256 mismatch"
    assert_equal canonical_before, @fixture.snapshot(@fixture.canonical)
    assert_equal 1, @fixture.latest_revision
    assert_equal ["conversion-receipt.json"], @fixture.progress_calls.map { |call| call.fetch("artifact") }
  end

  def test_missing_and_invalid_registries_stop_before_intake_binding
    @fixture.remove_registry
    stdout, _stderr, status = @fixture.start
    assert_refusal stdout, status, "TRANSITION_COMMAND_FAILED"
    assert_includes stdout, "registry"
    assert_equal 1, @fixture.latest_revision
    assert_equal ["conversion-receipt.json"], @fixture.progress_calls.map { |call| call.fetch("artifact") }

    @fixture.close
    @fixture = Ig07cSourceAcceptance::Fixture.new(
      repository_root: ROOT,
      pipeline_source_root: PIPELINE_SOURCE_ROOT
    )
    capture_owned_inputs
    @fixture.write_invalid_registry
    stdout, _stderr, status = @fixture.start
    assert_refusal stdout, status, "TRANSITION_COMMAND_FAILED"
    assert_includes stdout, "schema"
    assert_equal 1, @fixture.latest_revision
    assert_equal ["conversion-receipt.json"], @fixture.progress_calls.map { |call| call.fetch("artifact") }
  end

  def test_conflicting_identity_and_segmented_registration_require_operator_resolution
    @fixture.write_registry(
      "Another Source" => {"file" => File.basename(@fixture.canonical)}
    )
    stdout, _stderr, status = @fixture.start
    assert_refusal stdout, status, "COMPONENT_ARTIFACT_CONFLICT"
    assert_includes stdout, "source identity conflicts with operation input"
    assert_equal 2, @fixture.latest_revision
    assert_empty @fixture.forbidden_calls

    @fixture.close
    @fixture = Ig07cSourceAcceptance::Fixture.new(
      repository_root: ROOT,
      pipeline_source_root: PIPELINE_SOURCE_ROOT
    )
    capture_owned_inputs
    @fixture.write_registry(
      Ig07cSourceAcceptance::Fixture::SOURCE_ID => {
        "segments" => [
          {"start_page" => 1, "end_page" => 1, "file" => File.basename(@fixture.canonical)}
        ]
      }
    )
    stdout, _stderr, status = @fixture.start
    assert_refusal stdout, status, "NEEDS_MANUAL_SOURCE_REGISTRATION"
    assert_includes stdout, "unsegmented, offset-free single-file mapping"
    assert_equal 2, @fixture.latest_revision
  end

  def test_zero_exit_with_missing_declared_output_stops_immediately
    stdout, _stderr, status = @fixture.start("IG07C_PROGRESS_MODE" => "zero_missing")

    assert_refusal stdout, status, "SOURCE_PROGRESSION_PROTOCOL_ERROR"
    assert_includes stdout, "output is missing"
    assert_includes stdout, "zero child exit is not recovery authority"
    assert_equal 1, @fixture.latest_revision
    assert_equal ["conversion-receipt.json"], @fixture.progress_calls.map { |call| call.fetch("artifact") }
    refute File.exist?(@fixture.canonical)
  end

  def test_changed_bound_artifact_and_source_intent_fail_before_later_transition
    _stdout, stderr, status = @fixture.start("IG07C_PROGRESS_MODE" => "pause_intake")
    assert status.success?, stderr
    assert_equal 2, @fixture.latest_revision
    upstream = @fixture.snapshot(@fixture.canonical, @fixture.source_intake_path)
    calls_before = @fixture.progress_calls.length
    @fixture.corrupt_bound_source_intake

    stdout, _stderr, status = @fixture.resume

    assert_refusal stdout, status, "STALE_INPUT"
    assert_equal calls_before, @fixture.progress_calls.length
    assert_equal 2, @fixture.latest_revision
    assert_equal upstream.fetch(@fixture.canonical), Digest::SHA256.file(@fixture.canonical).hexdigest

    @fixture.close
    @fixture = Ig07cSourceAcceptance::Fixture.new(
      repository_root: ROOT,
      pipeline_source_root: PIPELINE_SOURCE_ROOT
    )
    capture_owned_inputs
    _stdout, stderr, status = @fixture.start("IG07C_PROGRESS_MODE" => "pause_intake")
    assert status.success?, stderr
    calls_before = @fixture.progress_calls.length
    @fixture.change_bound_source_intent
    stdout, _stderr, status = @fixture.resume
    assert_refusal stdout, status, "CORRUPT_EVIDENCE"
    assert_equal calls_before, @fixture.progress_calls.length
    assert_equal 2, @fixture.latest_revision
  end

  def test_public_registration_correction_revalidates_and_preserves_upstream_work
    stdout, stderr, status = @fixture.start("IG07C_PROGRESS_MODE" => "pause_intake")
    assert status.success?, stderr
    assert_includes stdout, "Gate: NEEDS_SOURCE_REGISTRY_REVIEW"
    assert_includes stdout, "af-source-register"
    assert_equal 2, @fixture.latest_revision
    upstream = @fixture.snapshot(
      @fixture.canonical,
      @fixture.source_intake_path,
      @fixture.source_intake_companion
    )
    operation_before = @fixture.operation_snapshot

    unchanged_out, unchanged_err, unchanged_status = @fixture.resume(
      "IG07C_PROGRESS_MODE" => "pause_intake"
    )
    assert unchanged_status.success?, unchanged_err
    assert_includes unchanged_out, "Gate: NEEDS_SOURCE_REGISTRY_REVIEW"
    assert_equal operation_before, @fixture.operation_snapshot
    assert_equal upstream, @fixture.snapshot(*upstream.keys)

    register_out, register_err, register_status = @fixture.register_source
    assert register_status.success?, [register_out, register_err].join

    resumed_out, resumed_err, resumed_status = @fixture.resume

    assert resumed_status.success?, resumed_err
    assert_includes resumed_out, "Gate: BOUNDARY_EDITORIAL_REVIEW"
    assert_equal 4, @fixture.latest_revision
    assert_equal upstream, @fixture.snapshot(*upstream.keys)
    registry = YAML.safe_load_file(@fixture.registry)
    assert_equal({"file" => File.basename(@fixture.canonical)},
                 registry.dig("sources", Ig07cSourceAcceptance::Fixture::SOURCE_ID))
    assert_empty @fixture.forbidden_calls
    assert_no_fabricated_authority
  end

  private

  def assert_refusal(stdout, status, code)
    assert_equal 2, status.exitstatus, stdout
    assert_includes stdout, "Gate: #{code}"
    assert_includes stdout, "Diagnostic: #{code}:"
    assert_includes stdout, "Next action:"
    assert_no_fabricated_authority
  end

  def capture_owned_inputs
    @owned_inputs = @fixture.snapshot(@fixture.pdf, @fixture.base, @fixture.policy)
  end

  def assert_no_fabricated_authority
    initial = @fixture.revision_document(0)
    expected = {
      "source_id" => Ig07cSourceAcceptance::Fixture::SOURCE_ID,
      "edition" => "Fixture edition",
      "pagination_authority" => "Explicit printed labels",
      "publisher" => "Fixture Publisher"
    }
    assert_equal expected,
                 initial.fetch("source_declaration").transform_values { |choice| choice.fetch("value") }
    assert initial.fetch("future_choices").values.all?(&:nil?)
    assert_equal @owned_inputs, @fixture.snapshot(*@owned_inputs.keys)
    assert_empty @fixture.forbidden_calls
  end
end
