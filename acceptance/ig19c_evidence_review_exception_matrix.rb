# frozen_string_literal: true

require "minitest/autorun"
require_relative "ig19c_matrix_support"

class Ig19cEvidenceReviewExceptionMatrixTest < Minitest::Test
  include Ig19cMatrixSupport

  MATRIX = [
    {
      id: "current-attempt-evidence-only",
      repository: "af-workloads",
      file: "test/scoring_evidence_test.rb",
      tests: %w[
        test_superseded_attempt_evidence_cannot_be_selected_and_attempt_two_is_bound
        test_current_attempt_change_after_selection_is_rejected_before_write
        test_failed_wlo_attempt_with_present_outputs_is_not_valid_evidence
      ],
      input: "superseded, changed, or failed attempt with scorer artifacts present",
      precondition: "AFW binds the authoritative WLO attempt identity",
      identities: %w[workload_id plan_id job_id attempt receipt_id],
      gate: "no complete current AFSU evidence set",
      allowed: "attempt-aware diagnostic",
      forbidden: "newest-file selection, receipt fabrication or failed-output acceptance",
      preserved: "superseded attempts and current WLO metadata",
      next_action: "repair or explicitly retry through WLO ownership"
    },
    {
      id: "missing-ambiguous-and-changed-scorer-evidence",
      repository: "af-workloads",
      file: "test/scoring_evidence_test.rb",
      tests: %w[
        test_command_success_without_proposed_assessment_is_rejected
        test_command_success_without_request_evidence_is_rejected
        test_command_success_without_response_evidence_is_rejected
        test_modified_evidence_bytes_after_discovery_are_detected
      ],
      input: "successful command missing an artifact or with changed bound bytes",
      precondition: "exit zero is insufficient without the complete exact scorer evidence set",
      identities: %w[run_id request_sha256 response_sha256 assessment_sha256 attempt],
      gate: "evidence binding refusal",
      allowed: "focused missing/changed evidence report",
      forbidden: "review candidate, receipt persistence or fake human decision",
      preserved: "available scorer and WLO artifacts",
      next_action: "repair the scorer evidence producer or explicitly retry execution"
    },
    {
      id: "levels-metric-identity",
      repository: "af-workloads",
      file: "test/scoring_evidence_test.rb",
      tests: %w[
        test_valid_levels_assessment_requires_exactly_one_start_and_end_row
        test_levels_assessment_without_level_start_is_rejected
        test_levels_assessment_without_level_end_is_rejected
        test_levels_assessment_with_unexpected_third_metric_is_rejected
      ],
      input: "Levels evidence with two exact siblings or a missing/extra sibling",
      precondition: "one shared receipt does not collapse metric candidates",
      identities: %w[candidate_key adventure_id dimension metric receipt_id],
      gate: "two exact candidates or fail-closed receipt refusal",
      allowed: "separate Level Start and Level End candidates",
      forbidden: "implicit sibling acceptance or denominator loss",
      preserved: "metric-level identity and shared receipt provenance",
      next_action: "supply the exact two-metric Levels assessment"
    },
    {
      id: "complete-denominator-control",
      repository: "af-workloads",
      file: "test/workload_evidence_manifest_test.rb",
      tests: %w[
        test_all_success_freezes_denominator_receipts_and_levels_candidates
        test_successful_subset_is_accounted_for_but_not_evidence_complete
        test_missing_and_ambiguous_scoring_evidence_are_unresolved_without_receipts
      ],
      input: "complete success, partial success, and missing/ambiguous evidence",
      precondition: "the frozen workload supplies the complete intended-case denominator",
      identities: %w[manifest_id workload_id case_id job_id receipt_id candidate_key],
      gate: "evidence_complete only for full authoritative accounting",
      allowed: "partial publication with explicit unresolved cases",
      forbidden: "partial completion claim or fabricated receipt",
      preserved: "all intended cases, receipts and Levels candidates",
      next_action: "continue only after every intended case has authoritative evidence"
    },
    {
      id: "denominator-tampering",
      repository: "af-workloads",
      file: "test/workload_evidence_manifest_test.rb",
      tests: %w[
        test_validator_rejects_missing_duplicate_extra_and_empty_denominators
        test_validator_rejects_changed_receipt_bytes_and_receipt_id
        test_validator_rejects_mismatched_execution_and_attempt_identity
      ],
      input: "missing, duplicate, extra, empty, changed-receipt or mismatched-attempt manifest",
      precondition: "manifest identity alone cannot replace revalidation of bound evidence",
      identities: %w[manifest_id plan_sha256 index_sha256 execution_id attempt receipt_id],
      gate: "manifest validation refusal",
      allowed: "precise integrity diagnostic",
      forbidden: "denominator rewrite or current-attempt reassignment",
      preserved: "published revisions and referenced evidence",
      next_action: "republish from exact owner evidence after correcting the producer"
    },
    {
      id: "partial-review-is-not-complete",
      repository: "af-data-pipeline",
      file: "test/workload_scoring_review_package_test.rb",
      tests: %w[
        test_partial_success_keeps_decided_subset_visibly_workload_incomplete
        test_every_execution_and_evidence_state_is_explicit_without_fabricated_rows
        test_authorized_retry_and_superseded_attempts_remain_visible
      ],
      input: "partial workload with mixed execution/evidence states and retained decisions",
      precondition: "pipeline consumes AFW's complete denominator and immutable receipts",
      identities: %w[manifest_id package_id candidate_key receipt_id attempt],
      gate: "workload incomplete while valid decisions remain visible",
      allowed: "review package for real candidates and explicit unresolved accounting",
      forbidden: "false completeness, invented rows or superseded-attempt hiding",
      preserved: "decisions, attempts, receipts and unresolved cases",
      next_action: "route execution repair separately from existing human decisions"
    },
    {
      id: "review-denominator-integrity",
      repository: "af-data-pipeline",
      file: "test/workload_scoring_review_package_test.rb",
      tests: %w[
        test_rejects_denominator_mutation_even_with_recomputed_manifest_identity
        test_rejects_duplicate_and_extra_denominator_members
        test_rejects_mutated_receipt_artifact
        test_rejects_conflicting_candidate_keys_across_distinct_cases
      ],
      input: "rehashed denominator mutation, duplicate/extra member, changed receipt or candidate conflict",
      precondition: "pipeline independently revalidates AFW evidence and metric identities",
      identities: %w[manifest_id package_id case_id candidate_key receipt_id],
      gate: "review-package refusal",
      allowed: "integrity diagnostic",
      forbidden: "review ledger, acceptance or workbook mutation",
      preserved: "source manifest and conflicting evidence",
      next_action: "repair the AFW producer or execution evidence without rewriting review history"
    },
    {
      id: "standing-valid-numeric-and-advisory",
      repository: "af-data-pipeline",
      file: "test/standing_bulk_score_release_test.rb",
      tests: %w[
        test_full_qualified_workload_uses_standing_directive_and_publishes_only_finalized_candidate
        test_human_and_source_decisions_take_precedence_without_fabricated_accept_rows
      ],
      input: "complete qualified numeric candidates including policy-classified LOW_CONFIDENCE advisory",
      precondition: "active exact standing policy and owner selection bind the workload",
      identities: %w[policy_digest selection_id manifest_id candidate_key authority_id],
      gate: "standing acceptance for eligible candidates with human/source precedence",
      allowed: "immutable release candidate and explicit acceptance accounting",
      forbidden: "individual review requirement for advisory-only flags or shared catalog promotion",
      preserved: "human HOLD/REJECT/ACCEPT, source holds and ledger bytes",
      next_action: "continue qualified release accounting; route each exception to its owner"
    },
    {
      id: "standing-scope-and-hard-invalidity",
      repository: "af-data-pipeline",
      file: "test/standing_bulk_score_release_test.rb",
      tests: %w[
        test_scope_and_flag_classification_covers_every_policy_branch_without_rebuilding_a_workload
        test_failed_or_nonterminal_workload_evidence_blocks_before_workbook_mutation
        test_standing_policy_rejects_unsupported_page_scope_and_changed_activation
      ],
      input: "scope mismatch, unknown/hard flag, failed workload or changed activation",
      precondition: "standing authority is exact and never widens qualification",
      identities: %w[policy_digest selection_id profile model_alias model dimension source_id],
      gate: "unsupported scope, hard-refusal or nonterminal-evidence block",
      allowed: "explicit residual or refusal",
      forbidden: "machine acceptance, workbook mutation or policy reinterpretation",
      preserved: "policy, selection, workload and candidate evidence",
      next_action: "defer unsupported work or correct the owning hard-invalid evidence"
    },
    {
      id: "human-hold-reject-remain-terminal",
      repository: "af-data-pipeline",
      file: "test/amc_apply_test.rb",
      tests: %w[
        test_editorial_hold_produces_no_write
        test_editorial_reject_produces_no_write
        test_source_hold_produces_no_write
      ],
      input: "exact candidate carrying human HOLD, human REJECT or source HOLD",
      precondition: "human and source decisions precede standing application",
      identities: %w[candidate_key editorial_decision decision_authority],
      gate: "terminal non-accepting decision",
      allowed: "gap accounting and focused owner action",
      forbidden: "score write, execution retry or fabricated replacement decision",
      preserved: "decision and candidate provenance",
      next_action: "human reconsideration or source correction only through the owning seam"
    },
    {
      id: "ig12b-non-authorizing-outcomes",
      repository: "af-data-pipeline",
      file: "test/scoring_acceptance_retrospective_test.rb",
      tests: %w[
        test_missing_bindings_are_evidence_gaps_and_counts_reconcile
        test_negative_control_detects_false_auto_accept_and_concludes_fail
      ],
      input: "retrospective population with missing exact bindings or a false-auto-accept negative control",
      precondition: "IG-12B is an offline falsification report and grants no application authority",
      identities: %w[record_key record_sha256 policy_digest source_assessment_sha256 raw_response_sha256],
      gate: "INSUFFICIENT_EVIDENCE or FAIL",
      allowed: "retrospective accounting and adverse evidence",
      forbidden: "ledger mutation, score acceptance or IG-16B enablement",
      preserved: "human and historical V1 decision provenance",
      next_action: "retain zero IG-16B acceptances and continue independently valid standing or human routing"
    },
    {
      id: "ig16b-authority-absent",
      repository: "af-data-pipeline",
      file: "test/integration/final_release_package_test.rb",
      tests: %w[
        test_clean_package_and_read_only_replay_bind_complete_standing_authority
        test_unavailable_ig16b_application_control_cannot_be_replaced_by_record_only_authority
      ],
      input: "standing release with no IG-16B application or a record-only nonzero claim",
      precondition: "IG-12B is INSUFFICIENT_EVIDENCE and IG-16B application/suspension control has not landed",
      identities: %w[package_id policy_digest selection_id release_manifest_id],
      gate: "exact zero IG-16B acceptances; record-only nonzero claim refused",
      allowed: "standing directive and valid individual human decisions",
      forbidden: "simulated IG-16B authority or historical mechanical relabeling",
      preserved: "separate standing, human, IG-16B and historical counts",
      next_action: "continue standing ingestion without the optional IG-16B branch"
    },
    {
      id: "full-population-and-levels-reconciliation",
      repository: "af-data-pipeline",
      file: %w[test/integration/final_release_package_test.rb test/final_release_package_test.rb],
      tests: %w[
        test_successful_subset_and_rehashed_release_counts_do_not_replace_full_population
        test_complete_metric_identity_requires_levels_siblings_and_unique_members
        test_human_and_source_terminal_exceptions_remain_distinct
      ],
      input: "partial/rehashed counts, missing Levels sibling, duplicate member or terminal human/source gaps",
      precondition: "final accounting replays every intended case and metric identity",
      identities: %w[package_id intended_case_id candidate_key metric],
      gate: "full reconciliation or explicit terminal gap",
      allowed: "separate terminal exception accounting",
      forbidden: "denominator shrink, Levels collapse or exception conflation",
      preserved: "intended population and each decision category",
      next_action: "repair unresolved evidence or retain the exact terminal decision"
    },
    {
      id: "standing-release-replay-and-collision",
      repository: "af-data-pipeline",
      file: "test/standing_bulk_score_release_test.rb",
      tests: %w[
        test_explicit_preview_has_no_authority_effect_and_exact_replay_is_read_only
        test_changed_output_collision_and_failures_between_phases_never_announce_completion
        test_changed_policy_candidate_staged_bytes_and_revocation_fail_closed
      ],
      input: "identical replay, changed output, interrupted phase, revoked policy or changed bound bytes",
      precondition: "release identity binds every immutable input and output",
      identities: %w[policy_digest selection_id manifest_id authorization_id output_sha256],
      gate: "byte-identical reuse or fail-closed collision",
      allowed: "read-only replay and non-authoritative preview",
      forbidden: "overwrite, completion announcement or silent rebind",
      preserved: "prior release artifacts and all bound input evidence",
      next_action: "reuse exact release or issue new owning authority after resolving drift"
    }
  ].freeze

  def test_evidence_and_review_exception_matrix_runs_public_owner_proofs
    run_matrix!("evidence-review-exceptions", MATRIX)
  end
end
