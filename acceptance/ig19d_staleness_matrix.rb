# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"

# Independent owner predicate proofs supplement the fresh-process composition
# in ig19d_restart_promotion_test.rb. These are not an automatic ingest journey
# and do not establish an approval when the real promotion seam is blocked.
class Ig19dStalenessMatrixTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  REPOSITORIES = {
    "adventure-finder" => ROOT,
    "af-data-pipeline" => ENV.fetch("AF_DATA_PIPELINE_ROOT"),
    "af-workloads" => ENV.fetch("AF_AFW_SOURCE_ROOT")
  }.freeze
  MATRIX = [
    {id: "boundary-approval-drift", owner: "af-data-pipeline", file: "test/boundary_editorial_test.rb",
     tests: %w[test_explicit_approval_binds_complete_review_and_identical_replay_reuses_exact_bytes
       test_approval_invalidates_for_each_changed_review_or_provenance_input
       test_freeze_approved_replay_reuses_exact_bytes_without_another_draft_or_approval],
     input: "unchanged or changed review/source/base/dossier/decisions", precondition: "exact human boundary approval",
     identities: %w[approval_id context_sha256 decisions_sha256 freeze_sha256],
     gate: "safe identical replay or hard stale approval refusal", next_action: "fresh human boundary review for changed inputs"},
    {id: "staged-authority-and-shared-head", owner: "af-data-pipeline", file: "test/staged_scoring_authority_stale_base_acceptance_test.rb",
     tests: %w[test_head_matrix_before_issuance_uses_content_proof_and_never_mutates_inputs
       test_head_matrix_after_workload_freeze_preserves_authority_workload_and_roles
       test_identical_replay_regeneration_and_fresh_process_from_other_cwd_are_safe
       test_changed_staged_content_and_missing_original_base_fail_closed
       test_changed_authority_bytes_version_and_binding_are_conflicts
       test_newer_base_rebind_allocation_rewrite_and_workload_rebind_are_refused],
     input: "unchanged/compatible/incompatible head before and after freeze; staged bytes; authority; base; IDs",
     precondition: "approved staging lineage and exact public frozen workload binding",
     identities: %w[operation_id authority_id workload_id staged_sha256 base_sha256 allocated_ids],
     gate: "SAFE_REUSE or STALE_INPUT/CONFLICT; frozen identities never rebind",
     next_action: "reuse only proved compatible work; resolve incompatible owned evidence"},
    {id: "workload-fresh-coordinator", owner: "adventure-finder", file: "test/integration/ig14e_staged_workload_restart_acceptance_test.rb",
     tests: %w[test_actual_owner_contracts_preserve_mixed_allocation_across_process_restart],
     input: "mixed qualified and deferred IDs", precondition: "real staged authority and synthetic scorer preflight IO",
     identities: %w[operation_id workload_id selection_id selected_ids authority_id],
     gate: "identical PREPARED/reuse", next_action: "inspect frozen workload; local execution remains explicit"},
    {id: "local-partial-complete-and-active-restart", owner: "adventure-finder", file: "test/integration/local_ingest_execution_test.rb",
     tests: %w[test_fresh_process_restart_before_first_capability_request_reconstructs_bootstrap
       test_fresh_process_restart_after_ready_before_wlo_start_preserves_identity
       test_interrupted_capability_establishment_restarts_from_public_low_facts
       test_restart_after_completed_work_reconciles_generation_change_without_replay
       test_active_wlo_owner_is_observed_without_a_duplicate_launch
       test_public_operator_pause_remains_a_gate_until_explicit_continue
       test_failed_work_requires_selected_retry_and_preserves_archived_evidence
       test_restart_refuses_changed_operation_plan_sequence_and_execution_locator],
     input: "fresh-process local readiness/partial/completed execution, owner/pause/retry, immutable drift",
     precondition: "real LOW/WLO public APIs; fake runtime observer and synthetic executable payloads",
     identities: %w[operation_id plan_id consumer_id job_id attempt generation output_sha256],
     gate: "safe resume, owned active/recovery gate or STALE_LOCAL_EXECUTION",
     next_action: "observe active owner; explicitly authorize pause continuation or selected retry when required"},
    {id: "standing-policy-and-human-exceptions", owner: "af-data-pipeline", file: "test/standing_bulk_score_release_test.rb",
     tests: %w[test_human_and_source_decisions_take_precedence_without_fabricated_accept_rows
       test_explicit_preview_has_no_authority_effect_and_exact_replay_is_read_only
       test_changed_policy_candidate_staged_bytes_and_revocation_fail_closed],
     input: "unchanged release, explicit ACCEPT/HOLD/REJECT/source hold, revoked/changed policy or candidate",
     precondition: "exact standing selection plus complete supported owner evidence fixture",
     identities: %w[policy_digest selection_id candidate_key authority_id manifest_id],
     gate: "stable standing application; human/source precedence; hard changed-input refusal",
     next_action: "reuse the exact release; resolve owner drift without renewed automatic acceptance"},
    {id: "scoring-safe-is-not-promotion-safe", owner: "af-data-pipeline", file: "test/final_release_package_test.rb",
     tests: %w[test_current_head_advancement_is_scoring_safe_but_lost_score_blocks_promotion
       test_current_manifest_and_uncommitted_catalog_bytes_cannot_claim_repository_head
       test_missing_mutated_and_malformed_immutable_references_are_refused
       test_unavailable_ig16b_application_control_cannot_be_replaced_by_record_only_authority],
     input: "concurrent scores/HEAD/manifest/reference drift and unavailable IG-16B authority",
     precondition: "exact original release, independently bound catalog Git state and immutable package",
     identities: %w[package_id release_manifest_id candidate_sha256 catalog_head manifest_sha256],
     gate: "SAFE_REUSE scoring can coexist with PROMOTION_WOULD_LOSE_CURRENT_CHANGES; other drift refused",
     next_action: "preserve concurrent changes; prepare fresh review; retain zero IG-16B acceptances"}
  ].freeze

  MATRIX.each do |scenario|
    define_method("test_#{scenario.fetch(:id).tr('-', '_')}") do
      repository = REPOSITORIES.fetch(scenario.fetch(:owner))
      tests = scenario.fetch(:tests)
      pattern = "/\\A(?:#{tests.map { |name| Regexp.escape(name) }.join('|')})\\z/"
      command = [RbConfig.ruby, "-Ilib", "-Itest", scenario.fetch(:file), "--name", pattern]
      environment = {"BUNDLE_GEMFILE" => nil, "BUNDLE_LOCKFILE" => nil}
      if scenario.fetch(:owner) != "adventure-finder"
        command = ["bundle", "exec", *command]
        environment["BUNDLE_GEMFILE"] = File.join(repository, "Gemfile")
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      output, status = Open3.capture2e(environment, *command, chdir: repository)
      summary = output.scan(/^(\d+) runs, (\d+) assertions, (\d+) failures, (\d+) errors, (\d+) skips$/).last&.map(&:to_i)
      passed = status.success? && summary && summary[0] == tests.length && summary[2..4].all?(&:zero?)
      evidence = scenario.merge(status: passed ? "PASS" : "FAIL", actual: summary,
        command:, cwd: repository, wall_seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
        allowed_mutation: "explicit fixture producer outputs only; replay/validation read-only",
        forbidden_mutation: "silent base/ID rebind, stale approval reuse, automatic retry or Git persistence",
        preserved: "owner assertions compare exact bound artifacts, identities, independent roles and completed attempts")
      puts "IG-19D predicate evidence: #{JSON.generate(evidence)}"
      puts output
      assert passed, "#{scenario.fetch(:id)} did not execute its complete owner proof: #{output}"
    end
  end
end
