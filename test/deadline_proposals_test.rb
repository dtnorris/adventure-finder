# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"
require "open3"
require_relative "../lib/adventure_finder_deadline_proposals"

class DeadlineProposalsTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def setup
    @association = {
      "campaign_id" => "fixture", "campaign_identity_sha256" => "a" * 64,
      "binding_sha256" => "b" * 64, "budget_id" => "fixture-budget", "profile_id" => "qwen",
      "capability_fingerprint" => "c" * 64
    }
    @wlo = {
      "contract_version" => "wlo-execution-measurements/v0.1", "read_only" => true,
      "measured_at_utc" => "2026-10-04T12:00:00Z",
      "execution" => { "plan_id" => "fixture", "plan_sha256" => "d" * 64, "status" => "running",
        "window" => { "status" => "available", "started_at_utc" => "2026-10-04T11:00:00Z",
          "ended_at_utc" => "2026-10-04T12:00:00Z", "end_basis" => "measurement_clock", "elapsed_seconds" => 3600.0 } },
      "work" => { "total_jobs" => 18, "completed" => 6, "pending" => 12, "running" => 0,
        "failed" => 0, "interrupted" => 0, "retry_pending" => 0, "remaining_jobs" => 12 },
      "samples" => { "completed_successful_attempts" => 6, "failed_attempts" => 0,
        "interrupted_attempts" => 0, "currently_running_attempts" => 0, "attempts_excluded_missing_or_invalid_timing" => 0 },
      "throughput" => { "status" => "available", "sample_count" => 6,
        "denominator_seconds" => 3600.0, "jobs_per_hour" => 6.0 },
      "queue_wait" => { "status" => "unavailable", "reason" => "not retained" }
    }
    @evidence = (2..6).to_h { |count| [count, provider_evidence(count)] }
  end

  def test_exact_owner_plan_is_used_and_smallest_feasible_proposal_is_preferred
    result = compose
    assert_equal "adventurefinder-deadline-burst-proposals/v0.1", result["contract_version"]
    assert_equal "feasible", result["status"]
    assert_equal [4, 5, 6], result["recommendation_order"]
    assert_equal 4, result.dig("preferred_proposal", "worker_count")
    assert_equal "A40", result.dig("preferred_proposal", "preferred_hardware", "gpu_id")
    assert_equal %w[infeasible infeasible feasible feasible feasible], result["proposals"].map { |row| row["status"] }
    owner = AdventureFinderDeadlinePlan.plan(wlo: @wlo, **plan_options)
    assert_equal owner, result["deadline_plan"]
    owner["candidates"].zip(result["proposals"]).each { |math, row| assert_equal math, row.slice(*math.keys) }
    assert result["read_only"]
    assert result["planning_only"]
    refute result["mutation_permission"]
  end

  def test_deterministic_preference_ignores_collection_insertion_order
    expected = compose
    @evidence = @evidence.to_a.reverse.to_h
    assert_equal expected, compose
  end

  def test_math_failure_wins_even_when_provider_says_admissible_or_evidence_is_missing
    assert_equal "infeasible", proposal(2)["status"]
    assert_equal "admissible_under_current_authority", proposal(2).dig("rpof_admission_preview", "status")
    @evidence.delete(2)
    row = proposal(2)
    assert_equal "infeasible", row["status"]
    assert_includes row["reasons"], "mathematical_deadline_missed"
    assert_includes row["reasons"], "missing_matching_rpof_evidence"
  end

  def test_owner_authority_refusals_are_infeasible_without_recalculating_limits
    %w[profile_worker_ceiling_exceeded projected_worker_ceiling_exceeded
       projected_hourly_rate_ceiling_exceeded projected_cumulative_compute_authority_exceeded
       original_deadline_expired].each do |reason|
      refuse(@evidence[4], reason)
      row = proposal(4)
      assert_equal "infeasible", row["status"], reason
      assert_includes row["reasons"], reason
    end
  end

  def test_both_deadlines_exposed_and_original_campaign_expiry_blocks_completion
    change_deadline("2026-10-04T12:59:59Z")
    row = proposal(4)
    assert_equal "infeasible", row["status"]
    assert_includes row["reasons"], "rpof_authority_expires_before_estimated_completion"
    assert_equal "2026-10-04T12:59:59Z", row["rpof_campaign_deadline_utc"]
    assert_equal "2026-10-04T13:00:00.000000000Z", compose["target_completion_deadline_utc"]
    assert_equal 5, compose.dig("preferred_proposal", "worker_count")
    change_deadline("2026-10-04T13:00:00Z")
    assert_equal "feasible", proposal(4)["status"]
    change_deadline("2026-10-04T12:00:00Z")
    assert_equal "infeasible", proposal(4)["status"]
    assert_includes proposal(4)["reasons"], "rpof_campaign_deadline_expired"
  end

  def test_missing_wlo_throughput_and_wrong_wlo_contract_preserve_fo21a_insufficiency
    @wlo["throughput"] = { "status" => "unavailable", "sample_count" => 0 }
    result = compose
    assert_equal "insufficient_evidence", result["status"]
    assert_includes result["reasons"], "throughput_unavailable"
    assert_empty result["proposals"]
    assert_nil result["preferred_proposal"]
    @wlo["contract_version"] = "wrong"
    assert_includes compose["reasons"], "invalid_wlo_contract"
  end

  def test_wrong_planner_contract_is_not_silently_accepted
    original_plan = AdventureFinderDeadlinePlan.method(:plan)
    plan = AdventureFinderDeadlinePlan.plan(wlo: @wlo, **plan_options)
    plan["contract_version"] = "adventurefinder-deadline-burst-plan/v99"
    AdventureFinderDeadlinePlan.singleton_class.remove_method(:plan)
    AdventureFinderDeadlinePlan.define_singleton_method(:plan) { |**_options| plan }
    result = compose
    assert_equal "insufficient_evidence", result["status"]
    assert_includes result["reasons"], "invalid_deadline_plan_contract"
    assert_nil result["preferred_proposal"]
  ensure
    if original_plan
      AdventureFinderDeadlinePlan.singleton_class.remove_method(:plan)
      AdventureFinderDeadlinePlan.define_singleton_method(:plan, original_plan)
    end
  end

  def test_complete_and_passed_target_do_not_invent_proposals
    result = compose(deadline: "2026-10-04T11:00:00Z")
    assert_equal "infeasible", result["status"]
    assert_empty result["proposals"]
    @wlo["work"]["remaining_jobs"] = 0
    result = compose
    assert_equal "complete", result["status"]
    assert_nil result["preferred_proposal"]
  end

  def test_missing_and_mismatched_worker_count_are_never_extrapolated
    @evidence.delete(4)
    assert_equal "insufficient_evidence", proposal(4)["status"]
    assert_equal 5, compose.dig("preferred_proposal", "worker_count")
    @evidence[4] = provider_evidence(5)
    assert_includes proposal(4)["reasons"], "rpof_proposed_worker_count_mismatch"
    @evidence[4]["proposal"]["profile_workers"] = 4.0
    assert_equal "insufficient_evidence", proposal(4)["status"]
  end

  def test_every_explicit_identity_field_is_checked
    AdventureFinderDeadlineProposals::IDENTITY_KEYS.each do |key|
      @evidence[4] = provider_evidence(4)
      @evidence[4][key] = "wrong"
      row = proposal(4)
      assert_equal "insufficient_evidence", row["status"], key
      assert_includes row["reasons"], "rpof_identity_mismatch"
      assert_nil row["projected_aggregate_hourly_tracked_compute_usd"]
    end
  end

  def test_contract_read_only_and_mutation_permission_are_validated
    [->(doc) { doc["contract_version"] = "v99" }, ->(doc) { doc["read_only"] = false },
     ->(doc) { doc["admission_preview"]["mutation_permission"] = true },
     ->(doc) { doc["candidates"][0]["admission_preview"]["mutation_permission"] = true }].each do |change|
      @evidence[4] = provider_evidence(4)
      change.call(@evidence[4])
      assert_equal "insufficient_evidence", proposal(4)["status"]
    end
  end

  def test_catalog_price_and_guardian_unknowns_remain_insufficient
    %w[provider_catalog_unavailable price_unavailable price_invalid guardian_or_safety_evidence_unavailable].each do |reason|
      @evidence[4] = provider_evidence(4)
      refuse(@evidence[4], reason, status: "insufficient_evidence")
      assert_equal "insufficient_evidence", proposal(4)["status"], reason
      assert_includes proposal(4)["reasons"], reason
    end
    @evidence[4]["catalog_error"] = "offline"
    @evidence[4]["candidates"].each { |row| row["rank"] = nil }
    assert_equal "insufficient_evidence", proposal(4)["status"]
  end

  def test_success_requires_observed_price_availability_authorization_and_safety_proof
    [ ["authorized", false], ["eligible", false], ["price_status", "unavailable"],
      ["availability", "unknown"], ["hourly_rate_usd", nil],
      ["projected_aggregate_hourly_rate_usd", "2.75"] ].each do |key, value|
      @evidence[4] = provider_evidence(4)
      @evidence[4]["candidates"][0][key] = value
      assert_equal "insufficient_evidence", proposal(4)["status"], key
    end
    @evidence[4] = provider_evidence(4)
    @evidence[4]["candidates"][0]["admission_preview"]["safety_report"] = nil
    assert_equal "insufficient_evidence", proposal(4)["status"]
  end

  def test_fallback_uses_next_rpof_rank_without_independent_sorting
    first = @evidence[4]["candidates"][0]
    first["eligible"] = false
    first["availability"] = "unavailable"
    first["reason"] = "SECURE availability is NONE"
    first["admission_preview"] = preview("not_admissible", ["candidate_rejected_by_fo15", "availability_unavailable"])
    row = proposal(4)
    assert_equal "feasible", row["status"]
    assert_equal "Blackwell", row.dig("preferred_hardware", "gpu_id")
    assert_equal ["A40", "Blackwell"], row["hardware_candidates"].map { |hardware| hardware["gpu_id"] }
    assert_equal 4.75, row["projected_aggregate_hourly_tracked_compute_usd"]
    @evidence[4]["candidates"].reverse!
    assert_equal "insufficient_evidence", proposal(4)["status"]
    assert_includes proposal(4)["reasons"], "invalid_rpof_candidate_order"
  end

  def test_no_admissible_candidate_and_contradictory_summary_are_not_feasible
    refuse(@evidence[4], "no_currently_eligible_authorized_candidate")
    assert_equal "infeasible", proposal(4)["status"]
    @evidence[4]["admission_preview"] = preview("admissible_under_current_authority")
    assert_equal "insufficient_evidence", proposal(4)["status"]
    @evidence[4] = provider_evidence(4)
    @evidence[4]["admission_preview"] = preview("not_admissible", ["bad"])
    assert_equal "insufficient_evidence", proposal(4)["status"]
  end

  def test_cost_is_copied_and_completion_estimate_is_separate_from_crash_liability
    row = proposal(4)
    assert_equal 2.75, row["projected_aggregate_hourly_tracked_compute_usd"]
    assert_equal 3600.0, row["estimated_remaining_seconds"]
    assert_equal 2.75, row["estimated_remaining_tracked_compute_usd"]
    assert_equal @evidence[4]["authority"]["billing_scope"], row["billing_scope"]
    assert_equal @evidence[4]["authority"], row["rpof_authority"]
    assert_equal @evidence[4]["candidates"][0]["admission_preview"], row["hardware_candidates"][0]["admission_preview"]
    assert_includes row["cost_basis"], "all commitments held fixed"
  end

  def test_sample_quality_linear_scaling_cold_start_and_caveats_are_visible
    @wlo["throughput"]["sample_count"] = 3
    result = compose
    assert_equal 3, result["sample_count"]
    assert_equal "limited", result["evidence_quality"]
    assert result["proposals"].all? { |row| row["sample_count"] == 3 && row["evidence_quality"] == "limited" }
    text = AdventureFinderDeadlineProposals.render(result)
    ["linear scaling", "excludes prospective provider cold start", "not a reservation or guarantee",
     "Actual admission must recheck", "not the total provider bill", "Samples: 3", "campaign deadline="].each do |phrase|
      assert_includes text, phrase
    end
    refute_match(/Total provider bill:|guaranteed capacity|admitted for mutation/, text)
  end

  def test_explicit_freshness_checks_are_deterministic
    @evidence[4]["observed_at_utc"] = "2026-10-04T12:00:01Z"
    assert_includes proposal(4)["reasons"], "rpof_observation_after_as_of"
    @evidence[4]["observed_at_utc"] = "2026-10-04T11:54:59Z"
    assert_includes proposal(4)["reasons"], "rpof_evidence_too_old"
    @evidence[4]["observed_at_utc"] = "2026-10-04T11:55:00Z"
    assert_equal "feasible", proposal(4)["status"]
    result = compose(as_of: "2026-10-04T12:10:00Z")
    assert_equal "insufficient_evidence", result["status"]
    assert_nil result["preferred_proposal"]
    assert_includes result["proposals"].first["reasons"], "wlo_evidence_too_old"
  end

  def test_invalid_times_and_conflicting_immutable_authority_fail_closed
    ["tomorrow", "2026-02-30T12:00:00Z", "2026-10-04T24:00:00Z"].each do |stamp|
      @evidence[4]["observed_at_utc"] = stamp
      assert_equal "insufficient_evidence", proposal(4)["status"]
    end
    @evidence[4] = provider_evidence(4)
    @evidence[5]["authority"]["limits"]["max_workers"] = 99
    assert_equal "insufficient_evidence", proposal(4)["status"]
    assert_includes proposal(4)["reasons"], "conflicting_immutable_rpof_authority"
  end

  def test_safety_identity_and_projected_rate_contradictions_fail_closed
    %w[binding_sha256 budget_id].each do |key|
      @evidence[4] = provider_evidence(4)
      @evidence[4]["candidates"][0]["admission_preview"]["safety_report"][key] = "wrong"
      assert_includes proposal(4)["reasons"], "safety_identity_mismatch"
    end
    @evidence[4] = provider_evidence(4)
    @evidence[4]["candidates"][0]["admission_preview"]["safety_report"]["hourly_compute_usd"]["projected"] = 0.01
    assert_includes proposal(4)["reasons"], "contradictory_rpof_safety_report"
  end

  def test_core_is_deterministic_with_frozen_inputs_and_no_io_or_clock
    before = JSON.generate([@wlo, @association, @evidence])
    freeze_tree(@wlo); freeze_tree(@association); freeze_tree(@evidence)
    guard = TracePoint.new(:call, :c_call) do |event|
      prohibited = [File, IO, Process].include?(event.self) || (event.self == Time && event.method_id == :now) ||
        %i[system exec spawn fork `].include?(event.method_id)
      raise "composition attempted I/O or process mutation" if prohibited
    end
    guard.enable { assert_equal JSON.generate(compose), JSON.generate(compose) }
    assert_equal before, JSON.generate([@wlo, @association, @evidence])
  end

  def test_cli_json_human_duplicate_keys_and_ownership_boundary
    Dir.mktmpdir("fo21c-") do |root|
      write = ->(name, value) { path = File.join(root, name); File.write(path, JSON.generate(value)); path }
      args = ["--measurements", write.call("wlo.json", @wlo), "--association", write.call("association.json", @association),
        "--deadline", plan_options[:deadline], "--baseline-workers", "2", "--max-workers", "6",
        "--as-of", plan_options[:as_of], "--max-evidence-age-seconds", "300"]
      @evidence.each { |count, value| args.concat(["--rpof-evidence", "#{count}=#{write.call("rpof-#{count}.json", value)}"]) }
      before = Dir.glob("#{root}/*").to_h { |path| [path, File.binread(path)] }
      out, err, status = cli(*args, "--json")
      assert status.success?, err
      assert_equal compose, JSON.parse(out)
      text, err, status = cli(*args)
      assert status.success?, err
      assert_equal AdventureFinderDeadlineProposals.render(compose), text
      assert_equal before, Dir.glob("#{root}/*").to_h { |path| [path, File.binread(path)] }
      _out, err, status = cli(*args, "--rpof-evidence", "4=unused")
      refute status.success?
      assert_includes err, "duplicate RPOF evidence"
    end
    source = File.read(File.join(ROOT, "lib/adventure_finder_deadline_proposals.rb"))
    assert_equal ['require_relative "adventure_finder_deadline_plan"'], source.lines.grep(/^require/).map(&:strip)
    refute_match(/File\.|IO\.|Net::|Open3|Process\.|Time\.now|execution\.json|jobs\.json/, source)
    # Other tests may legitimately load sibling public contracts in this process.
    # Inspect the composition module's dependencies in a fresh Ruby process.
    script = <<~'RUBY'
      require "json"
      require "adventure_finder_deadline_proposals"
      puts JSON.generate($LOADED_FEATURES.grep(/runpod[_-]ollama[_-]fleet|workload[_-]orchestrator\//))
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.join(ROOT, "lib"), "-e", script)
    assert status.success?, err
    assert_empty JSON.parse(out)
  end

  private

  def compose(**options)
    AdventureFinderDeadlineProposals.compose(wlo: @wlo, association: @association, rpof_evidence: @evidence,
      max_evidence_age_seconds: 300, **plan_options.merge(options))
  end

  def plan_options
    { deadline: "2026-10-04T13:00:00Z", baseline_workers: 2, max_workers: 6, as_of: "2026-10-04T12:00:00Z" }
  end

  def proposal(count)
    compose.fetch("proposals").find { |row| row["worker_count"] == count }
  end

  def preview(status = "admissible_under_current_authority", reasons = [])
    { "status" => status, "reasons" => reasons, "mutation_permission" => false }
  end

  # String-keyed public-document fixtures following the inspected landed v0.1
  # contracts. No owner implementation, lifecycle adapter or provider is loaded.
  def provider_evidence(count)
    deadline = "2026-10-04T15:00:00Z"
    billing = { "label" => "runpod_pod_compute_only", "bounded" => ["RunPod pod compute"],
      "not_proven_bounded" => ["storage", "network", "taxes", "credits", "other provider charges"],
      "requested_resources" => { "global_volume" => { "created_by_campaign" => false, "priced_in_ledger" => false } },
      "charges_may_continue_outside_cap" => true }
    document = @association.merge(
      "contract_version" => "rpof-capacity-planning-evidence/v0.1", "read_only" => true,
      "observed_at_utc" => "2026-10-04T12:00:00Z", "catalog_error" => nil,
      "proposal" => { "profile_workers" => count, "additional_workers" => count,
        "projected_campaign_workers" => count + 1, "basis" => "absolute profile target; preserve all active and pending commitments; no retirement credit" },
      "authority" => { "budget_id" => @association["budget_id"],
        "limits" => { "max_workers" => 8, "max_aggregate_hourly_rate_usd" => 10.0,
          "max_cumulative_compute_usd" => 30.0, "max_runtime_seconds" => 14400,
          "guardian_poll_seconds" => 5, "orchestrator_heartbeat_timeout_seconds" => 30, "teardown_reserve_seconds" => 120 },
        "deadline" => { "derivation" => "armed_at_utc + max_runtime_seconds", "absolute_value" => "established once at arm" },
        "crash_liability" => { "horizon_seconds" => 155, "maximum_additional_compute_usd_at_hourly_ceiling" => 0.430556 },
        "billing_scope" => billing, "paid_start_gate" => "not evaluated until retained authority and guardian evidence exist",
        "phase" => "ARMED", "parent_budget_state" => "ARMED", "original_deadline_at_utc" => deadline,
        "profile_max_workers" => 6, "active_workers" => 1, "pending_or_ambiguous_workers" => 0,
        "committed_profile_workers" => 0, "committed_hourly_rate_usd" => 0.75,
        "accrued_compute_usd" => 0.75, "committed_maximum_liability_usd" => 0.782292,
        "remaining_uncommitted_compute_usd" => 29.217708 },
      "admission_preview" => preview,
      "availability_semantics" => "current catalog observation for one GPU; not reserved, guaranteed, or proof of proposed-count capacity",
      "projection_semantics" => "committed campaign rate plus additional profile workers at candidate rate; existing FO-08 crash horizon, not completion cost",
      "consistency" => "point-in-time observations; actual admission must recheck current authority"
    )
    document["candidates"] = [["A40", 0.5], ["Blackwell", 1.0]].map.with_index do |(gpu, rate), index|
      aggregate = 0.75 + count * rate
      safety = @association.slice("campaign_id", "campaign_identity_sha256", "binding_sha256", "budget_id").merge(
        "contract_version" => "rpof-capacity-campaign-safety-report/v0.1", "safety_gate" => "PASS", "refusal_reasons" => [],
        "workers" => { "active" => 1, "pending_or_ambiguous" => 0, "committed_and_pending" => 1, "projected" => count + 1, "maximum" => 8 },
        "hourly_compute_usd" => { "active" => 0.75, "pending_or_ambiguous" => 0, "committed_and_pending" => 0.75, "projected" => aggregate, "maximum" => 10.0 },
        "cumulative_compute_usd" => { "maximum" => 30, "accrued" => 0.75, "committed_and_pending_maximum_liability" => 0.782292,
          "remaining_uncommitted_authority" => 29.217708, "projected_maximum_liability" => 0.75 + aggregate * 155 / 3600,
          "remaining_after_projection" => 29.25 - aggregate * 155 / 3600 },
        "runtime" => { "maximum_seconds" => 14400, "armed_at_utc" => "2026-10-04T11:00:00Z", "original_deadline_at_utc" => deadline, "remaining_seconds" => 10800 },
        "crash_liability" => { "guardian_poll_seconds" => 5, "orchestrator_heartbeat_timeout_seconds" => 30, "teardown_reserve_seconds" => 120,
          "horizon_seconds" => 155, "maximum_additional_compute_usd_after_orchestrator_loss" => aggregate * 155 / 3600,
          "derivation" => "projected hourly compute * crash horizon / 3600" },
        "enforcement" => { "guardian_healthy_and_armed" => true, "guardian_identity_matches" => true },
        "billing_scope" => billing, "absolute_refusal_conditions" => ["original_deadline_expired"]
      )
      { "rank" => index + 1, "gpu_id" => gpu, "cloud" => "SECURE", "hourly_rate_usd" => rate,
        "authorized" => true, "eligible" => true, "reason" => nil, "price_status" => "observed",
        "availability" => "reported_available", "provider_availability" => "HIGH",
        "projected_aggregate_hourly_rate_usd" => aggregate,
        "admission_preview" => preview.merge("safety_report" => safety, "error" => nil) }
    end
    document
  end

  def refuse(evidence, reason, status: "not_admissible")
    evidence["admission_preview"] = preview(status, [reason])
    evidence["candidates"].each { |row| row["admission_preview"] = preview(status, [reason]).merge("safety_report" => nil, "error" => nil) }
  end

  def change_deadline(value)
    @evidence.each_value do |evidence|
      evidence["authority"]["original_deadline_at_utc"] = value
      evidence["candidates"].each { |row| row["admission_preview"]["safety_report"]["runtime"]["original_deadline_at_utc"] = value }
    end
  end

  def freeze_tree(value)
    value.each { |key, child| key.freeze; freeze_tree(child) } if value.is_a?(Hash)
    value.each { |child| freeze_tree(child) } if value.is_a?(Array)
    value.freeze
  end

  def cli(*args)
    Open3.capture3(RbConfig.ruby, File.join(ROOT, "bin/af-deadline-proposals"), *args)
  end
end
