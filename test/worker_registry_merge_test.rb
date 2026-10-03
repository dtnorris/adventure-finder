# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"

require "adventure_finder_worker_registry"
require "adventure_finder_worker_registry_front_door"

class WorkerRegistryMergeTest < Minitest::Test
  Status = Struct.new(:successful) { def success? = successful }

  class Runner
    attr_reader :calls

    def initialize(results)
      @results = results
      @calls = []
    end

    def capture(environment, argv, chdir:)
      @calls << { environment:, argv:, chdir: }
      value = @results.shift || raise("unexpected worker source call")
      AdventureFinderWorkspace::WorkerRegistryMerger::Result.new(
        stdout: value.fetch(:stdout), stderr: value.fetch(:stderr, ""),
        status: Status.new(value.fetch(:success, true))
      )
    end
  end

  class Registry
    def initialize(batch, fleet)
      @batch = batch
      @fleet = fleet
    end

    def resolve(type, _handle) = type == "batch" ? @batch : @fleet
  end

  def setup
    @root = Dir.mktmpdir("af-worker-merge-")
    @now = Time.utc(2030, 1, 1, 0, 0, 10)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_lc01_lc02_rpof_and_low_workers_share_one_contract_and_local_only_is_valid
    remote = worker("remote-1", "https://remote.example:11434", "gpu-remote", [model("qwen")])
    local = worker("local-1", "http://127.0.0.1:11434", "apple-m4", [model("qwen")])
    merged = merge(snapshot("rpof-a", 4, [remote]), snapshot("low-a", 8, [local]))

    assert_equal "dynamic-worker-registry/v0.1", merged.fetch("contract_version")
    assert_equal %w[local-1 remote-1], merged.fetch("workers").map { |row| row.fetch("worker_id") }

    local_only = merge(snapshot("rpof-a", 4, []), snapshot("low-a", 8, [local]), root: "local-only")
    assert_equal ["local-1"], local_only.fetch("workers").map { |row| row.fetch("worker_id") }
  end

  def test_front_door_polls_rpof_and_low_with_argv_safe_observational_commands
    rpof = source_repository("rpof", "rpof")
    low = source_repository("low", "low")
    bundle = File.join(@root, "bundle")
    File.write(bundle, "#!/bin/sh\n")
    FileUtils.chmod(0o755, bundle)
    runner = Runner.new([result(snapshot("rpof-a", 1, [])), result(snapshot("low-a", 1, []))])
    registry = Registry.new(
      { "associated_fleets" => ["A"], "local_workers" => { "repository_root" => low },
        "wlo" => { "output_root" => File.join(@root, "output") } },
      { "rpof" => { "repository_root" => rpof, "state_root" => File.join(@root, "rpof-state") } }
    )

    document = AdventureFinderWorkspace::WorkerRegistryFrontDoor.new(
      registry:, bundle_executable: bundle, runner:, clock: -> { @now },
      id_generator: -> { "af-merged-test" }
    ).snapshot("39")

    assert_empty document.fetch("workers")
    assert_equal [File.join(rpof, "bin", "rpof"), File.join(low, "bin", "low")],
                 runner.calls.map { |call| call.fetch(:argv).fetch(2) }
    assert runner.calls.all? { |call| call.fetch(:argv).last(2) == %w[workers --json] }
    refute runner.calls.any? { |call| call.fetch(:argv).include?("bootstrap") }
  end

  def test_lc03_one_multi_capability_local_worker_is_published_once_not_four_times
    models = %w[gemma gptoss qwen qwen27].map { |name| model(name) }
    local = worker("local-1", "http://127.0.0.1:11434", "apple-m4", models)
    merged = merge(snapshot("rpof-a", 1, []), snapshot("low-a", 1, [local]))

    assert_equal 1, merged.fetch("workers").length
    assert_equal %w[gemma gptoss qwen qwen27],
                 merged.dig("workers", 0, "capabilities", "ollama", "models").map { |row| row.fetch("model") }
  end

  def test_lc04_identical_duplicate_identity_collapses_but_conflict_fails_closed
    shared = worker("shared", "http://127.0.0.1:11434", "apple-m4", [model("qwen")])
    merged = merge(snapshot("rpof-a", 1, [shared]), snapshot("low-a", 1, [shared]))
    assert_equal 1, merged.fetch("workers").length

    changed = JSON.parse(JSON.generate(shared))
    changed["state"] = "NOT_READY"
    error = assert_raises(AdventureFinderWorkspace::Error) do
      merge(snapshot("rpof-a", 1, [shared]), snapshot("low-a", 1, [changed]), root: "conflict")
    end
    assert_includes error.message, "conflicting duplicate worker identity"
  end

  def test_lc05_duplicate_physical_endpoint_with_different_identity_fails_closed
    one = worker("one", "http://127.0.0.1:11434", "apple-m4", [model("qwen")])
    two = worker("two", "http://127.0.0.1:11434/", "apple-m4", [model("qwen")])
    error = assert_raises(AdventureFinderWorkspace::Error) do
      merge(snapshot("rpof-a", 1, [one]), snapshot("low-a", 1, [two]))
    end
    assert_includes error.message, "duplicate worker endpoint"
  end

  def test_lc06_child_failure_or_malformed_snapshot_never_degrades_to_zero_capacity
    good = result(snapshot("rpof-a", 1, []))
    runner = Runner.new([good, { stdout: "", stderr: "LOW unavailable", success: false }])
    error = assert_raises(AdventureFinderWorkspace::Error) { merger(runner:).snapshot }
    assert_includes error.message, "LOW unavailable"
    refute File.exist?(File.join(@root, "merged-worker-registry.json"))

    error = assert_raises(AdventureFinderWorkspace::Error) do
      merger(runner: Runner.new([good, { stdout: "not-json" }]), root: "malformed").snapshot
    end
    assert_includes error.message, "invalid JSON"
  end

  def test_lc07_stable_identity_monotonic_revision_and_byte_stable_replay
    first_rpof = snapshot("rpof-a", 1, [])
    first_low = snapshot("low-a", 1, [worker("local", "http://127.0.0.1:11434", "m4", [model("qwen")])])
    runner = Runner.new([result(first_rpof), result(first_low), result(first_rpof), result(first_low)])
    publisher = merger(runner:)
    first = publisher.snapshot
    replay = publisher.snapshot
    assert_equal first, replay
    assert_equal 1, replay.fetch("revision")

    @now += 2
    next_rpof = snapshot("rpof-a", 2, [], published: @now)
    next_low = snapshot("low-a", 2, first_low.fetch("workers"), published: @now)
    advanced = merger(runner: Runner.new([result(next_rpof), result(next_low)])).snapshot
    assert_equal first.fetch("registry_id"), advanced.fetch("registry_id")
    assert_equal 2, advanced.fetch("revision")
  end

  def test_lc08_child_rollback_same_revision_rewrite_and_identity_change_fail_closed
    initial = [snapshot("rpof-a", 2, []), snapshot("low-a", 2, [])]
    merge(*initial)
    @now += 2

    rollback = assert_raises(AdventureFinderWorkspace::Error) do
      merge(snapshot("rpof-a", 1, [], published: @now), snapshot("low-a", 3, [], published: @now))
    end
    assert_includes rollback.message, "moved backwards"

    rewritten = snapshot("rpof-a", 2, [], published: Time.utc(2030, 1, 1, 0, 0, 10))
    rewritten["expires_at"] = (@now + 20).iso8601(0)
    error = assert_raises(AdventureFinderWorkspace::Error) do
      merge(rewritten, snapshot("low-a", 3, [], published: @now))
    end
    assert_includes error.message, "changed bytes at the same revision"

    error = assert_raises(AdventureFinderWorkspace::Error) do
      merge(snapshot("rpof-b", 3, [], published: @now), snapshot("low-a", 3, [], published: @now))
    end
    assert_includes error.message, "changed registry identity"
  end

  private

  def merge(rpof, low, root: nil)
    merger(runner: Runner.new([result(rpof), result(low)]), root:).snapshot
  end

  def merger(runner:, root: nil)
    sources = %w[rpof low].map do |name|
      AdventureFinderWorkspace::WorkerRegistryMerger::Source.new(
        name:, environment: {}, argv: [name], chdir: @root
      )
    end
    AdventureFinderWorkspace::WorkerRegistryMerger.new(
      state_root: File.join(@root, root || "state"), sources:, runner:, clock: -> { @now },
      id_generator: -> { "af-merged-test" }
    )
  end

  def result(document) = { stdout: "#{JSON.generate(document)}\n" }

  def snapshot(id, revision, workers, published: @now)
    { "contract_version" => "dynamic-worker-registry/v0.1", "registry_id" => id,
      "revision" => revision, "published_at" => published.iso8601(0),
      "expires_at" => (published + 30).iso8601(0), "workers" => workers }
  end

  def model(name)
    { "model" => name, "digest" => Digest::SHA256.hexdigest(name), "context_length" => 131_072,
      "fully_gpu_resident" => true }
  end

  def worker(id, endpoint, gpu, models)
    value = { "worker_id" => id, "generation_id" => "generation-1", "endpoint" => endpoint,
              "state" => "READY", "labels" => [],
              "capabilities" => { "gpu_id" => gpu, "ollama" => { "models" => models } } }
    fingerprint_input = { "gpu_id" => gpu, "labels" => [], "ollama_models" => models.map do |row|
      { "context_length" => row.fetch("context_length"), "digest" => row.fetch("digest"),
        "fully_gpu_resident" => row.fetch("fully_gpu_resident"), "model" => row.fetch("model") }
    end }
    value.merge("capability_fingerprint" => Digest::SHA256.hexdigest(JSON.generate(fingerprint_input)))
  end

  def source_repository(name, executable)
    root = File.join(@root, name)
    FileUtils.mkdir_p(File.join(root, "bin"))
    File.write(File.join(root, "Gemfile"), "source 'https://example.invalid'\n")
    File.write(File.join(root, "bin", executable), "#!/bin/sh\n")
    FileUtils.chmod(0o755, File.join(root, "bin", executable))
    root
  end
end
