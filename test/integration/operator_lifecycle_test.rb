# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "stringio"
require "tmpdir"
require "time"

require "adventure_finder_production_context"

if ENV["AF_OPERATOR_ACCEPTANCE_OFFLINE"] == "1"
WLO_ROOT = File.expand_path(ENV.fetch("WLO_REPO_ROOT"))
RPOF_ROOT = File.expand_path(ENV.fetch("RPOF_REPO_ROOT"))
$LOAD_PATH.unshift(File.join(WLO_ROOT, "lib"))
$LOAD_PATH.unshift(File.join(RPOF_ROOT, "lib"))
require "workload_orchestrator"
require "runpod_ollama_fleet"
require "runpod_ollama_fleet/dynamic_worker_registry"
require "local_model_evaluation/runpod_budget_guardian"

class OperatorLifecycleTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  REGISTRY_PATH = File.join(ROOT, "config", "production_contexts.yml")
  CAMPAIGN_PATH = File.join(RPOF_ROOT, "test", "fixtures", "rpof-capacity-campaign-v0.1.json")
  BUDGET_PATH = File.join(RPOF_ROOT, "test", "fixtures", "rpof-capacity-campaign-budget-v0.1.json")
  HARDWARE_PATH = File.join(RPOF_ROOT, "config", "execution_pool_hardware.yml")
  REGISTRY_START = Time.iso8601("2030-01-01T00:00:00Z")

  CommandStatus = Struct.new(:exitstatus) do
    def success? = exitstatus.zero?
  end

  Namespace = Struct.new(:fleet_key, :env_path, :state_root, :local_port_base, keyword_init: true)

  class GuardianSupervisor
    def initialize(clock)
      @clock = clock
      @armed = false
    end

    def arm!(budget:, request:)
      @armed = true
      budget.arm!(budget: request, guardian_heartbeat_at_utc: @clock.call)
    end

    def status(budget:)
      {
        "enabled" => true,
        "launchd_loaded" => true,
        "ready" => true,
        "pid" => Process.pid + 1,
        "provider_probe_at_utc" => @clock.call.iso8601,
        "ledger_heartbeat_at_utc" => @clock.call.iso8601,
        "state" => (@armed ? budget.status.fetch("state") : "WAITING_FOR_ARM"),
        "last_error" => nil
      }
    end
  end

  class FakeProvider
    attr_accessor :list_error
    attr_reader :create_calls

    def initialize
      @pods = {}
      @create_calls = 0
    end

    def create(profile_id, index)
      @create_calls += 1
      id = "fake-#{profile_id}-pod-#{index}"
      @pods[id] = { "id" => id, "name" => "af-lme-#{profile_id}-burst-#{index}" }
      @pods.fetch(id)
    end

    def list_pods
      raise list_error if list_error

      Marshal.load(Marshal.dump(@pods.values))
    end

    def get_pod(id)
      @pods.fetch(id) { raise LocalModelEvaluation::RunpodClient::Error.new(404, "missing") }
    end

    def delete(id)
      @pods.delete(id)
    end
  end

  class CampaignRuntime
    attr_reader :profile

    def initialize(profile, hardware, admission, provider)
      @profile = profile
      @hardware = hardware
      @admission = admission
      @provider = provider
      @count = 0
    end

    def admission=(value)
      @admission = value if value
    end

    def current_worker_count = @count

    def ensure_workers!(desired_workers:, **)
      ((@count + 1)..desired_workers).each do |index|
        handle = @admission.reserve!(
          operation_type: @count.zero? ? "create" : "scale_up",
          logical_resource_id: "burst_#{index}",
          max_hourly_rate_delta_usd: 0.5,
          gpu_id: @hardware.fetch("qualified_gpu_ids").first,
          cloud: @hardware.fetch("cloud")
        )
        pod = @admission.attempt_provider_create!(handle) do
          @provider.create(profile.fetch("profile_id"), index)
        end
        @admission.commit!(
          handle,
          provider_resource_id: pod.fetch("id"),
          actual_hourly_rate_usd: 0.5
        )
        @count += 1
      end
    end

    def status
      {
        "current_workers" => @count,
        "ready_workers" => @count,
        "fleet_id" => (@count.positive? ? "fake-#{profile.fetch('profile_id')}-fleet" : nil),
        "fleet_status" => (@count.positive? ? "active" : nil),
        "worker_readiness" => (@count.positive? ? { "active" => @count } : {})
      }
    end
  end

  class FleetState
    attr_accessor :fleet

    def initialize(root)
      @root = root
      @fleet = nil
    end

    def current
      fleet && Marshal.load(Marshal.dump(fleet))
    end

    def artifact_dir(fleet_id, name)
      File.join(@root, fleet_id, name)
    end

    def registry_identity(index:, observed_pod_id:)
      worker = fleet.fetch("workers").find { |row| row.fetch("index") == index }
      raise "publisher observed the wrong provider pod" unless worker.fetch("pod_id") == observed_pod_id

      slug = fleet.fetch("fleet_id")
      { "worker_id" => "#{slug}-worker-#{index}", "generation_id" => "#{slug}-generation-1" }
    end
  end

  class FakeProcess
    def alive?(_pid) = true
    def matches?(_pid, _identity) = true
  end

  class FakeHealth
    Result = Struct.new(:healthy, :version, :detail, keyword_init: true)

    def check(_endpoint)
      Result.new(healthy: true, version: "operator-lifecycle", detail: nil)
    end
  end

  class PublishingSource < WorkloadOrchestrator::WorkerSource
    attr_reader :snapshots

    def initialize(publisher)
      @publisher = publisher
      @snapshots = []
    end

    def latest_snapshot
      snapshot = @publisher.snapshot
      @snapshots << snapshot
      "#{JSON.generate(snapshot)}\n"
    end
  end

  class FakeFleet
    def initialize(provider, profile_id)
      @provider = provider
      @profile_id = profile_id
    end

    def destroy(worker_indices:, **)
      worker_indices.each do |index|
        name = "af-lme-#{@profile_id}-burst-#{index}"
        pod = @provider.list_pods.find { |row| row.fetch("name") == name }
        @provider.delete(pod.fetch("id")) if pod
      end
      worker_indices
    end
  end

  def setup
    @tmp = Dir.mktmpdir("af-operator-lifecycle-")
    @workdir = File.join(@tmp, "work")
    @output = File.join(@tmp, "wlo-output")
    FileUtils.mkdir_p(@workdir)
    @now = Time.utc(2026, 9, 29, 12, 0, 0)
    @registry_now = REGISTRY_START
    @provider = FakeProvider.new
    @runtimes = {}
    @states = {
      "qwen35" => FleetState.new(File.join(@tmp, "fleets", "qwen35")),
      "gemma" => FleetState.new(File.join(@tmp, "fleets", "gemma"))
    }
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_offline_operator_lifecycle_from_context_to_verified_teardown
    phase("portable context") { assert_portable_context }
    lifecycle, binding = phase("campaign construction") { build_campaign_lifecycle }
    plan = phase("WLO plan") { build_plan }
    source = phase("RPOF publisher") { build_source }
    observed = []
    observed_mutex = Mutex.new
    executor = lambda do |environment, *argv, chdir:|
      job_id = argv.last
      metadata = JSON.parse(File.read(File.join(@output, "runs", job_id, "metadata.json")))
      observed_mutex.synchronize do
        observed << { "job_id" => job_id, "environment" => environment.dup, "chdir" => chdir,
                      "metadata" => metadata }
      end
      ["fake result #{job_id}\n", "", CommandStatus.new(0)]
    end

    runner = nil
    waits = 0
    sleeper = lambda do |*_arguments|
      waits += 1
      case waits
      when 1
        phase("WLO waiting") do
          assert_equal "running", runner.store.status
          assert_equal({ "pending" => 2 }, runner.store.counts)
          assert_empty observed
          assert_empty runner.worker_registry_poller.ready_workers
        end
        phase("campaign start") do
          started = lifecycle.start(authorize_paid: true, ssh_public_key_path: "fake-unused.pub")
          assert_equal "ARMED", started.fetch("budget_state")
          assert_equal 6, started.fetch("active_workers")
          assert_equal 6, @provider.create_calls
          publish_fleets(bootstrap_status: "running")
        end
      when 2
        phase("NOT_READY publication") do
          checkpoint = runner.worker_registry_poller.accepted_checkpoint
          assert_equal 2, checkpoint.fetch("revision")
          assert_equal %w[NOT_READY NOT_READY],
                       checkpoint.fetch("workers").map { |row| row.dig("worker_snapshot", "state") }.sort
          assert_empty runner.worker_registry_poller.ready_workers
          assert_empty observed
          publish_fleets(bootstrap_status: "passed")
        end
      end
    end
    runner = WorkloadOrchestrator::Runner.new(
      plan:,
      workers: WorkloadOrchestrator::WorkerSet.new({}),
      workdir: @workdir,
      output_dir: @output,
      out: StringIO.new,
      worker_source: source,
      worker_registry_clock: -> { @registry_now + 1 },
      worker_registry_sleeper: sleeper,
      worker_poll_interval: 0.001,
      command_executor: executor
    )

    phase("WLO completion") do
      assert_equal "completed", runner.run
      assert_equal({ "complete" => 2 }, runner.store.counts)
      assert_equal 2, observed.length
      assert_equal %w[http://127.0.0.1:11441 http://127.0.0.1:11442],
                   observed.map { |row| row.dig("environment", "AF_OLLAMA_BASE_URL") }.sort
      observed.each do |row|
        metadata = row.fetch("metadata")
        assert_equal @workdir, row.fetch("chdir")
        assert_equal "running", metadata.fetch("status")
        assert_equal 1, metadata.fetch("attempt")
        assert_equal 3, metadata.dig("worker_registry_binding", "registry_revision")
        assert_equal metadata.dig("worker_execution_identity", "endpoint"),
                     row.dig("environment", "AF_OLLAMA_BASE_URL")
        refute metadata.key?("remote_request")
        refute metadata.key?("provider_job_id")
        refute Dir.exist?(File.join(@output, "runs", row.fetch("job_id"), "provider-attempt-1"))
      end
      assert_equal [1, 2, 3], source.snapshots.map { |snapshot| snapshot.fetch("revision") }.uniq.first(3)
    end

    wlo_evidence = evidence_sha256(@output)
    phase("read-only observers") do
      campaign_before = Digest::SHA256.file(binding.parent_budget.state_path).hexdigest
      report = WorkloadOrchestrator::ExecutionReport.new(plan:, output: @output).document
      status = lifecycle.status
      assert_equal "completed", report.fetch("status")
      assert status.fetch("read_only")
      assert_equal "ARMED", status.fetch("budget_state")
      assert_equal wlo_evidence, evidence_sha256(@output)
      assert_equal campaign_before, Digest::SHA256.file(binding.parent_budget.state_path).hexdigest
    end

    phase("teardown requested") do
      stopped = lifecycle.stop
      assert_equal "TEARDOWN_REQUIRED", stopped.fetch("budget_state")
      refute stopped.fetch("provider_absence_verified")
      assert_equal wlo_evidence, evidence_sha256(@output)
    end

    guardian = build_budget_guardian(binding)
    phase("teardown retry") do
      @provider.list_error = LocalModelEvaluation::RunpodClient::Error.new(503, "offline fixture outage")
      assert_raises(LocalModelEvaluation::RunpodBudgetGuardian::Error) { guardian.tick }
      retained = binding.parent_budget.status
      assert_equal "TEARDOWN_REQUIRED", retained.fetch("state")
      assert_equal "in_progress", retained.fetch("teardown_phase")
      assert_nil retained["provider_absence_verified_at_utc"]
      assert_equal 1, retained.fetch("teardown_failures").length
    ensure
      @provider.list_error = nil
    end

    phase("verified close") do
      closed = guardian.tick
      assert_equal "CLOSED", closed.fetch("state")
      assert_equal "verified_provider_absence", closed.fetch("teardown_phase")
      refute_nil closed.fetch("provider_absence_verified_at_utc")
      assert_empty @provider.list_pods
      assert_equal "CLOSED", lifecycle.status.fetch("budget_state")
      assert_equal wlo_evidence, evidence_sha256(@output)
    end
  end

  private

  def phase(name)
    yield
  rescue Minitest::Assertion, StandardError => e
    raise e.class, "operator-lifecycle phase #{name}: #{e.message}", e.backtrace
  end

  def assert_portable_context
    previous = ENV["AF_PROJECT_ROOT"]
    ENV["AF_PROJECT_ROOT"] = @tmp
    registry = AdventureFinderWorkspace::ProductionContextRegistry.new(
      REGISTRY_PATH,
      workspace_root: ENV.fetch("AF_PROJECT_ROOT")
    )
    batch = registry.resolve("batch", "39")
    fleet = registry.resolve("fleet", "A")
    assert batch.dig("afw", "plan_path").start_with?("#{@tmp}/")
    assert fleet.dig("rpof", "campaign_path").start_with?("#{@tmp}/")
    assert_equal ["A"], batch.fetch("associated_fleets")
    assert_equal ["39"], fleet.fetch("associated_batches")
  ensure
    previous.nil? ? ENV.delete("AF_PROJECT_ROOT") : ENV["AF_PROJECT_ROOT"] = previous
  end

  def build_campaign_lifecycle
    hardware = RunpodOllamaFleet::ExecutionPoolHardware.new(path: HARDWARE_PATH)
    campaign = RunpodOllamaFleet::CapacityCampaign.load(path: CAMPAIGN_PATH, hardware:)
    binding = RunpodOllamaFleet::CampaignBudgetBinding.new(
      root: File.join(@tmp, "rpof-state"),
      repo_root: RPOF_ROOT,
      campaign:,
      declaration: JSON.parse(File.binread(BUDGET_PATH)),
      wall_clock: -> { @now },
      guardian_supervisor: GuardianSupervisor.new(-> { @now })
    )
    factory = lambda do |profile, profile_hardware, admission|
      id = profile.fetch("profile_id")
      runtime = (@runtimes[id] ||= CampaignRuntime.new(profile, profile_hardware, admission, @provider))
      runtime.admission = admission
      runtime
    end
    lifecycle = RunpodOllamaFleet::CampaignLifecycle.new(
      campaign:,
      binding:,
      runtime_factory: factory,
      price_resolver: ->(*) { 0.5 },
      wall_clock: -> { @now }
    )
    [lifecycle, binding]
  end

  def build_plan
    profiles = JSON.parse(File.binread(CAMPAIGN_PATH)).fetch("profiles")
    selected = profiles.select { |row| %w[qwen35 gemma].include?(row.fetch("profile_id")) }
    WorkloadOrchestrator::Plan.new(JSON.generate(
      "contract_version" => WorkloadOrchestrator::Plan::PRIORITY_CONTRACT_VERSION,
      "plan_id" => "fo03-operator-lifecycle",
      "failure_policy" => { "max_consecutive_failures" => 2, "max_total_failures" => 2 },
      "pools" => selected.map do |profile|
        {
          "pool_id" => profile.fetch("profile_id"),
          "required_labels" => ["inference"],
          "requirements" => {
            "ollama" => {
              "model" => profile.fetch("model"),
              "expected_digest" => profile.fetch("expected_digest"),
              "required_context_length" => profile.fetch("required_context_length"),
              "require_fully_gpu_resident" => true
            }
          }
        }
      end,
      "jobs" => selected.map do |profile|
        id = "score-#{profile.fetch('profile_id')}"
        { "job_id" => id, "pool_id" => profile.fetch("profile_id"), "argv" => ["fake-scorer", id] }
      end
    ))
  end

  def build_source
    publisher = RunpodOllamaFleet::DynamicWorkerRegistry.new(
      state_root: File.join(@tmp, "publisher"),
      repo_root: RPOF_ROOT,
      clock: -> { @registry_now },
      ttl_seconds: 300,
      process_adapter: FakeProcess.new,
      health_checker: FakeHealth.new,
      fleet_sources: @states.map { |key, state| { "fleet_key" => key, "state" => state } },
      id_generator: -> { "fo03-operator-lifecycle" }
    )
    PublishingSource.new(publisher)
  end

  def publish_fleets(bootstrap_status:)
    definitions = {
      "qwen35" => ["qwen3.6:35b-a3b", "a" * 64, "NVIDIA A40", 11_441],
      "gemma" => ["gemma4:26b", "c" * 64, "NVIDIA L40S", 11_442]
    }
    @registry_now += 10
    definitions.each do |profile_id, (model, digest, gpu, port)|
      state = @states.fetch(profile_id)
      state.fleet ||= fleet_document(profile_id, model, gpu, port)
      write_worker_evidence(state, model:, digest:, gpu:, port:, bootstrap_status:)
    end
  end

  def fleet_document(profile_id, model, gpu, port)
    {
      "fleet_id" => "fake-#{profile_id}-fleet",
      "status" => "active",
      "created_at_utc" => "2029-12-31T23:59:00Z",
      "gpu" => { "id" => gpu },
      "workers" => [{
        "index" => 1,
        "name" => "#{profile_id}-worker",
        "pod_id" => "fake-#{profile_id}-pod-1",
        "generation" => 1,
        "created_at_utc" => "2029-12-31T23:59:00Z",
        "status" => "active",
        "gpu_id" => gpu,
        "local_ollama_url" => "http://127.0.0.1:#{port}",
        "model" => model
      }]
    }
  end

  def write_worker_evidence(state, model:, digest:, gpu:, port:, bootstrap_status:)
    fleet = state.fleet
    worker = fleet.fetch("workers").fetch(0)
    run_id = "operator-lifecycle-bootstrap"
    bootstrap_root = state.artifact_dir(fleet.fetch("fleet_id"), "bootstrap")
    FileUtils.mkdir_p(File.join(bootstrap_root, run_id))
    File.write(File.join(bootstrap_root, "current"), "#{run_id}\n")
    File.write(File.join(bootstrap_root, run_id, "bootstrap.json"), JSON.pretty_generate(
      "schema_version" => 2,
      "bootstrap_run_id" => run_id,
      "fleet_id" => fleet.fetch("fleet_id"),
      "status" => bootstrap_status,
      "models" => [model],
      "expected_digests" => { model => digest },
      "context" => 131_072,
      "workers" => [{
        "index" => 1,
        "pod_id" => worker.fetch("pod_id"),
        # Capability evidence is already complete while the aggregate bootstrap
        # remains in progress, so RPOF can publish the worker as NOT_READY rather
        # than omitting it.
        "status" => "passed",
        "provenance_error" => nil,
        "provenance" => {
          "gpu" => { "name" => gpu },
          "models" => {
            model => {
              "digest" => digest,
              "context_length" => 131_072,
              "size_bytes" => 20_000,
              "size_vram_bytes" => 20_000,
              "fully_gpu_resident" => true
            }
          }
        }
      }]
    ) + "\n")
    tunnel_root = state.artifact_dir(fleet.fetch("fleet_id"), "tunnels")
    FileUtils.mkdir_p(tunnel_root)
    File.write(File.join(tunnel_root, "tunnels.json"), JSON.pretty_generate(
      "fleet_id" => fleet.fetch("fleet_id"),
      "workers" => [{
        "index" => 1,
        "pod_id" => worker.fetch("pod_id"),
        "pid" => 12_345,
        "endpoint" => "http://127.0.0.1:#{port}",
        "process_identity" => { "forward" => "fixture", "ssh_port" => 22_001,
                                "target" => "root@fixture" }
      }]
    ) + "\n")
  end

  def build_budget_guardian(binding)
    LocalModelEvaluation::RunpodBudgetGuardian.new(
      root: File.join(@tmp, "rpof-state"),
      repo_root: RPOF_ROOT,
      budget_id: binding.declaration.fetch("budget_id"),
      plan_sha256: binding.binding_sha256,
      budget: binding.parent_budget,
      provider_client: @provider,
      namespace_factory: lambda do |profile_id|
        Namespace.new(fleet_key: profile_id, env_path: File.join(@tmp, "#{profile_id}.env"),
                      state_root: @tmp, local_port_base: 11_400)
      end,
      fleet_factory: ->(namespace) { FakeFleet.new(@provider, namespace.fleet_key) },
      sleeper: ->(_seconds) {},
      wall_clock: -> { @now }
    )
  end

  def evidence_sha256(root)
    paths = Dir[File.join(root, "**", "*")].select { |path| File.file?(path) }.sort
    Digest::SHA256.hexdigest(paths.map do |path|
      "#{path.delete_prefix("#{root}/")}\0#{File.binread(path)}"
    end.join("\0"))
  end
end
else
  class OperatorLifecycleTest < Minitest::Test
    def test_offline_operator_lifecycle_from_context_to_verified_teardown
      skip "run through bin/af-operator-acceptance"
    end
  end
end
