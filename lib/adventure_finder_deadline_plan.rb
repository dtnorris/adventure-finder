# frozen_string_literal: true

require "time"

module AdventureFinderDeadlinePlan
  CONTRACT_VERSION = "adventurefinder-deadline-burst-plan/v0.1"
  WLO_VERSION = "wlo-execution-measurements/v0.1"
  MAX_INTEGER = (2**53) - 1
  MAX_CANDIDATES = 1000
  ASSUMPTIONS = [
    "Measured cumulative WLO throughput is treated as the current baseline.",
    "Baseline workers are explicit caller planning context, not observed provider authority.",
    "Candidate throughput assumes approximately linear scaling with worker count.",
    "Queueing, cold start, model load, provider startup, contention, failures and diminishing returns " \
      "are not separately modeled; their historical effects may already be present in WLO wall-clock measurements.",
    "Provider availability, cost, feasibility and admission are not evaluated.",
    "Remaining work is held fixed at the measurement; an explicit later as_of does not extrapolate progress."
  ].freeze

  class Invalid < StandardError; end

  def self.plan(wlo:, deadline:, baseline_workers: nil, max_workers: nil, as_of: nil)
    result = {
      "contract_version" => CONTRACT_VERSION, "read_only" => true, "planning_only" => true,
      "status" => "insufficient_evidence", "reason" => nil,
      "measured_at_utc" => nil, "as_of_utc" => nil, "deadline_utc" => nil,
      "seconds_until_deadline" => nil, "remaining_jobs" => nil,
      "sample_count" => nil, "evidence_quality" => "none",
      "measured_baseline_jobs_per_hour" => nil, "baseline_workers" => nil,
      "candidate_max_workers" => nil, "measurement_window" => nil,
      "assumptions" => ASSUMPTIONS.map(&:dup), "candidates" => [],
      "minimum_candidate_workers_meeting_deadline" => nil
    }
    require_evidence(wlo.is_a?(Hash) && wlo["contract_version"] == WLO_VERSION && wlo["read_only"] == true,
                     "invalid_wlo_contract")
    measured = timestamp(wlo["measured_at_utc"])
    planning = as_of.nil? ? measured : timestamp(as_of)
    target = timestamp(deadline)
    require_evidence(measured <= planning, "measurement_after_as_of")
    result.merge!("measured_at_utc" => stamp(measured), "as_of_utc" => stamp(planning),
                  "deadline_utc" => stamp(target), "seconds_until_deadline" => (target - planning))
    work = wlo["work"]
    remaining = work.is_a?(Hash) && work["remaining_jobs"]
    require_evidence(integer?(remaining, minimum: 0), "invalid_remaining_jobs")
    result["remaining_jobs"] = remaining
    throughput = wlo["throughput"]
    samples = throughput.is_a?(Hash) && throughput["sample_count"]
    if integer?(samples, minimum: 0)
      result["sample_count"] = samples
      result["evidence_quality"] = samples.zero? ? "none" : (samples < 5 ? "limited" : "measured")
    end
    # Neither complete nor expired work needs a throughput-based numerical estimate.
    if remaining.zero? || target <= planning
      result["status"] = remaining.zero? ? "complete" : "deadline_passed"
      return result
    end
    require_evidence(integer?(baseline_workers), "invalid_baseline_workers")
    maximum = max_workers.nil? ? baseline_workers + 2 : max_workers
    require_evidence(integer?(maximum) && maximum >= baseline_workers &&
                     maximum - baseline_workers < MAX_CANDIDATES, "invalid_candidate_bounds")
    result.merge!("baseline_workers" => baseline_workers, "candidate_max_workers" => maximum)
    require_evidence(throughput.is_a?(Hash) && throughput["status"] == "available", "throughput_unavailable")
    require_evidence(integer?(samples), "no_usable_throughput_samples")
    rate = throughput["jobs_per_hour"]
    require_evidence(positive_number?(rate), "invalid_throughput")
    execution = wlo["execution"]
    window = execution.is_a?(Hash) && execution["window"]
    require_evidence(window.is_a?(Hash) && window["status"] == "available", "window_unavailable")
    started = timestamp(window["started_at_utc"])
    ended = timestamp(window["ended_at_utc"])
    elapsed = window["elapsed_seconds"]
    denominator = throughput["denominator_seconds"]
    require_evidence(started < ended && ended <= measured, "inconsistent_window_times")
    # WLO timestamps omit subsecond precision while elapsed_seconds retains it.
    require_evidence(positive_number?(elapsed) && positive_number?(denominator) &&
                     (elapsed - denominator).abs <= 0.000001 &&
                     (elapsed - (ended - started)).abs < 1, "inconsistent_window_duration")
    result["measurement_window"] = {
      "started_at_utc" => stamp(started), "ended_at_utc" => stamp(ended),
      "elapsed_seconds" => elapsed, "throughput_denominator_seconds" => denominator
    }
    result["measured_baseline_jobs_per_hour"] = rate
    candidates = (baseline_workers..maximum).map do |workers|
      scale = Rational(workers, baseline_workers)
      estimated_rate = rate.to_r * scale
      duration = remaining * 3600 / estimated_rate
      finish = planning + duration
      margin = target.to_r - finish.to_r
      require_evidence(positive_number?(estimated_rate.to_f) && positive_number?(duration.to_f) &&
                       margin.to_f.finite? && finish.year.between?(1, 9999), "estimate_out_of_range")
      {
        "worker_count" => workers, "scaling_factor" => scale.to_f,
        "estimated_jobs_per_hour" => estimated_rate.to_f,
        "estimated_remaining_seconds" => duration.to_f, "estimated_completion_at_utc" => stamp(finish),
        "deadline_margin_seconds" => margin.to_f, "mathematically_meets_deadline" => margin >= 0,
        "sample_count" => samples, "evidence_quality" => result["evidence_quality"]
      }
    end
    result["candidates"] = candidates
    result["minimum_candidate_workers_meeting_deadline"] =
      candidates.find { |candidate| candidate["mathematically_meets_deadline"] }&.fetch("worker_count")
    result["status"] = "plan_available"
    result
  rescue Invalid => e
    result.merge("status" => "insufficient_evidence", "reason" => e.message)
  rescue ArgumentError, RangeError, FloatDomainError
    result.merge("status" => "insufficient_evidence", "reason" => "estimate_out_of_range")
  end

  def self.require_evidence(condition, reason)
    raise Invalid, reason unless condition
  end
  private_class_method :require_evidence

  def self.integer?(value, minimum: 1)
    value.is_a?(Integer) && value.between?(minimum, MAX_INTEGER)
  end
  private_class_method :integer?

  def self.positive_number?(value)
    (value.is_a?(Integer) || value.is_a?(Float)) && value.positive? && value.to_f.finite?
  end
  private_class_method :positive_number?

  def self.timestamp(value)
    pattern = /\A\d{4}-\d{2}-\d{2}T([01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,9})?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)\z/
    require_evidence(value.is_a?(String) && pattern.match?(value), "invalid_timestamp")
    Date.iso8601(value[0, 10]) # Time alone normalizes invalid calendar dates.
    parsed = Time.iso8601(value).utc
    require_evidence(parsed.year.between?(1, 9999), "invalid_timestamp")
    parsed
  rescue ArgumentError
    raise Invalid, "invalid_timestamp"
  end
  private_class_method :timestamp

  def self.stamp(value)
    value.utc.iso8601(9)
  end
  private_class_method :stamp
end
