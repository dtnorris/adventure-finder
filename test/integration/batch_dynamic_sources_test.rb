# frozen_string_literal: true

require "minitest/autorun"
require_relative "../support/batch_dynamic_fixture"
require_relative "../batch_worker_source_contract_test"

# FO-25 exercises the actual public AF-to-WLO composition with synthetic work.
# No production scorer, provider, capacity operation or owner implementation is
# replaced. Tests inspect bindings only after public observations establish them.
class BatchDynamicSourcesTest < Minitest::Test
  # Dispose test-owned processes on assertion failure as well as success.
  def teardown
    warn @fixture.diagnostics if @fixture && !passed?
    warn "Retained failed fixture: #{@fixture.root}" if @fixture && !passed?
    @fixture&.close(preserve: !passed?)
  end

  # One uninterrupted foreground resume: wait, LOW, RPOF, then healthy RPOF after
  # idle LOW failure. Original successes/failures and every binding stay intact.
  def test_continuous_public_resume_waits_consumes_both_and_survives_idle_source_failure
    @fixture = BatchDynamicFixture.new(jobs: [
      {"job_id" => "local-first", "pool_id" => "qwen27"},
      {"job_id" => "remote-second", "pool_id" => "gptoss", "depends_on_job_ids" => ["local-first"]},
      {"job_id" => "healthy-third", "pool_id" => "gemma", "depends_on_job_ids" => ["remote-second"]}
    ])
    retained = @fixture.retained_evidence(%w[retained-0 retained-1])
    before = @fixture.observe("paused")
    assert_equal "paused", before.fetch("status")
    assert_equal 3, before.dig("counts", "pending")
    @fixture.publish("local", [])
    @fixture.publish("remote", [])
    pid = @fixture.launch
    waiting = @fixture.await("waiting with empty publishers") do |report|
      report if report.fetch("executor_active") && report.fetch("worker_sources").length == 2
    end
    assert_equal "running", waiting.fetch("status")
    assert_equal before.fetch("counts"), waiting.fetch("counts")
    assert waiting.fetch("pool_status").any? { |pool| pool.fetch("state") == "WAITING" }
    assert waiting.fetch("worker_sources").all? { |source| source.fetch("policy") == "optional" && !source.fetch("blocking") }
    assert_equal retained, @fixture.retained_evidence(%w[retained-0 retained-1])
    pending = waiting.fetch("jobs").select { |job| job.fetch("status") == "pending" }
    assert pending.all? { |job| job["attempt"].nil? }

    @fixture.publish("local", [@fixture.worker("local", [@fixture.pools.fetch(0)])])
    local = await_running("local-first")
    assert_same_owner(waiting, local, pid)
    assert_binding("local-first", "fo25-local")
    @fixture.release("local-first")
    await_complete("local-first")

    @fixture.publish("remote", [@fixture.worker("remote", [@fixture.pools.fetch(1)])])
    remote = await_running("remote-second")
    assert_same_owner(waiting, remote, pid)
    assert_binding("remote-second", "fo25-remote")
    @fixture.release("remote-second")
    await_complete("remote-second")

    # Both publishers have contributed; neither owns a running attempt here.
    assert_empty @fixture.store.dynamic_running_attempts
    @fixture.unavailable("local")
    @fixture.publish("remote", [@fixture.worker("remote", [@fixture.pools.fetch(2)], generation: "generation-2")])
    healthy = await_running("healthy-third")
    assert_same_owner(waiting, healthy, pid)
    local_health = healthy.fetch("worker_sources").find { |source| source.fetch("source_name") == "local" }
    assert_equal "failure", local_health.fetch("last_poll_result")
    assert_includes local_health.fetch("failure_reason"), "offline local publisher unavailable"
    refute local_health.fetch("blocking")
    assert_binding("healthy-third", "fo25-remote")
    @fixture.release("healthy-third")
    result = @fixture.wait(pid)
    assert_equal 2, result.exitstatus, @fixture.diagnostics
    final = @fixture.observe("failure-bearing terminal")
    assert_equal "workload_failed", final.fetch("status")
    assert_equal({"complete" => 4, "failed" => 1, "running" => 0, "pending" => 0}, final.fetch("counts"))
    assert_equal 100.0, final.fetch("progress_percent")
    refute final.fetch("executor_active")
    assert_equal retained, @fixture.retained_evidence(%w[retained-0 retained-1])
    assert_equal 1, @fixture.store.metadata_for(@fixture.plan.jobs.fetch(1)).fetch("attempt")
    %w[local-first remote-second healthy-third].each { |id| assert_binding(id) }
    text, code = @fixture.public_wlo("status", @fixture.plan_path, "--output", @fixture.output, "--human", "--verbose")
    assert_equal 0, code, text
    assert_includes text, "policy=optional"
    assert_includes text, "poll=failure"
  end

  # A valid READY publication with a wrong full digest cannot dispatch. A later
  # exact publication enables the same waiting execution while RPOF is failed.
  def test_corrupt_digest_negative_control_then_healthy_local_with_failed_remote
    @fixture = BatchDynamicFixture.new(jobs: [{"job_id" => "negative-control", "pool_id" => "qwen27"}])
    original = @fixture.retained_evidence(%w[retained-0 retained-1])
    wrong = @fixture.worker("local", [@fixture.pools.first])
    wrong.dig("capabilities", "ollama", "models").first["digest"] = "0" * 64
    @fixture.fingerprint!(wrong)
    document = @fixture.publish("local", [wrong])
    @fixture.unavailable("remote")
    pid = @fixture.launch
    waiting = @fixture.await("exact digest rejected") do |report|
      report if report.fetch("executor_active") && report.fetch("worker_sources").length == 2 &&
        report.fetch("pool_status").any? { |pool| pool.fetch("pool_id") == "qwen27" && pool.fetch("reason") == "READY_WORKERS_INCOMPATIBLE" }
    end
    assert_equal 1, waiting.dig("counts", "pending")
    assert_equal 0, waiting.dig("counts", "running")
    assert_nil @fixture.store.metadata_for(@fixture.plan.jobs.last)
    registry = WorkloadOrchestrator::DynamicWorkerRegistry.new(JSON.generate(document), now: Time.now.utc)
    match = WorkloadOrchestrator::CapabilityMatcher.new(plan: @fixture.plan)
      .match_job(job: @fixture.plan.jobs.last, worker: registry.entries.first)
    assert_equal ["digest_mismatch"], match.reasons
    @fixture.publish("local", [@fixture.worker("local", [@fixture.pools.first])])
    running = await_running("negative-control")
    assert_same_owner(waiting, running, pid)
    assert_binding("negative-control", "fo25-local")
    @fixture.release("negative-control")
    assert_equal 2, @fixture.wait(pid).exitstatus
    assert_equal original, @fixture.retained_evidence(%w[retained-0 retained-1])
  end

  # Full synthetic accounting retains the historical boundary, exact four pool
  # identities, prior hashes/history, and executes precisely the 112 pending jobs.
  def test_192_job_accounting_preserves_80_original_terminal_jobs
    jobs = Array.new(112) do |index|
      {"job_id" => "pending-#{index}", "pool_id" => %w[qwen27 gptoss gemma qwen].fetch(index % 4)}
    end
    @fixture = BatchDynamicFixture.new(jobs:, complete: 75, failed: 5)
    ids = @fixture.plan.jobs.first(80).map(&:id)
    original = @fixture.retained_evidence(ids)
    before = @fixture.observe("75 complete 5 failed 112 pending")
    assert_equal({"complete" => 75, "failed" => 5, "running" => 0, "pending" => 112}, before.fetch("counts"))
    assert_equal 192, @fixture.plan.jobs.length
    assert_equal 4, @fixture.pools.length
    %w[local remote].each do |name|
      workers = @fixture.pools.map.with_index do |pool, index|
        @fixture.worker(name, [pool]).merge("worker_id" => "worker-#{pool.fetch('pool_id')}",
          "endpoint" => "http://127.0.0.1:#{(name == 'local' ? 11450 : 11460) + index}")
      end
      @fixture.publish(name, workers)
    end
    jobs.each { |job| @fixture.release(job.fetch("job_id")) }
    pid = @fixture.launch
    assert_equal 2, @fixture.wait(pid).exitstatus, @fixture.diagnostics
    final = @fixture.observe("187 complete 5 failed 0 pending")
    assert_equal "workload_failed", final.fetch("status")
    assert_equal({"complete" => 187, "failed" => 5, "running" => 0, "pending" => 0}, final.fetch("counts"))
    assert_equal 192, final.fetch("terminal")
    assert_equal original, @fixture.retained_evidence(ids)
    assert_equal before.fetch("retry_history", []), final.fetch("retry_history", [])
    assert_equal before.dig("circuit_breaker", "history"), final.dig("circuit_breaker", "history")
    assert_equal jobs.map { |job| job.fetch("job_id") }.sort,
      Dir.glob(File.join(@fixture.root, "afw", "*.started")).map { |path| File.basename(path, ".started") }.sort
    jobs.each { |job| assert_binding(job.fetch("job_id")) }
    registries = @fixture.plan.jobs.drop(80).map do |job|
      @fixture.store.metadata_for(job).dig("worker_execution_identity", "registry_id")
    end.uniq.sort
    assert_equal %w[fo25-local fo25-remote], registries
  end

  # Real running-worker loss remains in doubt, halts dispatch, and refuses a
  # later resume. A healthy replacement never rewrites the original binding.
  def test_running_worker_loss_requires_explicit_recovery
    @fixture = BatchDynamicFixture.new(jobs: [{"job_id" => "lost", "pool_id" => "qwen27"}], complete: 0, failed: 0)
    @fixture.publish("local", [@fixture.worker("local", [@fixture.pools.first])])
    @fixture.publish("remote", [])
    pid = @fixture.launch
    await_running("lost")
    binding = @fixture.store.metadata_for(@fixture.plan.jobs.first).slice("worker_execution_identity", "worker_registry_binding")
    @fixture.publish("local", [])
    @fixture.publish("remote", [@fixture.worker("remote", [@fixture.pools.first])])
    @fixture.await("running worker loss") { |report| report["dispatch_halt"] }
    @fixture.release("lost")
    assert_equal 2, @fixture.wait(pid).exitstatus
    metadata = @fixture.store.metadata_for(@fixture.plan.jobs.first)
    assert_equal binding, metadata.slice("worker_execution_identity", "worker_registry_binding")
    assert_equal "dynamic_worker_loss_in_doubt", metadata.dig("evidence", "kind")
    assert_equal 1, metadata.fetch("attempt")
    assert_equal "failed", metadata.fetch("status")
    before = @fixture.retained_evidence(["lost"])
    assert_equal 2, @fixture.wait(@fixture.launch).exitstatus
    assert_equal before, @fixture.retained_evidence(["lost"])
    refute File.file?(File.join(@fixture.root, "afw", "retained-0.started"))
  end

  # Public start/resume must refuse before source generation, preparation, pause
  # clearing or dispatch for each established safety boundary. All corruption
  # and loss inputs are restricted to this disposable synthetic fixture.
  def test_af_binary_safety_refusals_preserve_all_execution_bytes
    cases = {
      "paused start" => ["start", "bin/af-batch resume 39", ->(fixture) {}],
      "breaker" => ["resume", "circuit breaker", ->(fixture) {}],
      "interruption" => ["resume", "explicit retry authorization", ->(fixture) { fixture.store.record_interruption!("TERM") }],
      "dispatch halt" => ["resume", "dispatch is halted", ->(fixture) { fixture.store.record_dispatch_halt!(kind: "worker_registry", error: "synthetic halt") }],
      "orphaned running attempt" => ["resume", "running attempts without an active executor", lambda do |fixture|
        document = fixture.publish("local", [fixture.worker("local", [fixture.pools.first])])
        worker = WorkloadOrchestrator::DynamicWorkerRegistry.new(JSON.generate(document), now: Time.now.utc).entries.first
        fixture.store.record_dynamic_running!(job: fixture.plan.jobs.last, worker:, environment_keys: [])
      end],
      "corrupt retained plan" => ["resume", "retained", ->(fixture) { File.write(File.join(fixture.output, "plan.json"), "corrupt") }],
      "stale production context" => ["resume", "SHA-256 mismatch", ->(fixture) { File.open(fixture.plan_path, "a") { |file| file.write(" ") } }],
      "changed retained workdir" => ["resume", "different execution identity", lambda do |fixture|
        FileUtils.mkdir_p(File.join(fixture.root, "other-workdir"))
        fixture.configure { |document| document.dig("contexts", "batch", "39", "afw")["repository_root"] = "other-workdir" }
      end],
      "unauthorized source policy" => ["resume", "exactly match", lambda do |fixture|
        fixture.configure { |document| document.dig("contexts", "batch", "39", "worker_source_policies").delete("remote") }
      end]
    }
    cases.each do |name, (action, message, arrange)|
      @fixture = BatchDynamicFixture.new(jobs: [{"job_id" => "forbidden", "pool_id" => "qwen27"}],
        complete: 0, failed: name == "breaker" ? 10 : 0)
      arrange.call(@fixture)
      before = execution_bytes
      assert_equal 2, @fixture.wait(@fixture.launch(action)).exitstatus, name
      assert_includes File.read(File.join(@fixture.root, "owner.stderr")), message, name
      assert_equal before, execution_bytes, name
      assert_empty Dir.glob(File.join(@fixture.root, "*", "calls.jsonl")), name
      assert_empty Dir.glob(File.join(@fixture.root, "worker-sources", "*")), name
      @fixture.close
      @fixture = nil
    end
  end

  # Existing execution lock ownership refuses a second AF owner. Teardown after
  # an assertion/timeout exception interrupts only the known child; an unrelated
  # positively identified sentinel survives until this test reaps it.
  def test_lock_refusal_and_scoped_cleanup_on_timeout_and_interruption
    @fixture = BatchDynamicFixture.new(jobs: [{"job_id" => "pending", "pool_id" => "qwen27"}], complete: 0, failed: 0)
    @fixture.store.with_execution_lock do
      before = execution_bytes
      assert_equal 2, @fixture.wait(@fixture.launch).exitstatus
      assert_includes File.read(File.join(@fixture.root, "owner.stderr")), "active executor"
      assert_equal before, execution_bytes
    end
    sentinel = Process.spawn(RbConfig.ruby, "-e", "sleep 30", out: File::NULL, err: File::NULL)
    @fixture.unavailable("local")
    @fixture.unavailable("remote")
    pid = @fixture.launch
    waiting = @fixture.await("both optional unavailable") do |report|
      report if report.fetch("executor_active") && report.fetch("worker_sources").length == 2
    end
    assert_equal 1, waiting.dig("counts", "pending")
    assert_equal 0, waiting.dig("counts", "running")
    assert waiting.fetch("worker_sources").all? { |source| source.fetch("last_poll_result") == "failure" && !source.fetch("blocking") }
    assert_raises(Timeout::Error) { @fixture.wait(pid, seconds: 0.01) }
    assert_equal 1, Process.kill(0, sentinel)
    Process.kill("TERM", pid)
    assert_equal 143, @fixture.wait(pid).exitstatus
    assert_equal "interrupted", @fixture.observe("intentional test-owner TERM").fetch("status")
    assert_equal 1, Process.kill(0, sentinel)
    # Exercise the same ensure path used by assertion failures with a live owner.
    @fixture.close
    @fixture = BatchDynamicFixture.new(jobs: [{"job_id" => "pending", "pool_id" => "qwen27"}], complete: 0, failed: 0)
    @fixture.unavailable("local")
    @fixture.unavailable("remote")
    pid = @fixture.launch
    @fixture.await("owner for exception cleanup") { |report| report.fetch("executor_active") }
    assert_raises(Minitest::Assertion) do
      begin
        raise Minitest::Assertion, "deliberate fixture failure"
      ensure
        @fixture.close
        @fixture = nil
      end
    end
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    assert_equal 1, Process.kill(0, sentinel)
  ensure
    if sentinel
      Process.kill("TERM", sentinel)
      Process.waitpid(sentinel)
    end
  end

  private

  # Snapshot all retained execution bytes for before-launch refusal assertions.
  # This read-only helper never repairs or normalizes owner state.
  def execution_bytes
    Dir.glob(File.join(@fixture.output, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
      .to_h { |path| [path, File.binread(path)] }
  end

  # Wait for public running evidence and the actual payload's startup barrier.
  # Returns the public report, or propagates the fixture's bounded timeout.
  def await_running(id)
    @fixture.await("running #{id}") do |report|
      row = report.fetch("jobs").find { |job| job.fetch("job_id") == id }
      report if row.fetch("status") == "running" && File.file?(File.join(@fixture.root, "afw", "#{id}.started"))
    end
  end

  # Wait for the owner to record terminal success, not merely payload exit.
  def await_complete(id)
    @fixture.await("complete #{id}") do |report|
      report.fetch("jobs").any? { |job| job.fetch("job_id") == id && job.fetch("status") == "complete" }
    end
  end

  # Verify retained execution identity and positive ownership at every phase.
  def assert_same_owner(before, after, pid)
    %w[plan_id plan_sha256 workdir started_at].each { |key| assert_equal before.fetch(key), after.fetch(key) }
    assert after.fetch("executor_active")
    assert_equal 1, Process.kill(0, pid)
  end

  # Compare every immutable dispatch field to exact advertised source bytes and
  # the selected frozen pool. Errors/unknown IDs fail the test rather than infer.
  def assert_binding(id, registry_id = nil)
    job = @fixture.plan.jobs.find { |entry| entry.id == id }
    metadata = @fixture.store.metadata_for(job)
    identity = metadata.fetch("worker_execution_identity")
    assert_equal registry_id, identity.fetch("registry_id") if registry_id
    binding = metadata.fetch("worker_registry_binding")
    bytes = @fixture.publication_bytes.fetch(binding.fetch("registry_snapshot_sha256"))
    document = JSON.parse(bytes)
    worker = document.fetch("workers").find { |entry| entry.fetch("worker_id") == identity.fetch("worker_id") }
    expected = worker.slice("worker_id", "generation_id", "endpoint", "capability_fingerprint")
                     .merge("registry_id" => document.fetch("registry_id"))
    assert_equal expected, identity
    assert_equal document.fetch("revision"), binding.fetch("registry_revision")
    assert_equal Digest::SHA256.hexdigest(bytes), binding.fetch("registry_snapshot_sha256")
    snapshot = metadata.fetch("worker_snapshot")
    assert_equal worker.fetch("capabilities"), snapshot.fetch("capabilities")
    assert_equal worker.fetch("labels"), snapshot.fetch("labels")
    assert_equal "READY", snapshot.fetch("state")
    requirement = @fixture.plan.pool(job.pool_id).ollama_requirement
    model = snapshot.dig("capabilities", "ollama", "models").find { |entry| entry.fetch("model") == requirement.fetch("model") }
    assert_equal requirement.fetch("expected_digest"), model.fetch("digest")
    assert_equal requirement.fetch("required_context_length"), model.fetch("context_length")
    assert_equal true, model.fetch("fully_gpu_resident")
    assert_equal 1, metadata.fetch("attempt")
    payload = JSON.parse(File.read(File.join(@fixture.root, "afw", "#{id}.started")))
    assert_equal identity.fetch("endpoint"), payload.fetch("endpoint")
    if metadata.fetch("status") == "complete"
      assert_equal "synthetic result #{id}\x00\xFF\n".b,
        File.binread(File.join(@fixture.output, "runs", id, "stdout.log"))
    end
  end
end
