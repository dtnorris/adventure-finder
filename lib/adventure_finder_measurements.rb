# frozen_string_literal: true

require "json"
require "time"

module AdventureFinderMeasurements
  CONTRACT_VERSION = "adventurefinder-operator-measurements/v0.1"
  WLO_VERSION = "wlo-execution-measurements/v0.1"
  RPOF_VERSION = "rpof-provider-cost-measurements/v0.1"

  class Error < StandardError; end

  class Composition
    def initialize(wlo:, rpof: nil)
      @wlo = deep_copy(wlo)
      @rpof = rpof && deep_copy(rpof)
    end

    def document
      validate_contract!(@wlo, WLO_VERSION, "WLO")
      validate_contract!(@rpof, RPOF_VERSION, "RPOF") if @rpof
      {
        "contract_version" => CONTRACT_VERSION,
        "read_only" => true,
        "association" => @rpof ? "explicit_wlo_execution_and_rpof_context" : "wlo_execution_only",
        "work" => @wlo.fetch("work"),
        "samples" => component_samples,
        "throughput" => @wlo.fetch("throughput"),
        "eta" => @wlo.fetch("eta"),
        "scoring_inference_time" => @wlo.fetch("command_execution"),
        "queue_wait" => @wlo.fetch("queue_wait"),
        "execution_utilization" => @wlo.fetch("utilization"),
        "provider" => @rpof && provider_summary,
        "useful_cost" => useful_cost
      }
    rescue KeyError, ArgumentError, TypeError => e
      raise Error, "cannot compose measurements: #{e.message}"
    end

    def render
      value = document
      work = value.fetch("work")
      lines = [
        "AdventureFinder measurements",
        "Jobs: #{work.fetch('completed')}/#{work.fetch('total_jobs')} complete; " \
          "running=#{work.fetch('running')} pending=#{work.fetch('pending')} " \
          "failed=#{work.fetch('failed')} interrupted=#{work.fetch('interrupted')}",
        measurement_line("Throughput", value.fetch("throughput"), "jobs_per_hour", suffix: " jobs/hour"),
        eta_line(value.fetch("eta")),
        measurement_line("Scoring/inference active wall fraction", value.fetch("execution_utilization"),
                         "busy_wall_fraction")
      ]
      if value["provider"]
        provider = value.fetch("provider")
        lines << "Tracked compute: $#{format('%.6f', provider.fetch('accrued_tracked_compute_usd'))}; " \
                 "current committed rate=$#{format('%.6f', provider.fetch('current_committed_hourly_usd'))}/hour"
      else
        lines << "Paid provider cost: not attached"
      end
      useful = value.fetch("useful_cost")
      lines << if useful.fetch("status") == "estimated"
                 "Estimated useful scoring/inference compute: $#{format('%.6f', useful.fetch('command_active_compute_usd'))} " \
                   "(#{useful.fetch('matched_attempt_interval_count')} matched attempt intervals)"
               else
                 "Estimated useful scoring/inference compute: unavailable (#{useful.fetch('reason')})"
               end
      lines.join("\n") + "\n"
    end

    private

    def component_samples
      result = { "wlo" => @wlo.fetch("samples") }
      result["rpof"] = @rpof.fetch("samples") if @rpof
      result
    end

    def provider_summary
      {
        "capacity" => @rpof.fetch("capacity"),
        "timing" => @rpof.fetch("timing").except("tracked_resource_intervals"),
        "current_committed_hourly_usd" => @rpof.dig("rates", "aggregate_current_committed_hourly_usd"),
        "accrued_tracked_compute_usd" => @rpof.dig("cost", "accrued_tracked_compute_usd"),
        "committed_and_pending_maximum_liability_usd" =>
          @rpof.dig("cost", "committed_and_pending_maximum_liability_usd"),
        "billing_scope" => @rpof.fetch("billing_scope")
      }
    end

    def useful_cost
      return unavailable("no associated paid RPOF measurement was attached") unless @rpof

      attempts = Array(@wlo.dig("command_execution", "active_intervals"))
      resources = Array(@rpof.dig("timing", "tracked_resource_intervals"))
      matchable = attempts.select { |row| complete_identity?(row["worker_identity"]) }
      resource_rows = resources.select { |row| complete_identity?(row["worker_identity"]) }
      return unavailable("no WLO attempt interval has a generic worker-generation identity") if matchable.empty?
      return unavailable("no RPOF tracked resource interval has a matching generic worker-generation identity") if resource_rows.empty?

      total_cost = 0.0
      successful_cost = 0.0
      failed_cost = 0.0
      matched = {}
      resource_rows.each do |resource|
        candidates = matchable.select { |attempt| same_identity?(attempt, resource) }
        next if candidates.empty?

        rate = Float(resource.fetch("tracked_hourly_rate_usd"))
        resource_interval = interval(resource)
        all = intersections(candidates, resource_interval)
        successful = intersections(candidates.select { |row| row["status"] == "complete" }, resource_interval)
        failed = intersections(candidates.select { |row| %w[failed interrupted].include?(row["status"]) }, resource_interval)
        total_cost += union_seconds(all) * rate / 3600.0
        successful_cost += union_seconds(successful) * rate / 3600.0
        failed_cost += union_seconds(failed) * rate / 3600.0
        candidates.each { |row| matched[[row["job_id"], row["attempt"], row["started_at_utc"]]] = true }
      end
      return unavailable("worker generations did not match between the explicitly associated measurements") if matched.empty?

      {
        "status" => "estimated",
        "definition" => "tracked RPOF compute rate during time-aligned WLO command intervals on the same generic worker generation",
        "assumptions" => [
          "the supplied WLO execution and RPOF context were explicitly associated by the operator",
          "tracked hourly rates are uniform within each reported resource interval",
          "this is tracked compute, not the total provider bill"
        ],
        "command_active_compute_usd" => total_cost.round(6),
        "successful_command_compute_usd" => successful_cost.round(6),
        "failed_or_interrupted_command_compute_usd" => failed_cost.round(6),
        "matched_attempt_interval_count" => matched.length,
        "total_attempt_interval_count" => attempts.length,
        "unmatched_attempt_interval_count" => attempts.length - matched.length,
        "resource_interval_count" => resources.length
      }
    rescue ArgumentError
      unavailable("component interval or rate evidence is invalid")
    end

    def intersections(rows, outer)
      rows.filter_map do |row|
        left, right = interval(row)
        start_at = [left, outer.first].max
        end_at = [right, outer.last].min
        [start_at, end_at] if end_at > start_at
      end
    end

    def interval(row)
      [Time.iso8601(row.fetch("started_at_utc")).utc, Time.iso8601(row.fetch("ended_at_utc")).utc]
    end

    def union_seconds(intervals)
      intervals.sort_by(&:first).reduce([]) do |merged, row|
        if merged.empty? || row.first > merged.last.last
          merged << row.dup
        else
          merged.last[1] = [merged.last.last, row.last].max
        end
        merged
      end.sum { |left, right| right - left }
    end

    def same_identity?(attempt, resource)
      attempt.fetch("worker_identity") == resource.fetch("worker_identity")
    end

    def complete_identity?(identity)
      identity.is_a?(Hash) && %w[worker_id generation_id].all? { |key| !identity[key].to_s.empty? }
    end

    def validate_contract!(document, expected, label)
      unless document.is_a?(Hash) && document["contract_version"] == expected
        raise Error, "#{label} measurement contract must be #{expected.inspect}"
      end
    end

    def measurement_line(label, measurement, field, suffix: "")
      return "#{label}: unavailable" unless measurement["status"] == "available"

      "#{label}: #{measurement.fetch(field)}#{suffix} (samples=#{measurement.fetch('sample_count', 0)})"
    end

    def eta_line(eta)
      return "ETA: unavailable (samples=#{eta.fetch('sample_count', 0)})" unless eta["status"] == "available"

      "ETA: #{eta.fetch('estimated_remaining_seconds')} seconds; completion #{eta.fetch('estimated_completion_at_utc')} " \
        "(samples=#{eta.fetch('sample_count', 0)})"
    end

    def unavailable(reason)
      { "status" => "unavailable", "reason" => reason }
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end
  end
end
