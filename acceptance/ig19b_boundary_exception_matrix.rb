# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"

class Ig19bBoundaryExceptionMatrixTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PIPELINE_ROOT = File.expand_path(
    ENV.fetch(
      "AF_IG19B_PIPELINE_SOURCE_ROOT",
      File.join(ENV.fetch("AF_PROJECT_ROOT", "/Users/davidnorris/code/adventure-finder-components"),
                "af-data-pipeline")
    )
  )

  MATRIX = [
    {
      id: "pending-held-ledger",
      file: "test/boundary_editorial_test.rb",
      tests: %w[
        test_import_refuses_pending_or_held_candidates
        test_workspace_foregrounds_explicit_ambiguity_and_retains_complete_inventory
        test_split_is_traceable_and_references_existing_candidates
      ],
      precondition: "candidate remains pending or held",
      gate: "incomplete editorial review",
      allowed: "ledger preservation and diagnostic",
      forbidden: "approval, freeze, IDs, successor",
      preserved: "complete candidate inventory and dispositions",
      next_action: "resolve the named candidate disposition"
    },
    {
      id: "unreviewed-empty-versus-zero-accept",
      file: "test/boundary_editorial_test.rb",
      tests: %w[
        test_approval_refuses_incomplete_or_unreviewed_empty_ledgers_but_allows_reviewed_zero_accept
        test_freeze_approved_preserves_reviewed_zero_accepted_result
      ],
      precondition: "empty, incomplete, unresolved, or fully reviewed zero-accept ledger",
      gate: "approval refusal or explicit validated zero-record freeze",
      allowed: "reviewed zero-record no-op evidence",
      forbidden: "treating empty as approved or inventing an adventure",
      preserved: "review evidence and zero accepted count",
      next_action: "finish review or continue through explicit no-successor semantics"
    },
    {
      id: "approval-input-drift",
      file: "test/boundary_editorial_test.rb",
      tests: %w[
        test_approval_invalidates_for_each_changed_review_or_provenance_input
        test_approval_rejects_malformed_schema_identity_and_changed_registered_segments
        test_approval_fails_closed_when_inputs_change_during_construction
      ],
      precondition: "ledger, dossier, source, registry, base, or approval bytes change",
      gate: "stale, mismatch, or changed-input refusal",
      allowed: "precise changed-input diagnostic",
      forbidden: "approval reuse or provenance rewrite",
      preserved: "original approval lineage and input artifacts",
      next_action: "review and approve the changed evidence explicitly"
    },
    {
      id: "missing-stale-approval",
      file: "test/boundary_editorial_test.rb",
      tests: %w[test_import_refuses_missing_stale_or_legacy_loose_approval_without_publishing],
      precondition: "approval is missing, stale, or a legacy loose assertion",
      gate: "approval validation refusal",
      allowed: "diagnostic only",
      forbidden: "frozen publication and ID allocation",
      preserved: "draft, ledger, and source evidence",
      next_action: "issue a bound approval through the public interface"
    },
    {
      id: "invalid-parent-span-or-freeze",
      file: "test/boundary_editorial_test.rb",
      tests: %w[
        test_approved_freeze_validation_rejects_duplicate_keys_cycles_invalid_spans_and_content_drift
        test_freeze_approved_does_not_publish_when_final_freeze_validation_fails
        test_freeze_approved_removes_its_new_output_if_post_publication_validation_is_interrupted
      ],
      precondition: "duplicate key, parent cycle, invalid span, drift, or interrupted final validation",
      gate: "approved-freeze validation refusal",
      allowed: "draft evidence where valid",
      forbidden: "authoritative frozen output or successor",
      preserved: "approval and all bound source inputs",
      next_action: "correct the owning editorial evidence and revalidate"
    },
    {
      id: "identical-approved-replay",
      file: "test/boundary_editorial_test.rb",
      tests: %w[
        test_explicit_approval_binds_complete_review_and_identical_replay_reuses_exact_bytes
        test_freeze_approved_replay_reuses_exact_bytes_without_another_draft_or_approval
      ],
      precondition: "all approval-relevant bytes are unchanged",
      gate: "validated frozen boundaries",
      allowed: "byte-identical reuse",
      forbidden: "duplicate approval or rewritten freeze",
      preserved: "approval and freeze hashes",
      next_action: "continue with the exact validated freeze"
    },
    {
      id: "source-registry-base-drift",
      file: "test/boundary_freeze_test.rb",
      tests: %w[
        test_validate_fails_when_markdown_bytes_drift
        test_validate_fails_when_registry_or_base_amc_drift
      ],
      precondition: "source, registry, or base bytes differ from the frozen handoff",
      gate: "boundary-freeze provenance refusal",
      allowed: "mismatch evidence",
      forbidden: "hash repair or successor apply",
      preserved: "original frozen provenance",
      next_action: "produce and review a newly bound handoff"
    },
    {
      id: "segment-parent-level-validation",
      file: "test/boundary_freeze_test.rb",
      tests: %w[
        test_validate_rejects_segment_gap_and_cross_segment_range
        test_validate_rejects_bad_parent_reference_and_bad_levels
      ],
      precondition: "segment gap, cross-segment range, invalid parent, or invalid levels",
      gate: "boundary-freeze structural refusal",
      allowed: "validation diagnostics",
      forbidden: "Adventure ID allocation and successor mutation",
      preserved: "source and base bytes",
      next_action: "correct the reviewed boundary data"
    },
    {
      id: "stage-authority-conflict",
      file: "test/boundary_freeze_apply_test.rb",
      tests: %w[
        test_operation_bound_stage_rejects_missing_or_conflicting_authoritative_metadata
        test_operation_bound_stage_rejects_operation_base_and_artifact_conflicts
      ],
      precondition: "operation, base, freeze, publisher, or successor authority does not bind",
      gate: "staged-successor authority refusal",
      allowed: "binding diagnostic",
      forbidden: "successor or shared-role mutation",
      preserved: "base, freeze, operation, and authority bytes",
      next_action: "correct or reissue the owning authority"
    },
    {
      id: "version-destination-collision",
      file: "test/boundary_freeze_apply_test.rb",
      tests: %w[
        test_deterministic_mode_rejects_equal_or_malformed_versions_and_unversioned_base
        test_deterministic_mode_refuses_preexisting_derived_output
        test_deterministic_mode_refuses_preexisting_derived_report
        test_operation_bound_stage_rejects_version_collisions_partial_publication_and_mutated_replay
      ],
      precondition: "invalid successor version or destination/report collision",
      gate: "deterministic publication refusal",
      allowed: "collision diagnostic",
      forbidden: "overwrite, silent version choice, or partial success",
      preserved: "pre-existing destination and report bytes",
      next_action: "select an explicit free version/destination through the owner"
    },
    {
      id: "verified-stage-and-replay",
      file: "test/boundary_freeze_apply_test.rb",
      tests: %w[
        test_operation_bound_stage_creates_verified_successor_without_promoting_shared_roles
        test_operation_bound_stage_replay_preserves_exact_artifacts_and_ids
        test_operation_bound_stage_cli_is_terminal_and_does_not_emit_adoption_or_scoring
      ],
      precondition: "approved freeze and exact operation/version authority",
      gate: "verified staged successor",
      allowed: "new IDs and immutable staged artifacts",
      forbidden: "shared catalog promotion or scoring",
      preserved: "base, freeze, role state, and replay hashes",
      next_action: "continue deterministic ingest from the staged receipt"
    },
    {
      id: "zero-record-stage",
      file: "test/boundary_freeze_apply_test.rb",
      tests: %w[test_operation_bound_zero_record_stage_is_traceable_without_successor],
      precondition: "fully reviewed and approved freeze contains zero accepted records",
      gate: "no successor needed",
      allowed: "traceable no-op receipt",
      forbidden: "fabricated version bump, IDs, or workbook",
      preserved: "approval and zero-record freeze",
      next_action: "continue through explicit no-successor handling"
    }
  ].freeze

  def test_boundary_exception_matrix_executes_landed_public_pipeline_proof
    grouped = MATRIX.flat_map do |row|
      row.fetch(:tests).map { |test| [row.fetch(:file), test] }
    end.group_by(&:first)

    grouped.each do |file, pairs|
      result = run_group(file, pairs.map(&:last))
      assert result.fetch(:status).success?, result.fetch(:output)
      assert_match(/#{pairs.length} runs,/, result.fetch(:output))
      assert_match(/0 failures, 0 errors/, result.fetch(:output))
    end

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
    output, status = Open3.capture2e(
      RbConfig.ruby, "-Ilib", "-Itest", file, "--name", pattern,
      chdir: PIPELINE_ROOT
    )
    {output:, status:}
  end
end
