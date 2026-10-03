# frozen_string_literal: true

require "json"
require_relative "adventure_finder_workspace"

module AdventureFinderWorkspace
  # Resolves AdventureFinder operator vocabulary against one frozen AFW plan.
  # WLO receives only the resulting canonical job ID.
  class JobHandleResolver
    def self.load(path)
      new(JSON.parse(File.binread(path)))
    rescue Errno::ENOENT, JSON::ParserError => e
      raise Error, "invalid frozen AFW plan #{path}: #{e.message}"
    end

    def initialize(plan)
      @jobs = plan.fetch("jobs")
      unless @jobs.is_a?(Array) && @jobs.all? { |job| job.is_a?(Hash) && job["job_id"].is_a?(String) }
        raise Error, "frozen AFW plan jobs are invalid"
      end
    rescue KeyError => e
      raise Error, "frozen AFW plan jobs are invalid: #{e.message}"
    end

    def resolve(handle)
      supplied = handle.to_s
      exact = @jobs.find { |job| job.fetch("job_id") == supplied }
      return exact.fetch("job_id") if exact

      matches = @jobs.select { |job| aliases(job).include?(supplied.downcase) }
      raise Error, "unknown AdventureFinder job handle #{handle.inspect}" if matches.empty?
      if matches.length > 1
        ids = matches.map { |job| job.fetch("job_id") }.sort
        raise Error, "ambiguous AdventureFinder job handle #{handle.inspect}: #{ids.join(', ')}"
      end

      matches.first.fetch("job_id")
    end

    private

    def aliases(job)
      job_id = job.fetch("job_id")
      values = []
      if (match = job_id.match(/(?:\A|-)adv(\d+)-(.+)\z/i))
        number = match[1]
        dimension = match[2]
        compact = dimension.split("-").last
        values.concat(["#{number}-#{compact}", "#{number}-#{dimension}",
                       "adv-#{number}-#{compact}", "adv-#{number}-#{dimension}"])
      end
      group_id = job["group_id"].to_s
      values << group_id.downcase unless group_id.empty?
      values.uniq
    end
  end
end
