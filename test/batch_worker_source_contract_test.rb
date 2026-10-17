# frozen_string_literal: true

require "minitest/autorun"
require_relative "support/batch_dynamic_fixture"

# AF-generated configuration composed with real WLO source-health, validation,
# matching and loss contracts. Controlled clocks are owner-supported test seams;
# no component contract or production registry authority is copied or weakened.
class BatchWorkerSourceContractTest < Minitest::Test
  # Create only disposable synthetic execution and publisher state.
  def setup
    @fixture = BatchDynamicFixture.new(jobs: [{"job_id" => "pending", "pool_id" => "qwen27"}], complete: 0, failed: 0)
    @now = Time.now.utc
  end

  # Always stop owned processes; preserve failed fixture bytes for diagnosis.
  def teardown
    warn "Retained failed fixture: #{@fixture.root}" unless passed?
    @fixture.close(preserve: !passed?)
  end

  # Both unavailable and valid empty publishers wait. Each healthy publisher
  # contributes independently; failed refresh retains only unexpired evidence.
  def test_optional_availability_and_expiry_matrix
    @fixture.unavailable("local")
    @fixture.unavailable("remote")
    set = registry_set
    set.poll_once
    refute set.dispatch_blocked?
    assert_empty assignments(set)
    assert set.source_health.values.all? { |row| row.fetch("last_poll_result") == "failure" && !row.fetch("blocking") }

    @fixture.publish("local", [])
    @fixture.publish("remote", [])
    set.poll_once
    refute set.dispatch_blocked?
    assert_empty assignments(set)
    assert set.source_health.values.all? { |row| row.fetch("usable") }

    local = @fixture.publish("local", [@fixture.worker("local", [@fixture.pools.first])], expires_at: @now + 10)
    @fixture.unavailable("remote")
    set.poll_once
    assert_equal ["fo25-local"], assignments(set).map { |assignment| assignment.worker.registry_id }
    original = checkpoint("local")
    @fixture.unavailable("local")
    set.poll_once
    assert_equal original, checkpoint("local")
    assert_equal ["fo25-local"], assignments(set).map { |assignment| assignment.worker.registry_id }
    assert_equal "failure", set.source_health.dig("local", "last_poll_result")
    assert_equal local.fetch("expires_at"), set.source_health.dig("local", "last_accepted_expires_at")

    @now += 11
    @fixture.publish("remote", [@fixture.worker("remote", [@fixture.pools.first])])
    set.poll_once
    assert_equal ["fo25-remote"], assignments(set).map { |assignment| assignment.worker.registry_id }
    assert_equal "stale", set.source_health.dig("local", "state")
    assert_equal original, checkpoint("local")
    refute set.dispatch_blocked?
    report = WorkloadOrchestrator::ExecutionReport.new(plan: @fixture.plan, output: @fixture.output, clock: -> { @now })
    assert_equal set.source_health.values.sort_by { |row| row.fetch("source_name") }, report.document.fetch("worker_sources")
    out = StringIO.new
    report.print(out, verbose: true)
    assert_includes out.string, "local policy=optional state=stale poll=failure blocking=false"
    assert_includes out.string, "remote policy=optional state=fresh poll=success blocking=false"
  end

  # No explicit policy opt-in remains v0.1/all-required and blocks on missing
  # source authority despite another registry having compatible capacity.
  def test_non_opted_in_required_source_still_blocks
    @fixture.configure { |document| document.dig("contexts", "batch", "39").delete("worker_source_policies") }
    @fixture.publish("local", [@fixture.worker("local", [@fixture.pools.first])])
    @fixture.unavailable("remote")
    set = registry_set.poll_once
    assert_equal %w[required required], set.source_health.values.map { |row| row.fetch("policy") }
    assert set.dispatch_blocked?
    assert_equal ["remote"], set.blocking_sources.map { |row| row.fetch("source_name") }
    @fixture.store.clear_pause!
    report = WorkloadOrchestrator::ExecutionReport.new(plan: @fixture.plan, output: @fixture.output).document
    assert_equal "REQUIRED_WORKER_SOURCE_UNAVAILABLE", report.fetch("pool_status").first.fetch("reason")
  end

  # Malformed, replayed, forged and stale replacements cannot create capacity
  # or rewrite accepted evidence. Healthy namespaces continue independently.
  def test_invalid_replacement_matrix_preserves_accepted_checkpoint
    empty = @fixture.publish("local", [])
    @fixture.publish("remote", [@fixture.worker("remote", [@fixture.pools.first])])
    set = registry_set.poll_once
    original = checkpoint("local")
    candidate = @fixture.snapshot("local", [@fixture.worker("local", [@fixture.pools.first])])
    invalid = [
      ["{", "invalid"],
      [JSON.generate(candidate.merge("revision" => 0)), "rolled back"],
      [JSON.generate(candidate.merge("revision" => empty.fetch("revision"))), "changed contents"],
      [JSON.generate(candidate.merge("registry_id" => "forged-namespace")), "identity changed"],
      [JSON.generate(candidate.merge("expires_at" => (@now - 1).iso8601)), "expired"],
      [JSON.generate(candidate.merge("published_at" => (@now + 60).iso8601)), "future"]
    ]
    %w[generation_id capability_fingerprint].each do |field|
      forged = Marshal.load(Marshal.dump(candidate))
      forged.fetch("workers").first[field] = field == "generation_id" ? "" : "0" * 64
      invalid << [JSON.generate(forged), field == "generation_id" ? "generation_id" : "fingerprint"]
    end
    invalid.each do |bytes, reason|
      @fixture.replace_publication("local", bytes)
      set.poll_once
      assert_equal original, checkpoint("local"), reason
      assert_equal ["fo25-remote"], set.ready_workers.map(&:registry_id), reason
      assert_equal "failure", set.source_health.dig("local", "last_poll_result"), reason
      assert_includes set.source_health.dig("local", "failure_reason").downcase, reason
      refute set.dispatch_blocked?
    end
  end

  # All exact capability comparisons use WLO's matcher on validated records.
  # Higher contexts, full-digest changes, CPU residency, labels and GPU identity
  # cannot be inferred as compatible merely because source policy is optional.
  def test_exact_capability_matrix
    requirement = @fixture.plan.pools.first.ollama_requirement.merge("required_gpu_id" => "fo25-synthetic-gpu")
    variants = {
      "model_mismatch" => ->(row) { row.dig("capabilities", "ollama", "models").first["model"] = "wrong-model" },
      "digest_mismatch" => ->(row) { row.dig("capabilities", "ollama", "models").first["digest"] = "0" * 64 },
      "context_length_mismatch" => ->(row) { row.dig("capabilities", "ollama", "models").first["context_length"] = 131_073 },
      "full_gpu_residency_required" => ->(row) { row.dig("capabilities", "ollama", "models").first["fully_gpu_resident"] = false },
      "missing_required_label" => ->(row) { row.fetch("labels").delete("inference") },
      "gpu_id_mismatch" => ->(row) { row.fetch("capabilities")["gpu_id"] = "wrong-gpu" }
    }
    variants.each do |reason, corrupt|
      row = @fixture.worker("local", [@fixture.pools.first])
      corrupt.call(row)
      @fixture.fingerprint!(row)
      document = @fixture.snapshot("local", [row])
      worker = WorkloadOrchestrator::DynamicWorkerRegistry.new(JSON.generate(document), now: @now).entries.first
      result = WorkloadOrchestrator::CapabilityMatcher.match(worker:, required_labels: ["inference"], ollama_requirement: requirement)
      assert_equal [reason], result.reasons
      refute result.compatible?
    end
  end

  # Optional policy cannot suppress duplicate registry identity as a source
  # health warning. Runner must halt before any scorer can be invoked.
  def test_duplicate_registry_identity_remains_fatal
    local = @fixture.publish("local", [@fixture.worker("local", [@fixture.pools.first])])
    remote = @fixture.snapshot("remote", [@fixture.worker("remote", [@fixture.pools.first])])
    @fixture.replace_publication("remote", JSON.generate(remote.merge("registry_id" => local.fetch("registry_id"))))
    runner = WorkloadOrchestrator::Runner.new(plan: @fixture.plan,
      workers: WorkloadOrchestrator::WorkerSet.new({}), workdir: File.join(@fixture.root, "afw"),
      output_dir: @fixture.output, worker_source: @fixture.generated_sources, out: StringIO.new,
      command_executor: ->(*) { flunk "duplicate registry dispatched" })
    error = assert_raises(WorkloadOrchestrator::Error) { runner.run(resume: true) }
    assert_includes error.message, "duplicate registry_id"
    assert_equal "worker_registry", runner.store.dispatch_halt.fetch("kind")
    assert_nil runner.store.metadata_for(@fixture.plan.jobs.first)
  end

  private

  # Load AF-generated YAML into independently checkpointed real owner pollers.
  def registry_set
    WorkloadOrchestrator::WorkerRegistrySet.new(sources: @fixture.generated_sources,
      checkpoint_root: File.join(@fixture.output, "dynamic-workers"), clock: -> { @now })
  end

  # Ask the actual scheduler for assignments; this matrix does not execute them.
  def assignments(set)
    WorkloadOrchestrator::DynamicScheduler.new(plan: @fixture.plan, store: @fixture.store)
      .assignments(workers: set.ready_workers, current_workers: set.current_workers)
  end

  # Read accepted bytes unchanged, separately from mutable poll-health evidence.
  def checkpoint(name)
    File.binread(File.join(@fixture.output, "dynamic-workers", "sources", name, "checkpoint.json"))
  end
end
