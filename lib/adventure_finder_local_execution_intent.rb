# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"
require "securerandom"
require "time"
require_relative "adventure_finder_workspace"

module AdventureFinderWorkspace
  # Immutable, operation-bound authority for the local-only execution driver.
  # It grants neither retry/recovery authority nor remote/provider authority.
  class LocalExecutionIntentStore
    CONTRACT_VERSION = "adventurefinder-local-execution-intent/v0.1"
    UUID_V4 = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

    class Failure < Error
      attr_reader :code

      def initialize(code, message)
        @code = code
        super("#{code}: #{message}")
      end
    end

    attr_reader :root

    def self.default_root(front_door_root: ENV["AF_ADVENTURE_FINDER_ROOT"] || File.expand_path("..", __dir__))
      Pathname(front_door_root).expand_path.join("output", "local-ingest-executions", "v0.1")
    end

    def self.canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
      when Array then value.map { |entry| canonical(entry) }
      else value
      end
    end

    def self.digest(value)
      Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
    end

    def initialize(root: self.class.default_root, clock: -> { Time.now.utc })
      @root = Pathname(root).expand_path
      @clock = clock
    end

    def capture!(operation_id:, selected_by:, capability_plan:, components:, workdir:, output:)
      validate_handle!(operation_id)
      text!(selected_by, "selected_by")
      candidate = build_intent(
        operation_id:, selected_by:, capability_plan:, components:, workdir:, output:
      )
      FileUtils.mkdir_p(root)
      File.open(lock_path(operation_id), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        if intent_path(operation_id).file?
          existing = load!(operation_id)
          return existing if replay?(existing, candidate)

          fail_with("LOCAL_EXECUTION_INTENT_CONFLICT", "local execution intent is already bound differently")
        end
        write_atomic(intent_path(operation_id), candidate)
      end
      candidate
    rescue SystemCallError => e
      fail_with("LOCAL_EXECUTION_INTENT_PERSISTENCE_FAILED", e.message)
    end

    def load!(operation_id)
      validate_handle!(operation_id)
      document = JSON.parse(File.binread(intent_path(operation_id)))
      validate!(document, operation_id)
      document
    rescue Errno::ENOENT
      fail_with("MISSING_LOCAL_EXECUTION_INTENT", "start local execution with explicit operator authority first")
    rescue JSON::ParserError, KeyError, TypeError => e
      fail_with("CORRUPT_LOCAL_EXECUTION_INTENT", e.message)
    end

    def intent_path(operation_id)
      operation_dir(operation_id).join("intent.json")
    end

    def operation_dir(operation_id)
      root.join(operation_id)
    end

    private

    def build_intent(operation_id:, selected_by:, capability_plan:, components:, workdir:, output:)
      workload = capability_plan.fetch("workload")
      sequence_binding = self.class.digest(
        "capabilities" => capability_plan.fetch("capabilities"),
        "sequence" => capability_plan.fetch("sequence")
      )
      body = {
        "contract_version" => CONTRACT_VERSION,
        "operation_id" => operation_id,
        "selected_by" => selected_by,
        "selected_at" => timestamp,
        "authority" => {
          "mode" => "local_only",
          "ordinary_execution" => true,
          "retry" => false,
          "recovery" => false,
          "breaker_acknowledgement" => false,
          "remote_capacity" => false,
          "paid_resources" => false,
          "catalog_adoption" => false
        },
        "workload" => {
          "workload_id" => workload.fetch("workload_id"),
          "plan_id" => workload.fetch("plan_id"),
          "plan_sha256" => workload.fetch("plan_sha256"),
          "capability_sequence_sha256" => sequence_binding
        },
        "execution" => {
          "workdir" => File.expand_path(workdir),
          "output" => File.expand_path(output),
          "consumer_id" => Digest::SHA256.hexdigest(JSON.generate(
            [workload.fetch("plan_sha256"), File.expand_path(workdir), File.expand_path(output)]
          ))
        },
        "components" => components.transform_values { |path| File.expand_path(path) }
      }
      body.merge("intent_id" => self.class.digest(body))
    end

    def validate!(document, operation_id)
      keys = %w[contract_version operation_id selected_by selected_at authority workload execution components intent_id]
      exact_keys!(document, keys, "intent")
      fail_with("CORRUPT_LOCAL_EXECUTION_INTENT", "unsupported intent contract") unless
        document["contract_version"] == CONTRACT_VERSION && document["operation_id"] == operation_id
      fail_with("CORRUPT_LOCAL_EXECUTION_INTENT", "intent digest mismatch") unless
        document["intent_id"] == self.class.digest(document.except("intent_id"))
      expected_authority = {
        "mode" => "local_only", "ordinary_execution" => true, "retry" => false,
        "recovery" => false, "breaker_acknowledgement" => false,
        "remote_capacity" => false, "paid_resources" => false,
        "catalog_adoption" => false
      }
      fail_with("CORRUPT_LOCAL_EXECUTION_INTENT", "authority widened or changed") unless
        document["authority"] == expected_authority
      %w[selected_by selected_at intent_id].each { |key| text!(document.fetch(key), key) }
      exact_keys!(document.fetch("workload"),
                  %w[workload_id plan_id plan_sha256 capability_sequence_sha256], "workload")
      exact_keys!(document.fetch("execution"), %w[workdir output consumer_id], "execution")
      exact_keys!(document.fetch("components"), %w[afw low wlo], "components")
      %w[plan_sha256 capability_sequence_sha256].each do |key|
        digest!(document.dig("workload", key), key)
      end
      %w[workload_id plan_id].each { |key| text!(document.dig("workload", key), key) }
      digest!(document.dig("execution", "consumer_id"), "consumer_id")
      %w[workdir output].each { |key| absolute_path!(document.dig("execution", key), key) }
      document.fetch("components").each { |key, value| absolute_path!(value, "components.#{key}") }
      Time.iso8601(document.fetch("selected_at"))
      true
    rescue ArgumentError
      fail_with("CORRUPT_LOCAL_EXECUTION_INTENT", "selected_at must be an ISO-8601 timestamp")
    end

    def replay?(existing, candidate)
      existing["selected_by"] == candidate["selected_by"] &&
        existing.except("selected_at", "intent_id") == candidate.except("selected_at", "intent_id")
    end

    def write_atomic(path, document)
      FileUtils.mkdir_p(path.dirname)
      temporary = path.dirname.join(".#{path.basename}.tmp-#{Process.pid}-#{SecureRandom.hex(6)}")
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.pretty_generate(self.class.canonical(document)) + "\n")
        file.flush
        file.fsync
      end
      File.rename(temporary, path)
    ensure
      File.delete(temporary) if temporary&.file?
    end

    def exact_keys!(value, expected, label)
      fail_with("CORRUPT_LOCAL_EXECUTION_INTENT", "#{label} has incompatible fields") unless
        value.is_a?(Hash) && value.keys.sort == expected.sort
    end

    def validate_handle!(value)
      fail_with("INVALID_OPERATION_HANDLE", "operation handle must be a lowercase UUIDv4") unless
        value.is_a?(String) && UUID_V4.match?(value)
    end

    def text!(value, label)
      valid = value.is_a?(String) && !value.empty? && value == value.strip && !value.match?(/[[:cntrl:]]/)
      fail_with("CORRUPT_LOCAL_EXECUTION_INTENT", "#{label} must be nonblank trimmed text") unless valid
      value
    end

    def digest!(value, label)
      fail_with("CORRUPT_LOCAL_EXECUTION_INTENT", "#{label} must be a lowercase SHA-256") unless
        value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
    end

    def absolute_path!(value, label)
      text!(value, label)
      fail_with("CORRUPT_LOCAL_EXECUTION_INTENT", "#{label} must be absolute") unless Pathname(value).absolute?
    end

    def timestamp
      value = @clock.call
      fail_with("LOCAL_EXECUTION_INTENT_PERSISTENCE_FAILED", "intent clock must return a Time") unless value.is_a?(Time)
      value.utc.iso8601(0)
    end

    def lock_path(operation_id)
      root.join("#{operation_id}.lock")
    end

    def fail_with(code, message)
      raise Failure.new(code, message)
    end
  end
end
