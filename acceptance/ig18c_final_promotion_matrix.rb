# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"

class Ig18cFinalPromotionMatrixTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PIPELINE_ROOT = File.expand_path(
    ENV.fetch(
      "AF_DATA_PIPELINE_ROOT",
      ENV.fetch(
        "AF_IG19B_PIPELINE_SOURCE_ROOT",
        File.join(ENV.fetch("AF_PROJECT_ROOT", "/Users/davidnorris/code/adventure-finder-components"),
                  "af-data-pipeline")
      )
    )
  )

  MATRIX = [
    {
      id: "clean-standing-release-and-replay",
      repository: :front_door,
      file: "test/integration/final_promotion_pipeline_seam_test.rb",
      tests: %w[test_front_door_delegates_exact_approval_to_real_pipeline_transaction],
      proves: "standing-directive-only promotion, scoped persistence, unchanged Git identity, and truthful identical replay"
    },
    {
      id: "explicit-decline",
      repository: :front_door,
      file: "test/integration/final_promotion_pipeline_seam_test.rb",
      tests: %w[test_front_door_decline_records_exact_authority_without_catalog_or_git_mutation],
      proves: "decline is durable authority and cannot mutate catalog or Git state"
    },
    {
      id: "same-filename-byte-collision",
      repository: :front_door,
      file: "test/integration/final_promotion_pipeline_seam_test.rb",
      tests: %w[test_front_door_refuses_same_filename_different_bytes_without_overwrite],
      proves: "an existing canonical filename with different bytes is never overwritten or treated as approval"
    },
    {
      id: "candidate-package-reference-and-manifest-drift",
      repository: :pipeline,
      file: "test/final_release_adoption_test.rb",
      tests: %w[test_exact_approval_rejects_staleness_survives_interruption_and_replays],
      proves: "candidate, package, request, referenced role, interruption, promotion, durable-result replay, and no-overwrite behavior"
    },
    {
      id: "catalog-head-drift",
      repository: :pipeline,
      file: "test/final_release_adoption_test.rb",
      tests: %w[test_decline_and_changed_repository_head_never_mutate_catalog],
      proves: "decline and catalog repository HEAD advancement refuse adoption without collateral mutation"
    },
    {
      id: "standing-authority-and-package-replay",
      repository: :pipeline,
      file: "test/integration/final_release_package_test.rb",
      tests: %w[test_clean_package_and_read_only_replay_bind_complete_standing_authority],
      proves: "boundary-created IDs, exact standing acceptance, zero human/machine acceptance, complete counts, and byte-stable package replay"
    },
    {
      id: "optional-frontier-rebinding",
      repository: :pipeline,
      file: "test/integration/final_release_package_test.rb",
      tests: %w[
        test_terminal_gap_and_declined_frontier_remain_ready_without_full_scoring
        test_valid_derived_candidate_binds_exact_original_and_separate_frontier_counts
      ],
      proves: "the clean release is frontier-independent and any derived candidate receives a distinct package and authority binding"
    },
    {
      id: "release-reference-drift",
      repository: :pipeline,
      file: "test/integration/final_release_package_test.rb",
      tests: %w[
        test_missing_mutated_and_malformed_immutable_references_are_refused
        test_successful_subset_and_rehashed_release_counts_do_not_replace_full_population
      ],
      proves: "missing, mutated, malformed, subset, and rehashed evidence cannot preserve prior release authority"
    },
    {
      id: "lineage-and-concurrent-catalog-safety",
      repository: :pipeline,
      file: %w[test/integration/final_release_package_test.rb test/final_release_package_test.rb],
      tests: %w[
        test_current_head_advancement_is_scoring_safe_but_lost_score_blocks_promotion
        test_current_manifest_and_uncommitted_catalog_bytes_cannot_claim_repository_head
        test_catalog_delta_reports_lost_additions_removals_and_conflicting_ids
      ],
      proves: "advanced or incompatible lineage cannot silently rebase, lose concurrent changes, or claim a stale Git head"
    },
    {
      id: "authority-count-separation",
      repository: :pipeline,
      file: "test/integration/final_release_package_test.rb",
      tests: %w[
        test_human_and_source_terminal_exceptions_remain_distinct
        test_unavailable_ig16b_application_control_cannot_be_replaced_by_record_only_authority
      ],
      proves: "standing, individual-human, machine, hold, reject, source-hold, deferred, and unresolved states remain distinct"
    },
    {
      id: "preview-is-non-authoritative",
      repository: :pipeline,
      file: "test/integration/final_release_package_test.rb",
      tests: %w[test_preview_is_informational_and_public_cli_validates_without_publication],
      proves: "verified red-cell preview remains optional and grants no score or promotion authority"
    },
    {
      id: "independent-role-preservation",
      repository: :pipeline,
      file: "test/project_state_test.rb",
      tests: %w[test_promoting_catalog_head_does_not_move_other_roles],
      proves: "catalog promotion changes only catalog_head"
    }
  ].freeze

  def test_final_promotion_matrix_executes_landed_public_owner_proofs
    grouped = MATRIX.flat_map do |row|
      row.fetch(:tests).map { |test| [row.fetch(:repository), row.fetch(:file), test] }
    end.group_by { |repository, file, _test| [repository, file] }

    grouped.each do |(repository, file), triples|
      result = run_group(repository, file, triples.map(&:last))
      assert result.fetch(:status).success?, result.fetch(:output)
      assert_match(/#{triples.length} runs,/, result.fetch(:output))
      assert_match(/0 failures, 0 errors/, result.fetch(:output))
    end
    assert_equal MATRIX.length, MATRIX.map { |row| row.fetch(:id) }.uniq.length
    assert_equal 17, MATRIX.sum { |row| row.fetch(:tests).length }
    MATRIX.each { |row| refute_empty row.fetch(:proves), "#{row.fetch(:id)} missing proof statement" }
  end

  private

  # Load every named owner file before Minitest filters this group; mixed unit/
  # integration rows retain their original exact expected run count.
  def run_group(repository, file, tests)
    root = repository == :pipeline ? PIPELINE_ROOT : ROOT
    environment = repository == :front_door ? {"AF_DATA_PIPELINE_ROOT" => PIPELINE_ROOT} : {}
    pattern = "/\\A(?:#{tests.join('|')})\\z/"
    output, status = Open3.capture2e(
      environment, RbConfig.ruby, "-Ilib", "-Itest",
      "-e", "ARGV.shift(#{Array(file).length}).each { |path| require File.expand_path(path) }",
      *Array(file), "--name", pattern, chdir: root
    )
    {output:, status:}
  end
end
