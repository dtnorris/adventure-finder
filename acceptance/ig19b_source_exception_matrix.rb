# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"

class Ig19bSourceExceptionMatrixTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SOURCE_ACCEPTANCE = "test/integration/ig07c_source_exception_recovery_acceptance_test.rb"
  PIPELINE_ROOT = ENV.fetch(
    "AF_IG19B_PIPELINE_SOURCE_ROOT",
    File.join(ENV.fetch("AF_PROJECT_ROOT", "/Users/davidnorris/code/adventure-finder-components"),
              "af-data-pipeline")
  )

  MATRIX = [
    {
      id: "clean-control",
      test: "test_clean_actual_seam_reaches_boundary_review_and_repeat_is_no_write",
      precondition: "accepted converter receipt and unambiguous operation intent",
      gate: "BOUNDARY_EDITORIAL_REVIEW",
      allowed: "operation references and pipeline-owned source artifacts",
      forbidden: "boundary decisions, Adventure IDs, scoring, promotion",
      preserved: "operation/source/base identity and all completed artifacts",
      next_action: "complete boundary editorial review"
    },
    {
      id: "page-ocr-review",
      test: "test_page_review_receipt_stops_before_source_progression_with_pipeline_guidance",
      precondition: "converter reports unresolved page evidence",
      gate: "NEEDS_PAGE_REVIEW",
      allowed: "converter receipt only",
      forbidden: "source progression and semantic page repair",
      preserved: "declared source intent and input PDF",
      next_action: "resolve every flagged converter page"
    },
    {
      id: "conversion-not-ready",
      test: "test_non_ready_conversion_stops_without_routine_source_qa_or_later_execution",
      precondition: "conversion receipt is not downstream ready",
      gate: "BLOCKED_CONVERSION",
      allowed: "conversion evidence only",
      forbidden: "canonical placement and later transitions",
      preserved: "operation and input evidence",
      next_action: "resolve conversion or structural validation"
    },
    {
      id: "unknown-page-map",
      test: "test_page_mapping_exception_repeats_the_same_focused_gate_without_editorial_work",
      precondition: "canonical Markdown lacks an authoritative printed-page mapping",
      gate: "NEEDS_SOURCE_QA_REVIEW",
      allowed: "validated upstream source artifacts",
      forbidden: "editorial workspace and guessed pagination",
      preserved: "source intake, dossier, operation, and replay hashes",
      next_action: "review the unknown or ambiguous page mapping"
    },
    {
      id: "canonical-hash-conflict",
      test: "test_conflicting_canonical_markdown_is_a_focused_refusal",
      precondition: "canonical destination already contains different bytes",
      gate: "INVALID_CONTINUATION_EVIDENCE",
      allowed: "diagnostic evidence",
      forbidden: "overwrite or provenance rewrite",
      preserved: "pre-existing canonical bytes",
      next_action: "resolve the canonical destination conflict"
    },
    {
      id: "registry-invalid-or-missing",
      test: "test_missing_and_invalid_registries_stop_before_intake_binding",
      precondition: "registry is absent or fails its public schema",
      gate: "TRANSITION_COMMAND_FAILED",
      allowed: "validated conversion placement",
      forbidden: "source identity binding",
      preserved: "canonical and operation evidence",
      next_action: "restore a valid source registry"
    },
    {
      id: "identity-or-segment-conflict",
      test: "test_conflicting_identity_and_segmented_registration_require_operator_resolution",
      precondition: "registry identity conflicts or requires segmented registration",
      gate: "COMPONENT_ARTIFACT_CONFLICT or NEEDS_MANUAL_SOURCE_REGISTRATION",
      allowed: "focused conflict evidence",
      forbidden: "identity or segment inference",
      preserved: "operation choices and source bytes",
      next_action: "resolve identity or register segments explicitly"
    },
    {
      id: "zero-exit-missing-output",
      test: "test_zero_exit_with_missing_declared_output_stops_immediately",
      precondition: "component exits zero but omits its declared output",
      gate: "SOURCE_PROGRESSION_PROTOCOL_ERROR",
      allowed: "protocol diagnostic",
      forbidden: "later transition or recovery inference",
      preserved: "operation and input evidence",
      next_action: "repair the owning producer"
    },
    {
      id: "changed-bound-provenance",
      test: "test_changed_bound_artifact_and_source_intent_fail_before_later_transition",
      precondition: "bound pipeline evidence or immutable source intent changes",
      gate: "STALE_INPUT or CORRUPT_EVIDENCE",
      allowed: "stale/corrupt diagnostic",
      forbidden: "automatic rebind or source replacement",
      preserved: "still-valid canonical bytes and completed work",
      next_action: "restore or explicitly re-authorize through the owner"
    },
    {
      id: "public-correction-resume",
      test: "test_public_registration_correction_revalidates_and_preserves_upstream_work",
      precondition: "the owning public registry seam receives an explicit correction",
      gate: "BOUNDARY_EDITORIAL_REVIEW",
      allowed: "registry correction and resumed validation",
      forbidden: "duplicate placement or fabricated approval",
      preserved: "operation identity and valid upstream hashes",
      next_action: "complete boundary editorial review"
    }
  ].freeze

  def test_source_exception_matrix_executes_the_landed_public_driver_proof
    result = run_group(SOURCE_ACCEPTANCE, MATRIX.map { |row| row.fetch(:test) })

    assert result.fetch(:status).success?, result.fetch(:output)
    assert_match(/#{MATRIX.length} runs,/, result.fetch(:output))
    assert_match(/0 failures, 0 errors/, result.fetch(:output))
    assert_equal MATRIX.length, MATRIX.map { |row| row.fetch(:id) }.uniq.length
    MATRIX.each do |row|
      %i[precondition gate allowed forbidden preserved next_action].each do |field|
        refute_empty row.fetch(field), "#{row.fetch(:id)} missing #{field}"
      end
    end
  end

  private

  def run_group(file, tests)
    pattern = "/\\A(?:#{tests.join('|')})\\z/"
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    output, status = Open3.capture2e(
      {"AF_IG07C_PIPELINE_SOURCE_ROOT" => PIPELINE_ROOT},
      RbConfig.ruby, "-Ilib", "-Itest", file, "--name", pattern,
      chdir: ROOT
    )
    puts JSON.generate(file:, tests:, cwd: ROOT,
      wall_seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, exitstatus: status.exitstatus)
    puts output
    {output:, status:}
  end
end
