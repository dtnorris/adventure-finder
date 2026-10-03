# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "securerandom"
require "time"
require "uri"
require_relative "adventure_finder_workspace"

module AdventureFinderWorkspace
  # Provider-neutral composition for dynamic-worker-registry/v0.1 snapshots.
  # Child publishers retain their own identities; this publisher checkpoints
  # those identities and presents one stable, versioned registry to WLO.
  class WorkerRegistryMerger
    VERSION = "dynamic-worker-registry/v0.1"
    ROOT_KEYS = %w[contract_version registry_id revision published_at expires_at workers].freeze
    WORKER_KEYS = %w[worker_id generation_id endpoint state labels capabilities capability_fingerprint].freeze
    CAPABILITY_KEYS = %w[gpu_id ollama].freeze
    OLLAMA_KEYS = %w[models].freeze
    MODEL_KEYS = %w[model digest context_length fully_gpu_resident].freeze
    STATES = %w[READY NOT_READY UNAVAILABLE].freeze
    ID = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/
    SHA256 = /\A[0-9a-f]{64}\z/
    TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/
    STATE_KEYS = %w[schema_version registry_id revision published_at input_sha256 output sources].freeze
    SOURCE_KEYS = %w[registry_id revision published_at sha256].freeze

    Source = Struct.new(:name, :environment, :argv, :chdir, keyword_init: true)
    Result = Struct.new(:stdout, :stderr, :status, keyword_init: true)

    class CommandRunner
      def capture(environment, argv, chdir:)
        stdout, stderr, status = Open3.capture3(environment, *argv, chdir:)
        Result.new(stdout:, stderr:, status:)
      end
    end

    def initialize(state_root:, sources:, runner: CommandRunner.new, clock: nil, id_generator: nil)
      @state_root = File.expand_path(state_root)
      @sources = sources
      names = sources.map { |source| source.name.to_s }
      raise Error, "worker registry merge requires unique named sources" if names.empty? || names.uniq != names
      @runner = runner
      @clock = clock || -> { Time.now.utc }
      @id_generator = id_generator || -> { "af-merged-#{SecureRandom.hex(16)}" }
    end

    def snapshot
      FileUtils.mkdir_p(@state_root, mode: 0o700)
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        now = current_time
        observations = @sources.to_h { |source| [source.name, read_source!(source, now:)] }
        previous = load_state(now:)
        validate_source_progress!(observations, previous)
        input_sha = input_fingerprint(observations)
        return previous.fetch("output") if previous && previous.fetch("input_sha256") == input_sha

        if previous && Time.iso8601(previous.fetch("published_at")) >= now
          raise Error, "merged registry publication time has not advanced; retry after the next UTC second"
        end

        workers = merge_workers!(observations)
        document = {
          "contract_version" => VERSION,
          "registry_id" => previous ? previous.fetch("registry_id") : generated_registry_id,
          "revision" => previous ? previous.fetch("revision") + 1 : 1,
          "published_at" => now.iso8601(0),
          "expires_at" => observations.values.map { |item| item.fetch("document").fetch("expires_at") }.min,
          "workers" => workers
        }
        validate_snapshot!(document, now:)
        state = {
          "schema_version" => 1,
          "registry_id" => document.fetch("registry_id"),
          "revision" => document.fetch("revision"),
          "published_at" => document.fetch("published_at"),
          "input_sha256" => input_sha,
          "output" => document,
          "sources" => observations.transform_values { |item| source_checkpoint(item) }
        }
        write_state(state)
        document
      end
    rescue JSON::ParserError, SystemCallError, KeyError, TypeError, ArgumentError => e
      raise Error, "could not publish merged worker registry: #{e.message}"
    end

    private

    def read_source!(source, now:)
      result = @runner.capture(source.environment, source.argv, chdir: source.chdir)
      unless result.status.success?
        detail = result.stderr.to_s.strip
        detail = result.stdout.to_s.strip if detail.empty?
        raise Error, "worker source #{source.name} failed#{detail.empty? ? '' : ": #{detail}"}"
      end
      document = JSON.parse(result.stdout)
      validate_snapshot!(document, now:)
      { "document" => document, "sha256" => Digest::SHA256.hexdigest(result.stdout) }
    rescue JSON::ParserError => e
      raise Error, "worker source #{source.name} returned invalid JSON: #{e.message}"
    end

    def validate_source_progress!(observations, previous)
      return unless previous

      observations.each do |name, item|
        before = previous.fetch("sources").fetch(name.to_s) do
          raise Error, "merged registry state has no checkpoint for source #{name}"
        end
        current = source_checkpoint(item)
        unless current.fetch("registry_id") == before.fetch("registry_id")
          raise Error, "worker source #{name} changed registry identity"
        end
        if current.fetch("revision") < before.fetch("revision")
          raise Error, "worker source #{name} revision moved backwards"
        elsif current.fetch("revision") == before.fetch("revision")
          unless current.fetch("sha256") == before.fetch("sha256")
            raise Error, "worker source #{name} changed bytes at the same revision"
          end
        elsif Time.iso8601(current.fetch("published_at")) <= Time.iso8601(before.fetch("published_at"))
          raise Error, "worker source #{name} advanced revision without advancing published_at"
        end
      end
    end

    def merge_workers!(observations)
      by_identity = {}
      observations.each_value do |item|
        item.fetch("document").fetch("workers").each do |worker|
          key = [worker.fetch("worker_id"), worker.fetch("generation_id")]
          existing = by_identity[key]
          if existing && existing != worker
            raise Error, "conflicting duplicate worker identity #{key.join('/')}"
          end
          by_identity[key] ||= worker
        end
      end
      workers = by_identity.values.sort_by { |worker| [worker.fetch("worker_id"), worker.fetch("generation_id")] }
      validate_worker_uniqueness!(workers)
      workers
    end

    def validate_snapshot!(document, now:)
      exact_keys!(document, ROOT_KEYS, "worker registry")
      raise Error, "worker registry contract must be #{VERSION}" unless document.fetch("contract_version") == VERSION
      id!(document.fetch("registry_id"), "registry_id")
      revision!(document.fetch("revision"))
      published = timestamp!(document.fetch("published_at"), "published_at")
      expires = timestamp!(document.fetch("expires_at"), "expires_at")
      raise Error, "worker registry published_at is future-dated" if published > now
      raise Error, "worker registry expires_at must follow published_at" unless expires > published
      raise Error, "worker registry snapshot is expired" unless expires > now
      workers = document.fetch("workers")
      raise Error, "worker registry workers must be an array" unless workers.is_a?(Array)
      workers.each_with_index { |worker, index| validate_worker!(worker, "worker[#{index}]") }
      validate_worker_uniqueness!(workers)
      document
    end

    def validate_worker!(worker, label)
      exact_keys!(worker, WORKER_KEYS, label)
      id!(worker.fetch("worker_id"), "#{label}.worker_id")
      nonempty!(worker.fetch("generation_id"), "#{label}.generation_id", max: 256)
      normalized_endpoint(worker.fetch("endpoint"), "#{label}.endpoint")
      raise Error, "#{label}.state is invalid" unless STATES.include?(worker.fetch("state"))
      labels = worker.fetch("labels")
      strings!(labels, "#{label}.labels")
      raise Error, "#{label}.labels must be unique and sorted" unless labels.uniq == labels && labels.sort == labels
      capabilities = worker.fetch("capabilities")
      exact_keys!(capabilities, CAPABILITY_KEYS, "#{label}.capabilities")
      nonempty!(capabilities.fetch("gpu_id"), "#{label}.capabilities.gpu_id", max: 256)
      exact_keys!(capabilities.fetch("ollama"), OLLAMA_KEYS, "#{label}.capabilities.ollama")
      models = capabilities.dig("ollama", "models")
      raise Error, "#{label}.capabilities.ollama.models must be nonempty" unless models.is_a?(Array) && !models.empty?
      models.each_with_index { |model, index| validate_model!(model, "#{label}.model[#{index}]") }
      names = models.map { |model| model.fetch("model") }
      raise Error, "#{label} model identifiers must be unique" unless names.uniq == names
      sorted = models.sort_by { |model| [model.fetch("model"), model.fetch("digest"), model.fetch("context_length"), model.fetch("fully_gpu_resident") ? 1 : 0] }
      raise Error, "#{label} models must be sorted" unless models == sorted
      fingerprint = worker.fetch("capability_fingerprint")
      unless fingerprint.is_a?(String) && SHA256.match?(fingerprint) && fingerprint == capability_fingerprint(worker)
        raise Error, "#{label}.capability_fingerprint is invalid"
      end
    end

    def validate_model!(model, label)
      exact_keys!(model, MODEL_KEYS, label)
      nonempty!(model.fetch("model"), "#{label}.model", max: 256)
      digest = model.fetch("digest")
      raise Error, "#{label}.digest is invalid" unless digest.is_a?(String) && SHA256.match?(digest)
      context = model.fetch("context_length")
      raise Error, "#{label}.context_length is invalid" unless context.is_a?(Integer) && context.positive?
      unless [true, false].include?(model.fetch("fully_gpu_resident"))
        raise Error, "#{label}.fully_gpu_resident must be boolean"
      end
    end

    def capability_fingerprint(worker)
      models = worker.dig("capabilities", "ollama", "models").map do |model|
        { "context_length" => model.fetch("context_length"), "digest" => model.fetch("digest"),
          "fully_gpu_resident" => model.fetch("fully_gpu_resident"), "model" => model.fetch("model") }
      end
      Digest::SHA256.hexdigest(JSON.generate(
        "gpu_id" => worker.dig("capabilities", "gpu_id"), "labels" => worker.fetch("labels"),
        "ollama_models" => models
      ))
    end

    def validate_worker_uniqueness!(workers)
      ids = {}
      endpoints = {}
      workers.each do |worker|
        id = worker.fetch("worker_id")
        endpoint = normalized_endpoint(worker.fetch("endpoint"), "worker endpoint")
        raise Error, "duplicate worker_id #{id.inspect}" if ids.key?(id)
        raise Error, "duplicate worker endpoint #{worker.fetch('endpoint').inspect}" if endpoints.key?(endpoint)
        ids[id] = endpoints[endpoint] = true
      end
    end

    def load_state(now:)
      return nil unless File.file?(state_path)
      value = JSON.parse(File.binread(state_path))
      exact_keys!(value, STATE_KEYS, "merged registry state")
      raise Error, "merged registry state schema is invalid" unless value.fetch("schema_version") == 1
      id!(value.fetch("registry_id"), "merged registry_id")
      revision!(value.fetch("revision"))
      timestamp!(value.fetch("published_at"), "merged published_at")
      raise Error, "merged input fingerprint is invalid" unless SHA256.match?(value.fetch("input_sha256"))
      validate_stored_sources!(value.fetch("sources"))
      output = value.fetch("output")
      validate_snapshot!(output, now:)
      unless output.fetch("registry_id") == value.fetch("registry_id") &&
             output.fetch("revision") == value.fetch("revision") &&
             output.fetch("published_at") == value.fetch("published_at")
        raise Error, "merged registry state and output identity differ"
      end
      value
    end

    def validate_stored_sources!(sources)
      raise Error, "merged registry sources must be an object" unless sources.is_a?(Hash)
      expected = @sources.map { |source| source.name.to_s }.sort
      raise Error, "merged registry source set changed" unless sources.keys.sort == expected
      sources.each do |name, source|
        exact_keys!(source, SOURCE_KEYS, "source checkpoint #{name}")
        id!(source.fetch("registry_id"), "source registry_id")
        revision!(source.fetch("revision"))
        timestamp!(source.fetch("published_at"), "source published_at")
        raise Error, "source checkpoint SHA-256 is invalid" unless SHA256.match?(source.fetch("sha256"))
      end
    end

    def source_checkpoint(item)
      document = item.fetch("document")
      { "registry_id" => document.fetch("registry_id"), "revision" => document.fetch("revision"),
        "published_at" => document.fetch("published_at"), "sha256" => item.fetch("sha256") }
    end

    def input_fingerprint(observations)
      Digest::SHA256.hexdigest(JSON.generate(observations.sort.map { |name, item| [name.to_s, item.fetch("sha256")] }))
    end

    def write_state(document)
      temporary = "#{state_path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write("#{JSON.generate(document)}\n")
        file.flush
        file.fsync
      end
      File.rename(temporary, state_path)
      File.open(@state_root, File::RDONLY, &:fsync)
    ensure
      File.delete(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
    end

    def generated_registry_id
      value = @id_generator.call
      id!(value, "generated registry_id")
    end

    def current_time
      value = @clock.call
      raise Error, "merged registry clock must return a Time" unless value.is_a?(Time)
      Time.at(value.to_i).utc
    end

    def exact_keys!(value, expected, label)
      raise Error, "#{label} must be an object" unless value.is_a?(Hash)
      missing = expected - value.keys
      unknown = value.keys - expected
      raise Error, "#{label} missing fields: #{missing.join(', ')}" unless missing.empty?
      raise Error, "#{label} unknown fields: #{unknown.join(', ')}" unless unknown.empty?
    end

    def id!(value, label)
      raise Error, "#{label} is invalid" unless value.is_a?(String) && ID.match?(value)
      value
    end

    def revision!(value)
      raise Error, "registry revision must be a nonnegative integer" unless value.is_a?(Integer) && !value.negative?
    end

    def timestamp!(value, label)
      raise Error, "#{label} must be whole-second UTC" unless value.is_a?(String) && TIMESTAMP.match?(value)
      Time.iso8601(value).utc
    rescue ArgumentError
      raise Error, "#{label} is invalid"
    end

    def nonempty!(value, label, max: nil)
      valid = value.is_a?(String) && !value.empty? && value == value.strip && !value.match?(/[[:cntrl:]]/)
      valid &&= value.length <= max if max
      raise Error, "#{label} must be a non-empty trimmed string" unless valid
      value
    end

    def strings!(value, label)
      unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) && !item.empty? && item == item.strip }
        raise Error, "#{label} must be an array of non-empty trimmed strings"
      end
    end

    def normalized_endpoint(value, label)
      nonempty!(value, label)
      uri = URI.parse(value)
      valid_path = uri.path.nil? || uri.path.empty? || uri.path == "/"
      unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty? && uri.userinfo.nil? &&
             uri.query.nil? && uri.fragment.nil? && valid_path
        raise Error, "#{label} must be an HTTP(S) origin"
      end
      "#{uri.scheme.downcase}://#{uri.host.downcase}:#{uri.port}"
    rescue URI::InvalidURIError
      raise Error, "#{label} must be an HTTP(S) origin"
    end

    def lock_path = File.join(@state_root, ".merged-worker-registry.lock")
    def state_path = File.join(@state_root, "merged-worker-registry.json")
  end
end
