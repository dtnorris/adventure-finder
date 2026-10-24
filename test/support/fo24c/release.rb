# frozen_string_literal: true

# Explicit cross-owner acceptance process. No production dependency is added.
require "rbconfig"
workspace = File.expand_path(ENV.fetch("AF_FO24C_WORKSPACE_ROOT"))
ENV["AF_FO21_WORKSPACE_ROOT"] = workspace
ENV["AF_FO22_WORKSPACE_ROOT"] = workspace
guard = File.join(workspace, "workload-orchestrator/test/acceptance/fo24a/offline_guard.rb")
require guard
Fo24aOfflineGuard.self_check!
require "timeout"
require "stringio"
require_relative "../../integration/fo22d_evidence_review_composition_test"
require_relative "capacity"
require File.join(workspace, "workload-orchestrator/lib/workload_orchestrator")
require File.join(workspace, "local-ollama-workers/lib/local_ollama_workers")
require File.join(workspace, "runpod-ollama-fleet/lib/runpod_ollama_fleet")
require File.join(workspace, "runpod-ollama-fleet/lib/local_model_evaluation/runpod_budget_guardian")
%w[batch model_preflight diagnostics review].each do |name|
  require_relative "../../../lib/adventure_finder_#{name}"
end

LocalModelEvaluation::RunpodClient.define_singleton_method(:new) do |*|
  Fo24aOfflineGuard.deny!("real provider client construction")
end
Fo21dDeadlineAdmissionTest::Provider.prepend(Module.new do
  attr_accessor :absence_uncertain
  def list_pods
    raise LocalModelEvaluation::RunpodClient::Error.new(503, "scripted uncertain absence") if absence_uncertain
    super
  end
  def method_missing(name, *) = Fo24aOfflineGuard.deny!("unsupported provider fake method #{name}")
  def respond_to_missing?(*) = false
end)

