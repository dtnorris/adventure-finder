# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require_relative "../lib/adventure_finder_measurements"

class AdventureFinderMeasurementsTest < Minitest::Test
  def test_wlo_only_preserves_samples_and_marks_paid_cost_unattached
    result = composition(wlo).document

    assert_equal "adventurefinder-operator-measurements/v0.1", result.fetch("contract_version")
    assert_equal({ "completed_successful_attempts" => 2 }, result.dig("samples", "wlo"))
    assert_equal "unavailable", result.dig("useful_cost", "status")
    assert_includes result.dig("useful_cost", "reason"), "no associated paid"
    assert_nil result.fetch("provider")
  end

  def test_associated_documents_time_align_useful_cost_without_recomputing_owner_metrics
    result = composition(wlo, rpof).document

    assert_equal 2.0, result.dig("throughput", "jobs_per_hour")
    assert_equal 600.0, result.dig("eta", "estimated_remaining_seconds")
    assert_equal "estimated", result.dig("useful_cost", "status")
    assert_equal 0.5, result.dig("useful_cost", "command_active_compute_usd")
    assert_equal 0.5, result.dig("useful_cost", "successful_command_compute_usd")
    assert_equal 1, result.dig("useful_cost", "matched_attempt_interval_count")
    assert_equal 0, result.dig("useful_cost", "unmatched_attempt_interval_count")
    assert_equal({ "completed_successful_attempts" => 2 }, result.dig("samples", "wlo"))
    assert_equal({ "tracked_paid_resources" => 1 }, result.dig("samples", "rpof"))
  end

  def test_unavailable_component_values_remain_unavailable
    source = wlo
    source["throughput"] = { "status" => "unavailable", "reason" => "zero samples", "sample_count" => 0 }
    source["eta"] = { "status" => "unavailable", "reason" => "zero samples", "sample_count" => 0 }

    result = composition(source).document

    assert_equal "unavailable", result.dig("throughput", "status")
    assert_equal "unavailable", result.dig("eta", "status")
  end

  def test_mismatched_worker_generation_does_not_synthesize_cost
    provider = rpof
    provider.dig("timing", "tracked_resource_intervals", 0, "worker_identity")["generation_id"] = "other"

    result = composition(wlo, provider).document

    assert_equal "unavailable", result.dig("useful_cost", "status")
    assert_includes result.dig("useful_cost", "reason"), "did not match"
  end

  def test_render_relabels_command_time_only_for_af_presentation
    text = composition(wlo, rpof).render

    assert_includes text, "Scoring/inference active wall fraction"
    assert_includes text, "Estimated useful scoring/inference compute: $0.500000"
  end

  private

  def composition(workload, provider = nil)
    AdventureFinderMeasurements::Composition.new(wlo: workload, rpof: provider)
  end

  def wlo
    {
      "contract_version" => "wlo-execution-measurements/v0.1",
      "work" => {
        "total_jobs" => 3, "completed" => 2, "running" => 0, "pending" => 1,
        "failed" => 0, "interrupted" => 0
      },
      "samples" => { "completed_successful_attempts" => 2 },
      "throughput" => { "status" => "available", "jobs_per_hour" => 2.0, "sample_count" => 2 },
      "eta" => {
        "status" => "available", "estimated_remaining_seconds" => 600.0,
        "estimated_completion_at_utc" => "2026-10-04T12:10:00Z", "sample_count" => 2
      },
      "command_execution" => {
        "active_intervals" => [{
          "job_id" => "ADV-1", "attempt" => 1, "status" => "complete",
          "started_at_utc" => "2026-10-04T11:00:00Z", "ended_at_utc" => "2026-10-04T11:30:00Z",
          "worker_identity" => { "worker_id" => "worker-1", "generation_id" => "gen-1" }
        }]
      },
      "queue_wait" => { "status" => "unavailable", "reason" => "not retained" },
      "utilization" => { "status" => "available", "busy_wall_fraction" => 0.5, "sample_count" => 1 }
    }
  end

  def rpof
    {
      "contract_version" => "rpof-provider-cost-measurements/v0.1",
      "capacity" => { "tracked_active_paid_resources" => 1 },
      "samples" => { "tracked_paid_resources" => 1 },
      "timing" => {
        "cold_start" => { "status" => "available" },
        "tracked_resource_intervals" => [{
          "provider_resource_id" => "pod-1",
          "worker_identity" => { "worker_id" => "worker-1", "generation_id" => "gen-1" },
          "started_at_utc" => "2026-10-04T10:00:00Z", "ended_at_utc" => "2026-10-04T12:00:00Z",
          "tracked_hourly_rate_usd" => 1.0, "classification" => "prerequisites_passed"
        }]
      },
      "rates" => { "aggregate_current_committed_hourly_usd" => 1.0 },
      "cost" => {
        "accrued_tracked_compute_usd" => 2.0,
        "committed_and_pending_maximum_liability_usd" => 3.0
      },
      "billing_scope" => "tracked RunPod compute only"
    }
  end
end
