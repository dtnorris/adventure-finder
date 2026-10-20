# frozen_string_literal: true

require "json"
require "securerandom"
require "tmpdir"

# Independently validates the public AFDP result, without loading component code.
# Counts preserve the public command's observed execution populations.
module AdventureFinderTestResult
  SCHEMA = "afdp-suite-result/v1"
  PATH_KEY = "AFDP_TEST_RESULT_PATH"
  ID_KEY = "AFDP_TEST_RESULT_RUN_ID"
  COUNTERS = %w[tests assertions failures errors skips].freeze
  KEYS = (COUNTERS + %w[schema run_id suite status]).sort.freeze

  # Raised for absent, stale, ambiguous or malformed public accounting.
  class InvalidResult < StandardError; end

  # Yields fresh environment bindings and a reader for one child invocation.
  # Removes the channel afterward; I/O and child exceptions propagate unchanged.
  def self.channel(suite)
    Dir.mktmpdir("afdp-result-") do |directory|
      environment = {PATH_KEY => File.join(directory, "result.json"), ID_KEY => SecureRandom.hex(16)}
      yield environment, -> { read!(environment, suite: suite) }
    end
  end

  # Reads exactly one closed-schema result bound to the caller's fresh request.
  # Returns the document or raises InvalidResult; process success is separate.
  def self.read!(environment, suite:)
    record = JSON.parse(File.binread(environment.fetch(PATH_KEY)), allow_duplicate_key: false)
    unless record.is_a?(Hash) && record.keys.sort == KEYS && record["schema"] == SCHEMA &&
        record["run_id"] == environment.fetch(ID_KEY) && record["run_id"].is_a?(String) &&
        record["run_id"].match?(/\A[0-9a-f]{32}\z/) && record["suite"] == suite &&
        %w[fast integration all].include?(suite) && %w[passed failed].include?(record["status"]) &&
        COUNTERS.all? { |key| record[key].is_a?(Integer) && record[key] >= 0 } &&
        record.values_at("failures", "errors", "skips").sum <= record["tests"] &&
        (record["status"] != "passed" || record.values_at("failures", "errors").all?(&:zero?))
      raise InvalidResult, "suite result is malformed, stale, mismatched or incomplete"
    end
    record
  rescue SystemCallError, JSON::ParserError => error
    raise InvalidResult, "suite result is missing or corrupt: #{error.message}"
  end
end