class Fo24cRelease < Fo22dEvidenceReviewCompositionTest
  W = WorkloadOrchestrator
  Result = Struct.new(:exitstatus) { def success? = exitstatus.zero? }
  ComponentResult = AdventureFinderWorkspace::BatchFrontDoor::ComponentRunner::Result
  Port = Struct.new(:methods) do
    def method_missing(name, *args, **kw)
      callable = methods[name]
      Fo24aOfflineGuard.deny!("unsupported local port #{name}") unless callable
      kw.empty? ? callable.call(*args) : callable.call(*args, **kw)
    end
    def respond_to_missing?(name, *) = methods.key?(name)
  end
  class Source < W::WorkerSource
    attr_accessor :document
    def latest_snapshot = JSON.generate(document)
  end

  def self.runnable_methods = public_instance_methods(false).grep(/^test_/).map(&:to_s).sort

  def setup
    super
    @workspace = ENV.fetch("AF_FO24C_WORKSPACE_ROOT")
    @capacity = Fo24cCapacity.new(File.join(@root, "rpof-state"))
    @capacity.setup
    @clock = -> { Time.now.utc }
    # Owner objects retain the original lambda over @now; synchronize at public operations.
    @capacity.now = @clock.call
    %w[workload-orchestrator local-ollama-workers runpod-ollama-fleet].each do |name|
      destination = name == "workload-orchestrator" ? @wlo_root : File.join(@root, name)
      %w[lib bin config Gemfile].each do |entry|
        source = File.join(@workspace, name, entry)
        next unless File.exist?(source)
        FileUtils.mkdir_p(destination)
        FileUtils.cp_r(source, File.join(destination, entry))
      end
    end
    configure_plan_and_context
    FileUtils.rm_rf(@wlo)
    FileUtils.mkdir_p(@wlo)
    @plan = W::Plan.load(@plan_path)
    @store = W::ExecutionStore.new(plan: @plan, workdir: @afw, output_dir: @wlo)
    @source = Source.new
    bootstrap_local
    @calls = []
    @pause_after_first = true
    @exit_code = 0
    @component_calls = []
    @out = StringIO.new
    @front = AdventureFinderWorkspace::BatchFrontDoor.new(
      registry_path: @registry_path, workspace_root: @root, out: @out,
      component_runner: self, executor: method(:execute), bundle_executable: RbConfig.ruby)
    install_admission_trace
  end

  def teardown
    @admission_trace&.disable
    Fo24aOfflineGuard.assert_clean!
    super
  end

  # These two test ports preserve generated argv, and call real owner APIs.
  # Only process transport and the scoring command's behavior are scripted.
  def capture(*args, chdir:, env: {})
    argv = args.last
    @component_calls << argv.dup
    if argv.include?("bin/rpof")
      assert_equal ["doctor", "campaign"], argv[3, 2]
      assert_equal File.join(@root, "rpof-state"), argv[argv.index("--state-root") + 1]
      report = RunpodOllamaFleet::OperatorDoctor.new(campaign_binding: @capacity.binding).campaign
      return ComponentResult.new(stdout: JSON.generate(report), stderr: "", status: Result.new(0))
    end
    index = argv.index { |value| File.basename(value) == "wlo" }
    raise "unexpected component command #{argv.inspect}" unless index
    out, err = StringIO.new, StringIO.new
    code = W::CLI.new(argv.drop(index + 1), out: out, err: err, root: chdir).run
    ComponentResult.new(stdout: out.string, stderr: err.string, status: Result.new(code))
  end

  def execute(_environment, argv, chdir:)
    assert_equal @wlo_root, chdir
    assert_equal File.join(@wlo_root, "bin/wlo"), argv.first
    assert_equal @plan_path, argv[2]
    assert_equal @afw, argv[argv.index("--workdir") + 1]
    assert_equal @wlo, argv[argv.index("--output") + 1]
    sources = YAML.safe_load_file(argv[argv.index("--worker-sources-config") + 1])
    assert_equal ["local"], sources.fetch("sources").map { |row| row.fetch("name") }
    # Check the complete component-bundle launch contract, including removal
    # of an inherited lockfile before LOW's own bundle is selected.
    local_source = sources.fetch("sources").fetch(0)
    local_root = File.join(@root, "local-ollama-workers")
    assert_equal "env", File.basename(local_source.fetch("command"))
    assert_equal ["-u", "BUNDLE_LOCKFILE", RbConfig.ruby, "exec",
                  File.join(local_root, "bin/low"), "workers", "--json"],
                 local_source.fetch("args")
    assert_equal({"BUNDLE_GEMFILE" => File.join(local_root, "Gemfile")},
                 local_source.fetch("environment"))
    assert_equal local_root, local_source.fetch("workdir")
    configured = W::WorkerSourceConfiguration.load(argv[argv.index("--worker-sources-config") + 1])
    entry = configured.entries.fetch(0)
    # Reuse WLO's validated command-source transport seam; no owner selection
    # or registry parsing is implemented by this harness.
    transport = lambda do |environment, *command, chdir:|
      assert_equal entry.source.environment, environment
      assert_equal entry.source.argv, command
      assert_equal entry.source.workdir, chdir
      [@source.latest_snapshot, "", Result.new(0)]
    end
    source = W::CommandWorkerSource.new(entry.source.argv.first, entry.source.argv.drop(1),
      environment: entry.source.environment, workdir: entry.source.workdir, command_executor: transport)
    selected_sources = W::WorkerSourceSet.new([
      W::WorkerSourceSet::Entry.new(name: entry.name, policy: entry.policy, source: source)
    ])
    runner = W::Runner.new(plan: @plan, workers: W::WorkerSet.new({}), workdir: @afw,
      output_dir: @wlo, out: StringIO.new, worker_source: selected_sources,
      worker_registry_clock: @clock, worker_poll_interval: 0.001,
      worker_registry_sleeper: ->(*) { @no_capacity ? @store.pause! : sleep(0.005) }, command_executor: method(:score))
    @last_execution = Timeout.timeout(10) { runner.run(resume: argv[1] == "resume") }
  end

  def score(environment, *argv, chdir:)
    assert_equal @afw, chdir
    job = @plan.jobs.find { |row| @store.metadata_for(row)&.fetch("status") == "running" }
    metadata = @store.metadata_for(job)
    @calls << Marshal.load(Marshal.dump(metadata))
    assert_equal metadata.dig("worker_execution_identity", "endpoint"), environment.fetch("WLO_WORKER_ENDPOINT")
    assert_equal job.argv, argv
    if job.id == JOB_ID
      mutate_json(@request_path) { |row| row["recorded_at"] = Time.now.utc.iso8601 } unless @preserve_artifacts
      # One real elapsed second gives the planner a nonzero retained measurement window.
      sleep 1.05 if @pause_after_first
      @store.pause! if @pause_after_first
    end
    ["scripted scoring evidence; no inference\n", "", Result.new(@exit_code)]
  end

  def test_green_path_context_preflight_execution_planning_review_and_verified_teardown
    before = canonical_bytes
    registry = context_registry
    assert_empty registry.verify("batch", "39")
    assert_empty registry.verify("fleet", "A")
    assert_equal @plan.sha256, registry.resolve("batch", "39").dig("plan", "sha256")
    assert_equal @capacity.campaign.campaign_id, registry.resolve("fleet", "A").fetch("campaign_id")
    assert_equal JOB_ID, AdventureFinderWorkspace::JobHandleResolver.load(@plan_path).resolve("0001-combat")
    preflight = AdventureFinderWorkspace::ModelPreflight.new(registry: registry).resolve(batch_handle: "39", alias_name: "qwen")
    assert_equal @capability, preflight.fetch("capability_request")
    assert_equal 0, @front.run("start", "39")
    assert_equal "paused", @last_execution
    diagnostics
    @proposals = proposal
    assert_equal "feasible", @proposals.fetch("status")
    refute @proposals.fetch("mutation_permission")
    refute_equal @proposals.fetch("target_completion_deadline_utc"), @capacity.state.fetch("deadline_at_utc")
    limits = @capacity.authority
    result = @capacity.select(@proposals)
    assert_equal "PASS", result.dig("safety_report", "safety_gate")
    assert_equal @proposals.dig("preferred_proposal", "worker_count"), @capacity.provider.creates.length
    assert_equal limits, @capacity.authority
    assert_equal @capacity.provider.creates.length, @capacity.events.count(:provider_create)
    assert @capacity.state.fetch("reservations").values.all? { |row| row.fetch("status") == "committed" }
    @pause_after_first = false
    @front.run("resume", "39")
    assert_equal "completed", @last_execution
    attempt = @store.metadata_for(@plan.jobs.first)
    assert_equal 1, attempt.fetch("attempt")
    assert_equal 0, attempt.fetch("exit_status")
    assert_equal @calls.first.fetch("worker_execution_identity"), attempt.fetch("worker_execution_identity")
    assert_equal "generation-1", attempt.dig("worker_execution_identity", "generation_id")
    assert_equal @plan.sha256, measurements.dig("execution", "plan_sha256")
    assert_equal 3, measurements.dig("work", "completed")
    stdout = prepare_review
    assert_includes stdout, "Pending: 1"
    assert_includes stdout, "Accepted: 0"
    assert_includes stdout, "NEXT HUMAN DECISION: edit #{@ledger_path}"
    receipt, package, ledger = File.binread(@receipt_path), package_bytes, File.binread(@ledger_path)
    assert_equal 1, JSON.parse(receipt).dig("attempt", "attempt")
    assert_includes prepare_review, "Package reused: true"
    assert_equal receipt, File.binread(@receipt_path)
    assert_equal package, package_bytes
    assert_equal ledger, File.binread(@ledger_path)
    assert_equal before, canonical_bytes
    teardown_capacity
    assert_equal before, canonical_bytes
    assert_equal attempt, @store.metadata_for(@plan.jobs.first)
    puts "FO-24C composed green path: pending human review; verified provider absence"
  end

  def test_context_unknown_ambiguous_and_frozen_mismatch_fail_closed
    assert_review_root_restoration
    registry = context_registry
    %w[batch fleet].each { |type| assert_raises(AdventureFinderWorkspace::Error) { registry.resolve(type, "unknown") } }
    resolver = AdventureFinderWorkspace::JobHandleResolver.load(@plan_path)
    assert_raises(AdventureFinderWorkspace::Error) { resolver.resolve("unknown") }
    plan = JSON.parse(File.binread(@plan_path))
    plan["jobs"] << plan.fetch("jobs").first.merge("job_id" => "other-adv0001-combat")
    assert_raises(AdventureFinderWorkspace::Error) { AdventureFinderWorkspace::JobHandleResolver.new(plan).resolve("0001-combat") }
    File.open(@plan_path, "a") { |file| file.write(" ") }
    assert_raises(AdventureFinderWorkspace::Error) { @front.run("start", "39") }
    assert_empty @calls
  end

  def test_no_eligible_incompatible_stale_and_not_ready_capacity_never_dispatches
    @no_capacity = true
    original = Marshal.load(Marshal.dump(@source.document))
    %w[empty model digest context residency stale not_ready].each do |fault|
      @source.document = Marshal.load(Marshal.dump(original))
      document = @source.document
      worker = document.fetch("workers").first
      model = worker.dig("capabilities", "ollama", "models").first
      case fault
      when "empty" then document["workers"] = []
      when "model" then model["model"] = "incompatible"
      when "digest" then model["digest"] = "b" * 64
      when "context" then model["context_length"] = 1024
      when "residency" then model["fully_gpu_resident"] = false
      when "stale" then document["published_at"] = (Time.now.utc - 120).iso8601; document["expires_at"] = (Time.now.utc - 60).iso8601
      when "not_ready" then worker["state"] = "NOT_READY"
      end
      worker["capability_fingerprint"] = LocalOllamaWorkers::Contract.capability_fingerprint(worker)
      FileUtils.rm_rf(@wlo)
      @front.run("start", "39")
      assert_equal "paused", @last_execution, fault
      assert_empty @calls, fault
    end
  end

  def test_invalid_resume_retry_and_breaker_override_ready_capacity
    assert_raises(AdventureFinderWorkspace::Error) { @front.run("resume", "39") }
    assert_raises(AdventureFinderWorkspace::Error) { @front.run("retry", "39", jobs: ["0001-combat"], reason: "reviewed") }
    @pause_after_first = false
    @exit_code = 7
    @front.run("start", "39")
    assert_equal "circuit_broken", @last_execution
    assert_equal "READY", @source.document.dig("workers", 0, "state")
    count = @calls.length
    assert_raises(AdventureFinderWorkspace::Error) { @front.run("resume", "39") }
    assert_equal count, @calls.length
  end

  def test_stale_measurements_mismatched_evidence_and_current_refusal
    @front.run("start", "39")
    wlo = measurements
    old = wlo.merge("measured_at_utc" => (Time.now.utc - 600).iso8601)
    refute_equal "feasible", proposal(wlo: old).fetch("status")
    bad = @capacity.evidence(1)
    bad["profile_id"] = "wrong"
    refute_equal "feasible", proposal(evidence: { 1 => bad }).fetch("status")
    refute_equal "feasible", proposal(evidence: { 1 => @capacity.evidence(2) }).fetch("status")
    good = proposal
    assert_equal "feasible", good.fetch("status")
    @capacity.guardian.healthy = false
    assert_raises(RunpodOllamaFleet::CampaignLifecycle::Error) { @capacity.select(good) }
    assert_empty @capacity.provider.creates
    assert_empty @capacity.state.fetch("reservations")
    @capacity.guardian.healthy = true
    @capacity.now += 5401
    assert_raises(RunpodOllamaFleet::CampaignLifecycle::Error) { @capacity.select(good) }
    assert_empty @capacity.provider.creates
  end

  def test_successful_command_missing_malformed_and_superseded_evidence_cannot_enter_review
    complete_execution
    FileUtils.mv(@assessment_path, "#{@assessment_path}.saved")
    assert_raises(AdventureFinderWorkspace::Error) { prepare_review }
    refute_path_exists @review_dir
    File.binwrite(@assessment_path, "run_id,status\n#{@run_id},PROPOSED\n")
    assert_raises(AdventureFinderWorkspace::Error) { prepare_review }
    refute_path_exists @review_dir
    FileUtils.mv("#{@assessment_path}.saved", @assessment_path)
    # Even an exit-zero current attempt cannot bind artifacts outside its window.
    mutate_json(@request_path) { |row| row["recorded_at"] = "2000-01-01T00:00:00Z" }
    assert_raises(AdventureFinderWorkspace::Error) { prepare_review }
    refute_path_exists @receipt_path
  end

  def test_replacement_generation_archives_real_attempt_and_rejects_superseded_evidence
    @pause_after_first = false
    @exit_code = 7
    @front.run("start", "39")
    assert_equal "circuit_broken", @last_execution
    original = File.binread(@metadata_path)
    @source.document["revision"] += 1
    @source.document["workers"][0]["generation_id"] = "generation-2"
    assert_equal original, File.binread(@metadata_path)
    out, err = StringIO.new, StringIO.new
    args = ["retry-failed", @plan_path, "--workdir", @afw, "--output", @wlo,
      "--job", JOB_ID, "--reason", "reviewed scripted failure", "--acknowledge-circuit-breaker"]
    assert_equal 0, W::CLI.new(args, out: out, err: err).run, err.string
    assert_equal original, File.binread(File.join(@wlo, "attempts", JOB_ID, "attempt-1", "metadata.json"))
    sleep 1.05 # Make the old request unambiguously older than the next attempt.
    @source.document["published_at"] = Time.now.utc.iso8601
    @source.document["expires_at"] = (Time.now.utc + 300).iso8601
    @preserve_artifacts = true
    @exit_code = 0
    @front.run("resume", "39")
    assert_equal "completed", @last_execution
    current = @store.metadata_for(@plan.jobs.first)
    assert_equal 2, current.fetch("attempt")
    assert_equal "generation-2", current.dig("worker_execution_identity", "generation_id")
    assert_equal "generation-1", JSON.parse(original).dig("worker_execution_identity", "generation_id")
    assert_raises(AdventureFinderWorkspace::Error) { prepare_review }
    refute_path_exists @receipt_path
    assert_equal original, File.binread(File.join(@wlo, "attempts", JOB_ID, "attempt-1", "metadata.json"))
  end

  def test_provider_ambiguity_cannot_create_around_pending_reservation
    @front.run("start", "39")
    document = proposal
    @capacity.provider.behavior = :ambiguous
    assert_raises(RunpodOllamaFleet::CampaignLifecycle::Error) { @capacity.select(document) }
    assert_equal 1, @capacity.provider.creates.length
    assert_equal ["pending"], @capacity.state.fetch("reservations").values.map { |row| row.fetch("status") }
    @capacity.lifecycle.reconcile_once(ssh_public_key_path: @capacity.key)
    assert_equal 1, @capacity.provider.creates.length
  end

  def test_selected_drain_remove_preserves_identity_and_refuses_retired_generation
    @front.run("start", "39")
    document = proposal
    @capacity.select(document)
    fleet = @capacity.current_fleet
    original = fleet.fetch("workers").first
    args = original.slice("worker_id", "generation_id", "pod_id").transform_keys(&:to_sym).merge(
      profile_id: Fo24cCapacity::PROFILE, fleet_id: fleet.fetch("fleet_id"), expected_revision: 0, reason: "scripted drain")
    @capacity.lifecycle.select_worker(operation: "drain", **args)
    assert_equal "draining", @capacity.current_fleet.fetch("workers").first.dig("lifecycle", "phase")
    @capacity.lifecycle.set_desired(profile_counts: { Fo24cCapacity::PROFILE => 0 },
      expected_revision: @capacity.desired.current.fetch("revision"), reason: "scripted target zero")
    @capacity.lifecycle.select_worker(operation: "remove", confirm: true, **args.merge(expected_revision: 1))
    @capacity.lifecycle.reconcile_once(ssh_public_key_path: @capacity.key)
    retired = @capacity.current_fleet.fetch("workers").first
    assert_equal "retired", retired.dig("lifecycle", "phase")
    assert_equal original.fetch("generation_id"), retired.fetch("generation_id")
    assert_equal [original.fetch("pod_id")], @capacity.provider.deletes
    assert_raises(RunpodOllamaFleet::CampaignLifecycle::Error) do
      @capacity.lifecycle.select_worker(operation: "drain", **args)
    end
    assert_equal 1, @capacity.provider.creates.length
  end

  def test_tampered_receipt_artifacts_and_ledger_fail_closed_and_decisions_are_preserved
    complete_execution
    canonical = canonical_bytes
    prepare_review
    receipt = File.binread(@receipt_path)
    mutate_json(@receipt_path) { |row| row["workload"]["pool_id"] = "tampered" }
    assert_pipeline_refuses
    File.binwrite(@receipt_path, receipt)
    response = File.binread(@response_path)
    File.open(@response_path, "a") { |file| file.write(" ") }
    assert_pipeline_refuses
    File.binwrite(@response_path, response)
    ledger = File.binread(@ledger_path)
    table = CSV.read(@ledger_path, headers: true)
    table.first["proposed_value"] = "999"
    write_ledger(table)
    tampered = File.binread(@ledger_path)
    assert_raises(AdventureFinderWorkspace::Error) { prepare_review }
    assert_equal tampered, File.binread(@ledger_path)
    %w[ACCEPT HOLD REJECT].each do |decision|
      File.binwrite(@ledger_path, ledger)
      table = CSV.read(@ledger_path, headers: true)
      table.first["editorial_decision"] = decision
      table.first["editorial_note"] = "pre-existing synthetic human decision"
      write_ledger(table)
      previous = File.binread(@ledger_path)
      assert_includes prepare_review, "Pending: 0"
      assert_equal previous, File.binread(@ledger_path)
    end
    assert_equal canonical, canonical_bytes
  end

  private

  def configure_plan_and_context
    @capability = JSON.parse(@capacity.capability.normalized_json).merge("contract_version" => "ollama-capability-request/v0.1")
    model = @capability.dig("ollama", "model")
    mutate_yaml(@case_path) { |row| row["ollama_model"] = model }
    mutate_json(@preflight_path) { |row| row["run_metadata"]["model"] = model }
    mutate_yaml(@case_path) { |row| row["preflight_sha256"] = digest(@preflight_path) }
    table = CSV.read(@case_index_path, headers: true)
    table.first["ollama_model"] = model
    table.first["preflight_sha256"] = digest(@preflight_path)
    write_csv(@case_index_path, table.headers, table.map(&:fields))
    mutate_assessment("model", model)
    mutate_json(@request_path) do |row|
      row["request"]["payload"]["model"] = model
      row["request_sha256"] = Digest::SHA256.hexdigest(JSON.generate(row.fetch("request")))
    end
    mutate_json(@plan_path) do |row|
      row["failure_policy"] = { "max_consecutive_failures" => 1, "max_total_failures" => 1 }
      row["pools"][0]["requirements"]["ollama"] = @capability.fetch("ollama")
      2.times do |index|
        row["jobs"] << { "job_id" => "followup-#{index}", "pool_id" => "qwen", "group_id" => ADVENTURE_ID,
          "argv" => ["scripted-local-only", index.to_s], "depends_on_job_ids" => [index.zero? ? JOB_ID : "followup-0"] }
      end
    end
    mutate_yaml(@snapshot_path) { |row| row["execution_plan_sha256"] = digest(@plan_path) }
    campaign = File.join(@root, "campaign.json")
    budget = File.join(@root, "budget.json")
    FileUtils.cp(File.join(@workspace, "runpod-ollama-fleet/test/fixtures/rpof-capacity-campaign-v0.1.json"), campaign)
    File.write(budget, JSON.generate(@capacity.declaration))
    mutate_yaml(@registry_path) do |row|
      batch = row["contexts"]["batch"]["39"]
      batch["plan"]["sha256"] = digest(@plan_path)
      batch["model_aliases"] = { "qwen" => ["qwen"] }
      batch["worker_sources"] = ["local"]
      batch["local_workers"] = { "repository_root" => "local-ollama-workers" }
      batch["associated_fleets"] = ["A"]
      row["contexts"]["fleet"]["A"] = {
        "campaign_id" => @capacity.campaign.campaign_id, "associated_batches" => ["39"],
        "rpof" => { "repository_root" => "runpod-ollama-fleet", "campaign_path" => "campaign.json",
          "budget_path" => "budget.json", "state_root" => "rpof-state",
          "binding_path" => Pathname(@capacity.binding.state_path).relative_path_from(Pathname(@root)).to_s }
      }
    end
  end

  def bootstrap_local
    runtime = @capability.fetch("ollama")
    identity = { "worker_id" => "release-local", "generation_id" => "generation-1", "endpoint" => "http://127.0.0.1:11441" }
    running = { "model" => runtime.fetch("model"), "digest" => runtime.fetch("expected_digest"),
      "context_length" => runtime.fetch("required_context_length"), "fully_gpu_resident" => true,
      "runtime_size_bytes" => 30000, "runtime_size_vram_bytes" => 30000 }
    observer = Port.new({ observe: -> { identity } })
    client = Port.new({ endpoint: -> { identity.fetch("endpoint") }, version: -> { "scripted" },
      installed_models: -> { [running.slice("model", "digest")] }, running_models: -> { [running] },
      preload!: ->(model:, context_length:) { raise "wrong preload" unless model == running["model"] && context_length == running["context_length"] } })
    store = LocalOllamaWorkers::CapabilityEvidenceStore.new(root: File.join(@root, "low-evidence"))
    request = LocalOllamaWorkers::OllamaCapabilityRequest.new(JSON.generate(@capability))
    LocalOllamaWorkers::CapabilityBootstrapper.new(observer: observer, client: client, evidence_store: store,
      clock: @clock, hardware_probe: Port.new({ gpu_id: -> { runtime.fetch("required_gpu_id") } })).bootstrap(capability_request: request)
    source = LocalOllamaWorkers::LocalWorkerSource.new(observer: observer, client: client, evidence_store: store)
    @publisher = LocalOllamaWorkers::RegistryPublisher.new(state_root: File.join(@root, "low-registry"),
      worker_source: source, clock: @clock, ttl_seconds: 300, id_generator: -> { "fo24c-local" })
    @source.document = @publisher.snapshot
    assert_equal "READY", @source.document.dig("workers", 0, "state")
  end

  def context_registry
    AdventureFinderWorkspace::ProductionContextRegistry.new(@registry_path, workspace_root: @root)
  end

  def cli(*args)
    out, err = StringIO.new, StringIO.new
    status = W::CLI.new(args, out: out, err: err, root: @wlo_root).run
    assert_equal 0, status, err.string
    JSON.parse(out.string)
  end

  def measurements = cli("measurements", @plan_path, "--output", @wlo)

  def diagnostics
    assert_equal "paused", cli("status", @plan_path, "--output", @wlo).fetch("status")
    diagnostics = AdventureFinderWorkspace::Diagnostics.new(registry_path: @registry_path, workspace_root: @root, runner: self)
    assert_equal JOB_ID, diagnostics.call("job", ["39", "0001-combat"]).dig("subject", "id")
    assert_equal JOB_ID, diagnostics.call("job", ["39", "0001-combat"], logs: true, lines: 5).dig("subject", "id")
    assert_equal "campaign", diagnostics.call("campaign", ["A"]).dig("subject", "type")
    assert_equal "execute", cli("action-check", @plan_path, "--workdir", @afw, "--output", @wlo, "--action", "resume", "--json").fetch("disposition")
    assert @capacity.lifecycle.status.fetch("read_only")
  end

  def proposal(wlo: measurements, evidence: nil)
    @capacity.now = Time.now.utc
    evidence ||= (1..3).to_h { |count| [count, @capacity.evidence(count)] }
    before = @capacity.authority
    document = AdventureFinderDeadlineProposals.compose(wlo: wlo, deadline: (Time.now.utc + 60).iso8601,
      baseline_workers: 1, max_workers: 3, as_of: Time.now.utc.iso8601, max_evidence_age_seconds: 30,
      association: @capacity.identity, rpof_evidence: evidence)
    assert_equal before, @capacity.authority
    assert_empty @capacity.provider.creates
    document
  end

  def complete_execution
    @pause_after_first = false
    @front.run("start", "39")
    assert_equal "completed", @last_execution
  end

  class ReviewCommands
    # Carries the fixture-selected root into minimal guarded child environments.
    # A nil root preserves the legacy unset selector; capture errors propagate.
    def initialize(data_root:)
      @data_root = data_root
    end

    def capture(_environment, argv, chdir:)
      executable = File.basename(argv.first)
      raise "unexpected review command" unless %w[afw-bind-scoring-evidence af-data].include?(executable)
      command = [RbConfig.ruby, *argv]
      guard = File.join(ENV.fetch("AF_FO24C_WORKSPACE_ROOT"), "workload-orchestrator/test/acceptance/fo24a/offline_guard.rb")
      env = { "PATH" => File.dirname(RbConfig.ruby), "RUBYOPT" => "-r#{guard}",
              "AF_DATA_PIPELINE_DATA_ROOT" => @data_root }
      out, err, status = Fo24aOfflineGuard.permit(command) do
        Timeout.timeout(20) { Open3.capture3(env, *command, chdir: chdir, unsetenv_others: true) }
      end
      ComponentResult.new(stdout: out, stderr: err, status: status)
    end
  end

  # Runs the real front door with the fixture root and restores ambient ENV,
  # including an unset or empty selector, even when owner validation raises.
  def with_review_data_root(data_root = @data_root)
    previous = ENV["AF_DATA_PIPELINE_DATA_ROOT"]
    ENV["AF_DATA_PIPELINE_DATA_ROOT"] = data_root
    yield
  ensure
    ENV["AF_DATA_PIPELINE_DATA_ROOT"] = previous
  end

  # Verifies selected/unset roots and exact restoration on return and exception.
  # Uses only synthetic selectors; no owner operation runs with these sentinels.
  def assert_review_root_restoration
    previous = ENV["AF_DATA_PIPELINE_DATA_ROOT"]
    [nil, "", "synthetic-ambient-root"].each do |ambient|
      ENV["AF_DATA_PIPELINE_DATA_ROOT"] = ambient
      [@data_root, nil].each do |selected|
        observed = with_review_data_root(selected) { ENV["AF_DATA_PIPELINE_DATA_ROOT"] }
        assert_equal [selected], [observed]
        assert_equal [ambient], [ENV["AF_DATA_PIPELINE_DATA_ROOT"]]
        error = assert_raises(RuntimeError) do
          with_review_data_root(selected) do
            assert_equal [selected], [ENV["AF_DATA_PIPELINE_DATA_ROOT"]]
            raise "synthetic review refusal"
          end
        end
        assert_equal "synthetic review refusal", error.message
        assert_equal [ambient], [ENV["AF_DATA_PIPELINE_DATA_ROOT"]]
      end
    end
  ensure
    ENV["AF_DATA_PIPELINE_DATA_ROOT"] = previous
  end

  def prepare_review
    previous = ENV.to_h
    out = StringIO.new
    front = AdventureFinderWorkspace::ReviewFrontDoor.new(registry_path: @registry_path,
      manifest_path: @manifest_path, workspace_root: @root, out: out,
      component_runner: ReviewCommands.new(data_root: @data_root))
    with_review_data_root do
      assert_equal [@data_root], [ENV["AF_DATA_PIPELINE_DATA_ROOT"]]
      assert_equal 0, front.prepare("39", "0001-combat")
    end
    out.string
  ensure
    assert_equal previous, ENV.to_h
  end

  def assert_pipeline_refuses
    argv = [File.join(@pipeline, "bin/af-data"), "prepare-review", @receipt_path, "--afw-root", @afw,
      "--review-dir", @review_dir, "--audit-dir", @audit_dir]
    result = ReviewCommands.new(data_root: @data_root).capture({}, argv, chdir: @pipeline)
    refute result.status.success?
    assert_match(/mismatch|digest/, result.stderr)
  end

  def install_admission_trace
    @admission_trace = TracePoint.new(:return) do |event|
      if event.self.equal?(@capacity.binding) && event.method_id == :assert_safety_gate! && event.return_value&.fetch("safety_gate", nil) == "PASS"
        @capacity.events << :safety_pass
      elsif event.self.is_a?(RunpodOllamaFleet::CampaignCapacityAdmission)
        @capacity.events << :reserved if event.method_id == :reserve! && event.return_value
        @capacity.events << :committed if event.method_id == :commit! && event.return_value
      end
    end
    @admission_trace.enable
  end

  def teardown_capacity
    stopped = @capacity.lifecycle.stop
    assert_equal "TEARDOWN_REQUIRED", stopped.fetch("budget_state")
    refute stopped.fetch("provider_absence_verified")
    provider = @capacity.provider
    # Guardian owns stop/retry/verified-absence. Its fleet transport only deletes
    # the fake IDs selected by that owner; no real provider client is constructed.
    fake_fleet = Port.new({ destroy: lambda { |worker_indices:, **|
      worker_indices.each do |index|
        pod = provider.list_pods.find { |row| row.fetch("name").end_with?("-#{index}") }
        provider.delete_pod(pod.fetch("id")) if pod
      end
    } })
    guardian = LocalModelEvaluation::RunpodBudgetGuardian.new(root: File.join(@root, "rpof-state"),
      repo_root: File.join(@workspace, "runpod-ollama-fleet"), budget_id: @capacity.declaration.fetch("budget_id"),
      plan_sha256: @capacity.binding.binding_sha256, budget: @capacity.binding.parent_budget,
      provider_client: provider, wall_clock: -> { @capacity.now }, sleeper: ->(*) {},
      fleet_factory: ->(*) { fake_fleet })
    provider.absence_uncertain = true
    assert_raises(LocalModelEvaluation::RunpodBudgetGuardian::Error) { guardian.tick }
    assert_equal "TEARDOWN_REQUIRED", @capacity.state.fetch("state")
    assert_nil @capacity.state["provider_absence_verified_at_utc"]
    provider.absence_uncertain = false
    closed = guardian.tick
    assert_equal "CLOSED", closed.fetch("state")
    assert_equal "verified_provider_absence", closed.fetch("teardown_phase")
    assert_empty provider.list_pods
  end
end

# Fixture parent tests are exercised separately; this entry point selects only
# the connected release flow and its falsification cases.
ARGV.concat(["--name", "/Fo24cRelease#/"])
Minitest.after_run { Fo24aOfflineGuard.assert_clean! }
