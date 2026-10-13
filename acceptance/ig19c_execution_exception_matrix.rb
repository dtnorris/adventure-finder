# frozen_string_literal: true

require "minitest/autorun"
require_relative "ig19c_matrix_support"

class Ig19cExecutionExceptionMatrixTest < Minitest::Test
  include Ig19cMatrixSupport

  MATRIX = [
    {
      id: "qualified-page-boundary-and-levels",
      repository: "af-workloads",
      file: "test/staged_selection_test.rb",
      tests: %w[
        test_mixed_allocation_defers_exactly_100_pages_and_replays_durably
        test_single_multiple_and_all_deferred_are_distinct
        test_populated_levels_preserved_blank_levels_selected_and_source_failure_refused
      ],
      input: "operation-bound allocation with 99-page qualified and 100-page deferred records",
      precondition: "current AFW qualification is the exclusive <100-page envelope",
      identities: %w[authority_id selection_id adventure_id source_id],
      gate: "selected-qualified or legitimately-deferred with exact Levels evidence",
      allowed: "selection ledger and qualified workload preparation",
      forbidden: "page-envelope widening, sibling Levels loss, or scorer invocation for deferred work",
      preserved: "allocation order, authority, source, page and Levels evidence",
      next_action: "execute selected work; leave deferred work unscored"
    },
    {
      id: "unsupported-record-refusal",
      repository: "af-workloads",
      file: "test/staged_selection_test.rb",
      tests: %w[test_invalid_large_records_are_refused_before_deferral],
      input: "large record with malformed identity, pages, Levels, source or populated score state",
      precondition: "deferral is available only after structural qualification checks",
      identities: %w[authority_id adventure_id catalog_row_sha256 allocation_sha256],
      gate: "REFUSED",
      allowed: "complete refusal disposition",
      forbidden: "defer-as-valid, workload construction, or source repair",
      preserved: "invalid input and owning diagnostic",
      next_action: "correct the owning catalog or allocation evidence"
    },
    {
      id: "legacy-selector-exclusive-boundary",
      repository: "af-workloads",
      file: "test/adventure_ingest_test.rb",
      tests: %w[test_page_envelope_remains_frozen],
      input: "legacy qualified selector record at exactly 100 pages",
      precondition: "the standing production qualification declares max_page_count_exclusive=100",
      identities: %w[adventure_id qualification_sha256 runtime_sha256 preflight_sha256],
      gate: "outside proven <100 page envelope",
      allowed: "qualification refusal",
      forbidden: "case or plan generation",
      preserved: "frozen qualification boundary",
      next_action: "route through the explicit deferred/unsupported owner path"
    },
    {
      id: "zero-exit-is-not-ready",
      repository: "adventure-finder",
      file: "test/integration/local_ingest_execution_test.rb",
      tests: %w[
        test_zero_exit_bootstrap_without_independent_ready_publication_is_refused
        test_low_publication_failure_stops_before_wlo_launch
      ],
      input: "bootstrap exits zero without exact generation-bound READY publication",
      precondition: "AF coordinates the retained local execution intent through LOW's public seam",
      identities: %w[operation_id capability_request_id worker_id generation],
      gate: "CAPABILITY_NOT_READY",
      allowed: "LOW observation/bootstrap evidence and focused diagnostic",
      forbidden: "WLO launch, remote fallback, capability relaxation or inferred readiness",
      preserved: "operation intent and incomplete LOW evidence",
      next_action: "repair exact local capability readiness and resume the same operation"
    },
    {
      id: "exact-runtime-capability",
      repository: "adventure-finder",
      file: "test/integration/local_ingest_execution_test.rb",
      tests: %w[
        test_wrong_runtime_digest_does_not_establish_readiness
        test_wrong_runtime_context_does_not_establish_readiness
        test_partial_runtime_residency_does_not_establish_readiness
      ],
      input: "installed model with wrong digest, context, or residency",
      precondition: "the frozen request requires an exact capability match",
      identities: %w[model digest context_tokens fully_gpu_resident generation],
      gate: "CAPABILITY_NOT_READY",
      allowed: "truthful unavailable/not-ready observation",
      forbidden: "forged registry, model alias substitution or execution",
      preserved: "requested and observed capability evidence",
      next_action: "establish the exact requested capability"
    },
    {
      id: "no-compatible-ready-worker",
      repository: "workload-orchestrator",
      file: "test/dynamic_local_dispatch_test.rb",
      tests: %w[
        test_no_workers_means_polling_without_provider_fallback
        test_generation_replacement_halts_without_provider_replay
      ],
      input: "zero compatible READY workers or changed generation",
      precondition: "WLO consumes only the bound local registry source",
      identities: %w[plan_id source_id registry_revision worker_id generation],
      gate: "waiting or halted",
      allowed: "public polling/status evidence",
      forbidden: "legacy provider dispatch, remote fallback or replay on replacement",
      preserved: "pending jobs and prior attempt bindings",
      next_action: "wait for exact READY capacity or resolve changed generation"
    },
    {
      id: "operator-pause-and-active-owner",
      repository: "adventure-finder",
      file: "test/integration/local_ingest_execution_test.rb",
      tests: %w[
        test_public_operator_pause_remains_a_gate_until_explicit_continue
        test_active_wlo_owner_is_observed_without_a_duplicate_launch
        test_operation_coordination_lock_refuses_a_second_driver
      ],
      input: "intentional pause or an existing active executor/coordinator",
      precondition: "one frozen execution and one owner are already retained",
      identities: %w[operation_id plan_id consumer_id execution_id],
      gate: "OPERATOR_PAUSE or active-owner observation",
      allowed: "read-only status and explicit continue after review",
      forbidden: "pause clearing, duplicate launch or new output locator",
      preserved: "execution identity, jobs, attempts and pause evidence",
      next_action: "observe, wait, or explicitly continue the operator pause"
    },
    {
      id: "interruption-and-orphan-routing",
      repository: "adventure-finder",
      file: "test/integration/local_ingest_execution_test.rb",
      tests: %w[
        test_foreground_interrupt_reaches_wlo_and_retains_interrupted_evidence
        test_detached_wlo_owner_loss_exposes_orphaned_attempt_without_cleanup_claim
      ],
      input: "foreground interruption or detached manager loss",
      precondition: "WLO owns running subprocesses and durable attempt state",
      identities: %w[operation_id execution_id job_id attempt],
      gate: "explicit recovery required",
      allowed: "scoped cancellation or orphan diagnosis",
      forbidden: "unrelated process termination, cleanup claim or silent retry",
      preserved: "partial output and interruption/orphan evidence",
      next_action: "inspect WLO recovery evidence and select exact failed jobs"
    },
    {
      id: "selected-retry-and-breaker-authority",
      repository: "adventure-finder",
      file: "test/integration/local_ingest_execution_test.rb",
      tests: %w[
        test_failed_work_requires_selected_retry_and_preserves_archived_evidence
        test_breaker_requires_separate_explicit_acknowledgement
      ],
      input: "failed job with or without a tripped breaker",
      precondition: "ordinary resume grants neither retry nor breaker acknowledgement",
      identities: %w[plan_id execution_id job_id attempt reason],
      gate: "selected retry plus independent breaker acknowledgement when required",
      allowed: "archive prior attempt and queue only named jobs",
      forbidden: "all-job retry, breaker clearing or immediate execution",
      preserved: "completed counts and byte-identical prior attempt archives",
      next_action: "authorize exact jobs/reason and separately acknowledge the breaker"
    },
    {
      id: "unauthorized-recovery-does-not-mutate",
      repository: "workload-orchestrator",
      file: "test/retry_test.rb",
      tests: %w[
        test_invalid_requests_do_not_change_evidence_or_authorization
        test_retry_and_second_runner_refuse_active_execution_lock
        test_dry_run_previews_exact_evidence_without_mutation
      ],
      input: "unauthorized, malformed, preview-only, or concurrently owned retry request",
      precondition: "WLO recovery authority is explicit and execution-scoped",
      identities: %w[plan_id execution_id selected_jobs reason breaker],
      gate: "retry refusal or non-mutating preview",
      allowed: "focused preview/diagnostic",
      forbidden: "attempt advancement, archive creation or breaker acknowledgement",
      preserved: "all current evidence and authorization state",
      next_action: "submit a reviewed exact retry after the active owner exits"
    },
    {
      id: "restart-is-sticky-and-intent-bound",
      repository: "adventure-finder",
      file: "test/integration/local_ingest_execution_test.rb",
      tests: %w[
        test_restart_after_completed_work_reconciles_generation_change_without_replay
        test_restart_refuses_changed_operation_plan_sequence_and_execution_locator
      ],
      input: "restart after completed work or with changed retained intent",
      precondition: "the operation binds one plan, sequence and output locator",
      identities: %w[operation_id plan_id sequence_id output execution_id],
      gate: "sticky completion or STALE_LOCAL_EXECUTION",
      allowed: "reuse completed work and reconcile current capability facts",
      forbidden: "completed replay or replacement workload/output",
      preserved: "completed attempt evidence and frozen execution",
      next_action: "resume unchanged intent or return to the owning preparation"
    }
  ].freeze

  def test_execution_exception_matrix_runs_public_owner_proofs
    run_matrix!("execution-exceptions", MATRIX)
  end
end
