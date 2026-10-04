# frozen_string_literal: true

require_relative "adventure_finder_deadline_plan"

module AdventureFinderDeadlineProposals
  CONTRACT_VERSION = "adventurefinder-deadline-burst-proposals/v0.1"
  PLAN_VERSION = "adventurefinder-deadline-burst-plan/v0.1"
  RPOF_VERSION = "rpof-capacity-planning-evidence/v0.1"
  SAFETY_VERSION = "rpof-capacity-campaign-safety-report/v0.1"
  IDENTITY_KEYS = %w[campaign_id campaign_identity_sha256 binding_sha256 budget_id profile_id capability_fingerprint].freeze
  PREVIEW_STATES = %w[admissible_under_current_authority not_admissible insufficient_evidence].freeze
  ASSUMPTIONS = [
    "The caller explicitly associates this WLO measurement and baseline worker count with one RPOF profile/capability.",
    "Estimated completion excludes prospective provider cold start; startup time is unknown, not assumed measured as zero.",
    "Provider availability is a catalog observation, not a reservation or guarantee of proposed-count capacity.",
    "Remaining tracked compute assumes the entire RPOF projected campaign rate, including existing commitments, persists for the estimated duration.",
    "Tracked RunPod pod compute excludes charges outside the RPOF billing scope; completion cost is not the total provider bill or FO-08 crash liability.",
    "Feasibility is advisory under these assumptions. Actual admission must recheck current evidence; mutation permission is always false."
  ].freeze

  class Invalid < StandardError; end

  # FO-21A is invoked here so a caller cannot accidentally attach a plan derived
  # from another measurement. This API accepts documents, never owner state paths.
  def self.compose(wlo:, deadline:, baseline_workers:, max_workers: nil, as_of:,
                   max_evidence_age_seconds:, association:, rpof_evidence:)
    plan = AdventureFinderDeadlinePlan.plan(wlo:, deadline:, baseline_workers:, max_workers:, as_of:)
    Composer.new(plan:, association:, rpof_evidence:, max_evidence_age_seconds:, explicit_as_of: !as_of.nil?).document
  end

  class Composer
    def initialize(plan:, association:, rpof_evidence:, max_evidence_age_seconds:, explicit_as_of:)
      @plan = copy(plan)
      @association = copy(association)
      @evidence = copy(rpof_evidence)
      @age = max_evidence_age_seconds
      @explicit_as_of = explicit_as_of
    end

    def document
      output = {
        "contract_version" => CONTRACT_VERSION, "read_only" => true, "planning_only" => true,
        "mutation_permission" => false, "status" => "insufficient_evidence", "reasons" => [],
        "association" => @association, "wlo_measured_at_utc" => @plan["measured_at_utc"],
        "as_of_utc" => @plan["as_of_utc"], "target_completion_deadline_utc" => @plan["deadline_utc"],
        "max_evidence_age_seconds" => @age, "sample_count" => @plan["sample_count"],
        "evidence_quality" => @plan["evidence_quality"], "deadline_plan" => @plan,
        "assumptions" => ASSUMPTIONS.map(&:dup), "planner_assumptions" => @plan["assumptions"],
        "proposals" => [], "recommendation_order" => [], "preferred_proposal" => nil
      }
      begin
        check(@explicit_as_of, "explicit_as_of_required")
        check(@plan["contract_version"] == PLAN_VERSION &&
              @plan["read_only"] == true && @plan["planning_only"] == true, "invalid_deadline_plan_contract")
        check(@association.is_a?(Hash) && IDENTITY_KEYS.all? { |key| nonempty?(@association[key]) }, "invalid_association")
        %w[campaign_identity_sha256 binding_sha256 capability_fingerprint].each do |key|
          check(@association[key].match?(/\A[0-9a-f]{64}\z/), "invalid_association_#{key}")
        end
        check(@age.is_a?(Integer) && @age >= 0, "invalid_max_evidence_age_seconds")
        check(@evidence.is_a?(Hash) && @evidence.keys.all? { |key| key.is_a?(Integer) && key.positive? }, "invalid_evidence_keys")
        if @plan["status"] != "plan_available"
          output["status"] = { "complete" => "complete", "deadline_passed" => "infeasible" }.fetch(@plan["status"], "insufficient_evidence")
          output["reasons"] = [@plan["reason"] || @plan["status"]]
          return output
        end
        @planning = timestamp(@plan["as_of_utc"])
        measured = timestamp(@plan["measured_at_utc"])
        @measurement_stale = @planning - measured > @age
        @authority_conflict = conflicting_authority?
        output["proposals"] = @plan.fetch("candidates").map { |candidate| proposal(candidate) }
        feasible = output["proposals"].select { |row| row["status"] == "feasible" }.sort_by { |row| row.fetch("worker_count") }
        output["recommendation_order"] = feasible.map { |row| row.fetch("worker_count") }
        output["preferred_proposal"] = feasible.first && feasible.first.slice("worker_count", "preferred_hardware", "estimated_completion_at_utc",
          "projected_aggregate_hourly_tracked_compute_usd", "estimated_remaining_tracked_compute_usd")
        output["status"] = if feasible.any?
                             "feasible"
                           elsif output["proposals"].any? { |row| row["status"] == "insufficient_evidence" }
                             "insufficient_evidence"
                           else
                             "infeasible"
                           end
        output["reasons"] = output["proposals"].flat_map { |row| row.fetch("reasons") }.uniq unless feasible.any?
      rescue Invalid, KeyError, TypeError => e
        output["reasons"] = [e.message]
      end
      output
    end

    private

    def proposal(candidate)
      row = copy(candidate).merge(
        "status" => "insufficient_evidence", "reasons" => [], "mutation_permission" => false,
        "rpof_observed_at_utc" => nil, "rpof_campaign_deadline_utc" => nil,
        "rpof_admission_preview" => nil, "rpof_authority" => nil, "hardware_candidates" => [],
        "preferred_hardware" => nil, "projected_aggregate_hourly_tracked_compute_usd" => nil,
        "estimated_remaining_tracked_compute_usd" => nil,
        "cost_basis" => "projected campaign hourly compute * FO-21A estimated remaining seconds / 3600; all commitments held fixed",
        "billing_scope" => nil, "provider_caveats" => nil
      )
      mathematical_failure = candidate.fetch("mathematically_meets_deadline") == false
      row["reasons"] << "mathematical_deadline_missed" if mathematical_failure
      row["reasons"] << "wlo_evidence_too_old" if @measurement_stale
      hard_deadline = false
      begin
        check(!@authority_conflict, "conflicting_immutable_rpof_authority")
        evidence = @evidence[candidate.fetch("worker_count")]
        check(evidence.is_a?(Hash), "missing_matching_rpof_evidence")
        validate_evidence(evidence, candidate.fetch("worker_count"))
        observed = timestamp(evidence.fetch("observed_at_utc"))
        authority = evidence.fetch("authority")
        campaign_deadline = timestamp(authority.fetch("original_deadline_at_utc"))
        row.merge!("rpof_observed_at_utc" => evidence.fetch("observed_at_utc"),
          "rpof_campaign_deadline_utc" => authority.fetch("original_deadline_at_utc"),
          "rpof_admission_preview" => evidence.fetch("admission_preview"), "rpof_authority" => authority,
          "billing_scope" => authority.fetch("billing_scope"),
          "provider_caveats" => evidence.slice("availability_semantics", "projection_semantics", "consistency"))
        if campaign_deadline <= @planning
          hard_deadline = true
          row["reasons"] << "rpof_campaign_deadline_expired"
        elsif timestamp(candidate.fetch("estimated_completion_at_utc")) > campaign_deadline
          hard_deadline = true
          row["reasons"] << "rpof_authority_expires_before_estimated_completion"
        end
        check(observed <= @planning, "rpof_observation_after_as_of")
        check(@planning - observed <= @age, "rpof_evidence_too_old")
        rows = evidence.fetch("candidates")
        # Retain FO-15 ordering, including rejected alternatives. No hardware sorting.
        row["hardware_candidates"] = rows.map do |hardware|
          rate = hardware["projected_aggregate_hourly_rate_usd"]
          estimate = hardware["price_status"] == "observed" && number?(rate) ?
            rate * candidate.fetch("estimated_remaining_seconds") / 3600.0 : nil
          hardware.merge("estimated_remaining_tracked_compute_usd" => estimate&.finite? ? estimate : nil)
        end
        preview = evidence.fetch("admission_preview")
        status = preview.fetch("status")
        selected = rows.find { |hardware| admissible?(hardware) }
        any_admissible = rows.any? { |hardware| hardware.dig("admission_preview", "status") == "admissible_under_current_authority" }
        if status == "admissible_under_current_authority"
          check(selected && preview.fetch("reasons").empty? && evidence["catalog_error"].nil?, "contradictory_admissible_evidence")
          rate = selected.fetch("projected_aggregate_hourly_rate_usd")
          estimate = rate * candidate.fetch("estimated_remaining_seconds") / 3600.0
          check(estimate.finite?, "completion_compute_estimate_out_of_range")
          row.merge!("preferred_hardware" => selected.slice("gpu_id", "cloud", "rank"),
            "projected_aggregate_hourly_tracked_compute_usd" => rate,
            "estimated_remaining_tracked_compute_usd" => estimate)
          row["status"] = @measurement_stale ? "insufficient_evidence" : "feasible"
        else
          check(!any_admissible, "contradictory_admission_preview")
          check(!rows.empty?, "missing_candidate_evidence")
          row["status"] = status == "not_admissible" ? "infeasible" : "insufficient_evidence"
          row["reasons"].concat(preview.fetch("reasons"))
          row["reasons"] << "rpof_#{status}"
        end
      rescue Invalid, KeyError, TypeError => e
        row["reasons"] << e.message
      end
      row["status"] = "infeasible" if (mathematical_failure && !@measurement_stale) || hard_deadline
      row["reasons"].uniq!
      row
    end

    def validate_evidence(evidence, count)
      check(evidence["contract_version"] == RPOF_VERSION && evidence["read_only"] == true, "invalid_rpof_contract")
      check(IDENTITY_KEYS.all? { |key| evidence[key] == @association[key] }, "rpof_identity_mismatch")
      check(evidence.dig("proposal", "profile_workers").is_a?(Integer) && evidence.dig("proposal", "profile_workers") == count,
        "rpof_proposed_worker_count_mismatch")
      validate_preview(evidence.fetch("admission_preview"))
      authority = evidence.fetch("authority")
      check(authority.is_a?(Hash) && authority["billing_scope"].is_a?(Hash) &&
        authority.dig("billing_scope", "label") == "runpod_pod_compute_only", "invalid_rpof_authority_or_billing_scope")
      candidates = evidence.fetch("candidates")
      check(candidates.is_a?(Array) && candidates.all?(Hash), "invalid_rpof_candidates")
      ids = candidates.map { |hardware| [hardware["gpu_id"], hardware["cloud"]] }
      check(ids.uniq == ids && ids.flatten.all? { |id| nonempty?(id) }, "invalid_candidate_identity")
      ranks = candidates.map { |hardware| hardware["rank"] }
      if evidence["catalog_error"]
        check(ranks.all?(&:nil?), "invalid_unavailable_catalog_ranks")
      else
        check(ranks == (1..candidates.length).to_a, "invalid_rpof_candidate_order")
      end
      candidates.each do |hardware|
        check(hardware["authorized"] == true, "unauthorized_candidate_in_evidence")
        validate_preview(hardware.fetch("admission_preview"))
        next unless hardware.dig("admission_preview", "status") == "admissible_under_current_authority"
        check(admissible?(hardware), "incomplete_admissible_candidate_evidence")
        safety = hardware.dig("admission_preview", "safety_report")
        check(safety.is_a?(Hash) && safety["contract_version"] == SAFETY_VERSION && safety["safety_gate"] == "PASS" &&
          safety["refusal_reasons"] == [], "invalid_rpof_safety_report")
        check(%w[campaign_id campaign_identity_sha256 binding_sha256 budget_id].all? { |key| safety[key] == evidence[key] },
          "safety_identity_mismatch")
        check(safety.dig("workers", "projected") == evidence.dig("proposal", "projected_campaign_workers") &&
          safety.dig("hourly_compute_usd", "projected") == hardware["projected_aggregate_hourly_rate_usd"] &&
          safety.dig("runtime", "original_deadline_at_utc") == authority["original_deadline_at_utc"], "contradictory_rpof_safety_report")
      end
      states = candidates.map { |hardware| hardware.dig("admission_preview", "status") }
      expected = PREVIEW_STATES.find { |state| state != "not_admissible" && states.include?(state) } || "not_admissible"
      check(evidence.dig("admission_preview", "status") == expected, "contradictory_admission_preview")
    end

    def admissible?(hardware)
      hardware["authorized"] == true && hardware["eligible"] == true &&
        hardware["price_status"] == "observed" && hardware["availability"] == "reported_available" &&
        number?(hardware["hourly_rate_usd"], positive: true) && number?(hardware["projected_aggregate_hourly_rate_usd"]) &&
        hardware.dig("admission_preview", "status") == "admissible_under_current_authority" &&
        hardware.dig("admission_preview", "mutation_permission") == false && hardware.dig("admission_preview", "reasons") == []
    end

    def validate_preview(value)
      check(value.is_a?(Hash) && PREVIEW_STATES.include?(value["status"]) && value["mutation_permission"] == false &&
        value["reasons"].is_a?(Array) && value["reasons"].all?(String), "invalid_rpof_admission_preview")
    end

    def conflicting_authority?
      used = Array(@plan["candidates"]).filter_map do |candidate|
        value = @evidence[candidate["worker_count"]]
        next unless value.is_a?(Hash) && IDENTITY_KEYS.all? { |key| value[key] == @association[key] }
        authority = value["authority"]
        next unless authority.is_a?(Hash)
        authority.slice("limits", "original_deadline_at_utc", "profile_max_workers", "billing_scope")
      end
      used.uniq.length > 1
    end

    def timestamp(value)
      check(value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,9})?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)\z/), "invalid_evidence_timestamp")
      Date.iso8601(value[0, 10])
      parsed = Time.iso8601(value).utc
      check(parsed.year.between?(1, 9999), "invalid_evidence_timestamp")
      parsed
    rescue ArgumentError
      raise Invalid, "invalid_evidence_timestamp"
    end

    def check(condition, reason)
      raise Invalid, reason unless condition
    end

    def nonempty?(value)
      value.is_a?(String) && !value.empty?
    end

    def number?(value, positive: false)
      (value.is_a?(Integer) || value.is_a?(Float)) && value.to_f.finite? && (positive ? value > 0 : value >= 0)
    end

    def copy(value)
      case value
      when Hash then value.to_h { |key, child| [copy(key), copy(child)] }
      when Array then value.map { |child| copy(child) }
      when String then value.dup
      else value
      end
    end
  end
  private_constant :Composer

  def self.render(document)
    lines = ["AdventureFinder deadline proposals (read-only, advisory)",
      "Status: #{document.fetch('status')}; target completion: #{document['target_completion_deadline_utc']}",
      "Samples: #{document['sample_count']}; evidence: #{document['evidence_quality']}",
      "WLO measured: #{document['wlo_measured_at_utc']}; planning: #{document['as_of_utc']}"]
    document.fetch("proposals").each do |row|
      lines << "Workers=#{row['worker_count']} #{row['status']}; completion=#{row['estimated_completion_at_utc']}; " \
        "remaining=#{row['estimated_remaining_seconds']}s; margin=#{row['deadline_margin_seconds']}s"
      lines << "  RPOF observed=#{row['rpof_observed_at_utc']}; campaign deadline=#{row['rpof_campaign_deadline_utc']}; " \
        "admission preview=#{row.dig('rpof_admission_preview', 'status')}"
      lines << "  Tracked campaign compute/hour=#{row['projected_aggregate_hourly_tracked_compute_usd'] || 'unavailable'}; " \
        "estimated remaining compute=#{row['estimated_remaining_tracked_compute_usd'] || 'unavailable'}"
      row.fetch("hardware_candidates").each do |hardware|
        lines << "  rank=#{hardware['rank']} GPU=#{hardware['gpu_id']} cloud=#{hardware['cloud']} " \
          "availability=#{hardware['availability']} price=#{hardware['price_status']} " \
          "projected compute/hour=#{hardware['projected_aggregate_hourly_rate_usd']} " \
          "preview=#{hardware.dig('admission_preview', 'status')} " \
          "reasons=#{hardware.dig('admission_preview', 'reasons').join(', ')}"
      end
      lines << "  Reasons: #{row['reasons'].join(', ')}" unless row['reasons'].empty?
    end
    lines << "Preferred worker count: #{document.dig('preferred_proposal', 'worker_count') || 'none'}"
    lines << "Reasons: #{document['reasons'].join(', ')}" unless document['reasons'].empty?
    lines.concat(Array(document["planner_assumptions"]).map { |value| "FO-21A assumption: #{value}" })
    lines.concat(document.fetch("assumptions").map { |value| "Composition assumption: #{value}" })
    lines.join("\n") + "\n"
  end
end
