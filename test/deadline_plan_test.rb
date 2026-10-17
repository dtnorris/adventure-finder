# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "support/runtime_dependency_isolation"
require_relative "../lib/adventure_finder_deadline_plan"

class DeadlinePlanTest < Minitest::Test
  include RuntimeDependencyIsolation
  def measurements
    {
      "contract_version" => "wlo-execution-measurements/v0.1", "read_only" => true,
      "measured_at_utc" => "2026-10-04T12:00:00Z",
      "execution" => { "window" => {
        "status" => "available", "started_at_utc" => "2026-10-04T11:00:00Z",
        "ended_at_utc" => "2026-10-04T12:00:00Z", "elapsed_seconds" => 3600.0
      } },
      "work" => { "remaining_jobs" => 12 },
      "throughput" => {
        "status" => "available", "sample_count" => 6,
        "denominator_seconds" => 3600.0, "jobs_per_hour" => 6.0
      }
    }
  end

  def plan(wlo = measurements, **options)
    AdventureFinderDeadlinePlan.plan(wlo: wlo, deadline: "2026-10-04T13:00:00Z",
                                     baseline_workers: 2, **options)
  end

  def assert_insufficient(wlo = measurements, **options)
    result = plan(wlo, **options)
    assert_equal "insufficient_evidence", result["status"]
    refute_nil result["reason"]
    assert_empty result["candidates"]
    assert_nil result["minimum_candidate_workers_meeting_deadline"]
    result
  end

  def test_linear_candidates_and_smallest_meeting_candidate
    result = plan
    assert_equal "adventurefinder-deadline-burst-plan/v0.1", result["contract_version"]
    assert_equal "plan_available", result["status"]
    assert result["read_only"]
    assert result["planning_only"]
    assert_equal 3600, result["seconds_until_deadline"]
    assert_equal 12, result["remaining_jobs"]
    assert_equal 6, result["sample_count"]
    assert_equal 6, result["measured_baseline_jobs_per_hour"]
    assert_equal 3600, result.dig("measurement_window", "throughput_denominator_seconds")
    assert_equal [2, 3, 4], result["candidates"].map { |row| row["worker_count"] }
    baseline, middle, last = result["candidates"]
    assert_equal [1.0, 6.0, 7200.0, -3600.0, false], baseline.values_at(
      "scaling_factor", "estimated_jobs_per_hour", "estimated_remaining_seconds",
      "deadline_margin_seconds", "mathematically_meets_deadline"
    )
    assert_equal 4800, middle["estimated_remaining_seconds"]
    assert_equal "2026-10-04T13:00:00.000000000Z", last["estimated_completion_at_utc"]
    assert_equal 0, last["deadline_margin_seconds"]
    assert last["mathematically_meets_deadline"]
    assert_equal 4, result["minimum_candidate_workers_meeting_deadline"]
    result["candidates"].each do |row|
      assert_equal 6, row["sample_count"]
      assert_equal "measured", row["evidence_quality"]
    end
  end

  def test_completion_before_deadline_and_no_candidate_meeting_deadline
    result = plan(deadline: "2026-10-04T15:00:00Z")
    assert_equal 2, result["minimum_candidate_workers_meeting_deadline"]
    assert_equal 3600, result["candidates"].first["deadline_margin_seconds"]
    bounded = plan(max_workers: 3)
    assert_equal "plan_available", bounded["status"]
    assert_nil bounded["minimum_candidate_workers_meeting_deadline"]
    assert_equal [2, 3], bounded["candidates"].map { |row| row["worker_count"] }
  end

  def test_complete_even_without_rate_or_baseline_and_after_deadline
    wlo = measurements
    wlo["work"]["remaining_jobs"] = 0
    wlo["throughput"] = { "status" => "unavailable", "sample_count" => 0 }
    result = plan(wlo, baseline_workers: nil, deadline: "2026-10-04T11:00:00Z")
    assert_equal "complete", result["status"]
    assert_empty result["candidates"]
    assert_equal 0, result["sample_count"]
    assert_equal "none", result["evidence_quality"]
  end

  def test_deadline_passed_and_exact_deadline_without_estimates
    %w[2026-10-04T11:00:00Z 2026-10-04T12:00:00Z].each do |deadline|
      result = plan(deadline: deadline, baseline_workers: nil)
      assert_equal "deadline_passed", result["status"]
      assert_empty result["candidates"]
    end
  end

  def test_unavailable_or_invalid_rate_and_samples
    mutations = [
      ["status", "unavailable"], ["sample_count", 0], ["sample_count", nil],
      ["sample_count", -1], ["sample_count", 1.5], ["jobs_per_hour", 0],
      ["jobs_per_hour", -1], ["jobs_per_hour", "6"], ["jobs_per_hour", nil],
      ["jobs_per_hour", Float::NAN], ["jobs_per_hour", Float::INFINITY]
    ]
    mutations.each do |key, value|
      wlo = measurements
      wlo["throughput"][key] = value
      assert_insufficient(wlo)
    end
    [nil, [], "missing"].each do |value|
      wlo = measurements
      wlo["throughput"] = value
      assert_insufficient(wlo)
    end
  end

  def test_wrong_contract_and_missing_or_invalid_work
    [nil, [], {}, measurements.merge("contract_version" => "v99"),
     measurements.merge("read_only" => false)].each { |wlo| assert_insufficient(wlo) }
    [nil, -1, 1.5, "12", 10**100].each do |remaining|
      wlo = measurements
      wlo["work"]["remaining_jobs"] = remaining
      assert_insufficient(wlo)
    end
    assert_insufficient(measurements.merge("work" => []))
  end

  def test_timestamps_must_be_valid_absolute_and_consistent
    [nil, "tonight", "2026-10-04", "2026-10-04T13:00:00", "2026-02-30T13:00:00Z",
     "2026-10-04T24:00:00Z", "2026-10-04T13:00:60Z"].each do |deadline|
      assert_insufficient(deadline: deadline)
    end
    assert_insufficient(measurements.merge("measured_at_utc" => "bad"))
    assert_insufficient(as_of: "2026-10-04T11:59:59Z")
    assert_insufficient(as_of: "bad")
    ["2026-10-04T12:00:01Z", "2026-10-04T10:00:00Z", "bad"].each do |ended|
      wlo = measurements
      wlo["execution"]["window"]["ended_at_utc"] = ended
      assert_insufficient(wlo)
    end
    assert_equal plan, plan(deadline: "2026-10-04T15:00:00+02:00")
  end

  def test_window_unavailable_and_inconsistent_denominators
    [nil, {}, { "status" => "unavailable" }].each do |window|
      wlo = measurements
      wlo["execution"]["window"] = window
      assert_insufficient(wlo)
    end
    [0, -1, nil, 3590, Float::INFINITY].each do |denominator|
      wlo = measurements
      wlo["throughput"]["denominator_seconds"] = denominator
      assert_insufficient(wlo)
    end
    wlo = measurements
    wlo["throughput"]["denominator_seconds"] = 3600.5
    wlo["execution"]["window"]["elapsed_seconds"] = 3600.5
    assert_equal "plan_available", plan(wlo)["status"]
  end

  def test_baseline_and_candidate_bounds_are_explicit_bounded_integers
    [nil, 0, -1, 2.0, "2", true, 10**100].each { |value| assert_insufficient(baseline_workers: value) }
    [0, -1, 1, 4.0, "4", false, 1002, 10**100].each { |value| assert_insufficient(max_workers: value) }
    assert_equal 1, plan(max_workers: 2)["candidates"].length
    assert_equal 1000, plan(max_workers: 1001)["candidates"].length
    assert_insufficient(baseline_workers: AdventureFinderDeadlinePlan::MAX_INTEGER)
  end

  def test_extreme_rates_fail_without_overflow_or_partial_candidates
    [1e-300, 1e308].each do |rate|
      wlo = measurements
      wlo["throughput"]["jobs_per_hour"] = rate
      assert_insufficient(wlo)
    end
  end

  def test_quality_is_sample_size_label_not_statistical_confidence
    [1, 4, 5].each do |samples|
      wlo = measurements
      wlo["throughput"]["sample_count"] = samples
      result = plan(wlo)
      assert_equal(samples < 5 ? "limited" : "measured", result["evidence_quality"])
      assert_equal samples, result["sample_count"]
      assert result["candidates"].all? { |row| row["sample_count"] == samples }
    end
  end

  def test_explicit_as_of_holds_work_fixed_and_does_not_extend_deadline
    result = plan(as_of: "2026-10-04T12:30:00Z")
    assert_equal 1800, result["seconds_until_deadline"]
    assert_equal "2026-10-04T13:00:00.000000000Z", result["deadline_utc"]
    assert_equal "2026-10-04T14:30:00.000000000Z", result["candidates"].first["estimated_completion_at_utc"]
    assert_nil result["minimum_candidate_workers_meeting_deadline"]
  end

  def test_deterministic_with_frozen_input_and_no_clock_or_io
    wlo = measurements
    before = JSON.generate(wlo)
    freeze_tree(wlo)
    guard = TracePoint.new(:call, :c_call) do |event|
      clock = event.self == Time && event.method_id == :now
      io = [File, IO, Process].include?(event.self)
      raise "planner attempted clock or I/O" if clock || io
    end
    guard.enable do
      assert_equal JSON.generate(plan(wlo)), JSON.generate(plan(wlo))
    end
    assert_equal before, JSON.generate(wlo)
  end

  def test_visible_assumptions_and_no_runtime_authority_dependencies
    assumptions = plan["assumptions"].join(" ")
    ["current baseline", "caller planning context", "linear scaling", "cold start", "model load",
     "provider startup", "contention", "failures", "diminishing returns",
     "availability, cost, feasibility and admission are not evaluated"].each do |text|
      assert_includes assumptions, text
    end
    source = File.read(File.expand_path("../lib/adventure_finder_deadline_plan.rb", __dir__))
    assert_equal ['require "time"'], source.lines.grep(/^require/).map(&:strip)
    refute_match(/File\.|IO\.|Net::|Open3|Process\.|Kernel\.|Time\.now|execution\.json|system\(|`/, source)
    refute_match(/rpof|runpod|adventure_finder_workspace|workload_orchestrator\//i, source)
    forbidden = loaded_features_in_subprocess(
      File.expand_path("../lib/adventure_finder_deadline_plan.rb", __dir__)
    ).grep(/local[_-]ollama[_-]workers|runpod[_-]ollama[_-]fleet/i)
    assert_empty forbidden
  end

  private

  def freeze_tree(value)
    value.each { |key, child| key.freeze; freeze_tree(child) } if value.is_a?(Hash)
    value.each { |child| freeze_tree(child) } if value.is_a?(Array)
    value.freeze
  end
end
