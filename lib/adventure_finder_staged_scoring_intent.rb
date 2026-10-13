# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"
require "securerandom"
require "time"
require_relative "adventure_finder_ingest_operation_store"

module AdventureFinderWorkspace
  # AdventureFinder-owned, immutable record of the operator's explicit choice
  # about preparing scoring for one ingest operation. Only an affirmative
  # decision publishes the exact intent document consumed by the pipeline.
  class StagedScoringIntentStore
    DECISION_VERSION = "adventurefinder-staged-scoring-decision/v0.1"
    INTENT_VERSION = "adventurefinder-staged-scoring-intent/v0.1"
    CHOICES = %w[prepare decline].freeze
    INTERACTIONS = %w[ingest_start post_boundary_resume].freeze
    SUPPORTED_POLICY = {
      "schema_version" => "af-staged-scoring-input-policy/v0.1",
      "policy_id" => "approved-new-records",
      "policy_version" => "1",
      "scope" => "operation-approved-new-records",
      "selection" => "afw-qualified-default",
      "permissions" => %w[scoring_input workload_preparation]
    }.freeze

    class Failure < Error
      attr_reader :code

      def initialize(code, message)
        @code = code
        super("#{code}: #{message}")
      end
    end

    class UniquePolicyObject < Hash
      def []=(key, value)
        raise Failure.new("SCORING_POLICY_MISMATCH", "duplicate staged-scoring policy key") if key?(key)

        super
      end
    end

    attr_reader :root, :operation_store, :policy_path

    def self.default_root(front_door_root: ENV["AF_ADVENTURE_FINDER_ROOT"] || File.expand_path("..", __dir__))
      Pathname(front_door_root).expand_path.join("output", "staged-scoring-intents", "v0.1")
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

    def self.file_binding(path)
      {"sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => File.size(path)}
    end

    def initialize(root: self.class.default_root, operation_store:, policy_path:, clock: -> { Time.now.utc })
      @root = Pathname(root).expand_path
      @operation_store = operation_store
      @policy_path = Pathname(policy_path).expand_path
      @clock = clock
    end

    def capture!(operation_id:, choice:, selected_by:, interaction:)
      validate_choice!(choice, selected_by, interaction)
      operation = operation_store.validate!(operation_id)
      candidate = decision_for(operation, choice:, selected_by:, interaction:)

      FileUtils.mkdir_p(root)
      File.open(lock_path(operation_id), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        if decision_path(operation_id).file?
          existing = load_decision!(operation_id, operation:)
          return existing if replay?(existing, candidate)

          fail_with("SCORING_INTENT_CONFLICT", "operation already has a different scoring decision")
        end
        publish!(operation_id, candidate)
        load_decision!(operation_id, operation:)
      end
    rescue IngestOperationStore::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    end

    def decision(operation_id)
      operation = operation_store.validate!(operation_id)
      fail_with("MISSING_SCORING_INTENT", "operation has no explicit scoring decision") unless decision_path(operation_id).file?

      load_decision!(operation_id, operation:)
    rescue IngestOperationStore::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    end

    def intent!(operation_id)
      document = decision(operation_id)
      unless document.fetch("choice") == "prepare" && intent_path(operation_id).file?
        fail_with("SCORING_DECLINED", "operator explicitly declined staged scoring preparation")
      end
      intent = read_json(intent_path(operation_id))
      validate_intent!(intent, operation_store.validate!(operation_id))
      intent
    end

    def intent_path(operation_id)
      operation_dir(operation_id).join("intent.json")
    end

    private

    def decision_for(operation, choice:, selected_by:, interaction:)
      selected_at = timestamp(@clock.call)
      intent = build_intent(operation, selected_by:, selected_at:, interaction:) if choice == "prepare"
      body = {
        "schema_version" => DECISION_VERSION,
        "operation_id" => operation.fetch("operation_id"),
        "choice" => choice,
        "selected_by" => selected_by,
        "selected_at" => selected_at,
        "interaction" => interaction,
        "intent_id" => intent&.fetch("intent_id")
      }
      body["decision_id"] = self.class.digest(body)
      {"decision" => body, "intent" => intent}
    end

    def build_intent(operation, selected_by:, selected_at:, interaction:)
      policy = policy_definition!
      verify_inert_policy!(operation, policy)
      base_path = operation_store.binding_path(operation.fetch("operation_id"), "base_catalog")
      source = IngestOperation::SOURCE_CHOICES.to_h do |key|
        value = operation.dig("source_declaration", key, "value")
        text!(value, "operation source declaration #{key}")
        [key, value]
      end
      intent = {
        "schema_version" => INTENT_VERSION,
        "producer" => "adventure-finder",
        "mode" => "production",
        "operation" => operation.slice("contract_version", "operation_id", "created_at"),
        "base_amc" => {
          "filename" => File.basename(operation.dig("base_catalog", "content", "locator", "path")),
          **self.class.file_binding(base_path)
        },
        "source" => source,
        "policy" => policy.slice("policy_id", "policy_version").merge(self.class.file_binding(policy_path)),
        "selected_by" => selected_by,
        "selected_at" => selected_at,
        "interaction" => interaction,
        "purpose" => "prepare_staged_scoring",
        "scope" => "operation-approved-new-records",
        "workload_id" => "ingest-#{operation.fetch('operation_id')}"
      }
      intent["intent_id"] = self.class.digest(intent)
      validate_intent!(intent, operation)
      intent
    end

    def verify_inert_policy!(operation, policy)
      selected = operation["policy"]
      expected = policy.slice("policy_id", "policy_version").merge(
        "definition_sha256" => Digest::SHA256.file(policy_path).hexdigest,
        "selected_values" => {"selection" => policy.fetch("selection")}
      )
      unless selected.is_a?(Hash) && selected.slice(*expected.keys) == expected
        fail_with(
          "SCORING_POLICY_MISMATCH",
          "operation policy does not bind the selected staged-scoring input policy"
        )
      end
    end

    def policy_definition!
      fail_with("SCORING_POLICY_MISSING", "staged-scoring policy is missing: #{policy_path}") unless policy_path.file?
      value = JSON.parse(File.binread(policy_path), object_class: UniquePolicyObject)
      unless value == SUPPORTED_POLICY
        fail_with("SCORING_POLICY_MISMATCH", "restore the exact supported staged-scoring policy definition")
      end
      value
    rescue JSON::ParserError, SystemCallError
      fail_with("SCORING_POLICY_MISMATCH", "staged-scoring policy authority is unreadable")
    end

    def validate_intent!(intent, operation)
      keys = %w[schema_version producer mode operation base_amc source policy selected_by selected_at
                interaction purpose scope workload_id intent_id]
      exact_keys!(intent, keys, "intent")
      fail_with("CORRUPT_SCORING_INTENT", "unsupported intent schema") unless
        intent["schema_version"] == INTENT_VERSION && intent["producer"] == "adventure-finder" &&
        intent["mode"] == "production"
      fail_with("CORRUPT_SCORING_INTENT", "intent operation changed") unless
        intent.fetch("operation") == operation.slice("contract_version", "operation_id", "created_at")
      fail_with("CORRUPT_SCORING_INTENT", "intent digest mismatch") unless
        intent["intent_id"] == self.class.digest(intent.except("intent_id"))
      fail_with("CORRUPT_SCORING_INTENT", "invalid workload identity") unless
        intent["workload_id"].is_a?(String) && intent["workload_id"].match?(/\A[a-z0-9][a-z0-9_-]{0,63}\z/)
      unless intent["purpose"] == "prepare_staged_scoring" &&
             intent["scope"] == "operation-approved-new-records" &&
             INTERACTIONS.include?(intent["interaction"])
        fail_with("CORRUPT_SCORING_INTENT", "intent purpose, scope or interaction changed")
      end
      expected_policy = policy_definition!.slice("policy_id", "policy_version").merge(self.class.file_binding(policy_path))
      fail_with("SCORING_POLICY_MISMATCH", "intent policy bytes changed") unless intent["policy"] == expected_policy
      verify_inert_policy!(operation, policy_definition!)
      true
    end

    def load_decision!(operation_id, operation:)
      decision = read_json(decision_path(operation_id))
      exact_keys!(decision, %w[schema_version operation_id choice selected_by selected_at interaction intent_id decision_id], "decision")
      unless decision["schema_version"] == DECISION_VERSION && decision["operation_id"] == operation_id &&
             CHOICES.include?(decision["choice"]) && INTERACTIONS.include?(decision["interaction"])
        fail_with("CORRUPT_SCORING_INTENT", "stored scoring decision is incompatible")
      end
      fail_with("CORRUPT_SCORING_INTENT", "stored scoring decision digest mismatch") unless
        decision["decision_id"] == self.class.digest(decision.except("decision_id"))
      if decision["choice"] == "prepare"
        intent = read_json(intent_path(operation_id))
        validate_intent!(intent, operation)
        fail_with("CORRUPT_SCORING_INTENT", "decision and intent identity differ") unless
          decision["intent_id"] == intent["intent_id"]
      elsif !decision["intent_id"].nil? || intent_path(operation_id).exist?
        fail_with("CORRUPT_SCORING_INTENT", "declined decision contains an affirmative intent")
      end
      decision
    rescue Errno::ENOENT, JSON::ParserError, TypeError, KeyError => e
      fail_with("CORRUPT_SCORING_INTENT", e.message)
    end

    def replay?(existing, candidate)
      proposed = candidate.fetch("decision")
      existing.fetch("choice") == proposed.fetch("choice") &&
        existing.fetch("selected_by") == proposed.fetch("selected_by")
    end

    def publish!(operation_id, candidate)
      destination = operation_dir(operation_id)
      fail_with("SCORING_INTENT_CONFLICT", "scoring intent destination already exists") if destination.exist?
      stage = root.join(".#{operation_id}.tmp-#{Process.pid}-#{SecureRandom.hex(6)}")
      begin
        FileUtils.mkdir_p(stage)
        write_atomic(stage.join("decision.json"), candidate.fetch("decision"))
        write_atomic(stage.join("intent.json"), candidate.fetch("intent")) if candidate["intent"]
        File.rename(stage, destination)
      ensure
        FileUtils.remove_entry(stage) if stage.exist?
      end
    rescue SystemCallError => e
      fail_with("SCORING_INTENT_PERSISTENCE_FAILED", e.message)
    end

    def write_atomic(path, document)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.pretty_generate(self.class.canonical(document)) + "\n")
        file.flush
        file.fsync
      end
    end

    def decision_path(operation_id)
      operation_dir(operation_id).join("decision.json")
    end

    def operation_dir(operation_id)
      root.join(operation_id)
    end

    def lock_path(operation_id)
      root.join("#{operation_id}.lock")
    end

    def validate_choice!(choice, selected_by, interaction)
      fail_with("INVALID_SCORING_CHOICE", "choice must be prepare or decline") unless CHOICES.include?(choice)
      text!(selected_by, "selected by")
      fail_with("INVALID_SCORING_CHOICE", "unsupported intent interaction") unless INTERACTIONS.include?(interaction)
    end

    def exact_keys!(value, keys, label)
      fail_with("CORRUPT_SCORING_INTENT", "#{label} has incompatible fields") unless
        value.is_a?(Hash) && value.keys.sort == keys.sort
    end

    def text!(value, label)
      unless value.is_a?(String) && !value.empty? && value == value.strip && !value.match?(/[[:cntrl:]]/)
        fail_with("CORRUPT_SCORING_INTENT", "#{label} must be nonblank trimmed text")
      end
      value
    end

    def timestamp(value)
      time = value.respond_to?(:utc) ? value.utc : Time.iso8601(value.to_s).utc
      time.strftime("%Y-%m-%dT%H:%M:%SZ")
    rescue ArgumentError
      fail_with("INVALID_SCORING_CHOICE", "selection time is invalid")
    end

    def read_json(path)
      JSON.parse(File.binread(path))
    end

    def fail_with(code, message)
      raise Failure.new(code, message)
    end
  end
end
