# frozen_string_literal: true

# Separate process: real RPOF campaign, supervisor, budget, lifecycle and FO-11
# identity/state. Only OS supervision, guardian and worker runtime are fakes.
require "json"
require "tmpdir"
require "fileutils"
require "runpod_ollama_fleet"
require "runpod_ollama_fleet/worker_bringup_identity"
require "runpod_ollama_fleet/worker_bringup_state"
require "runpod_ollama_fleet/worker_bringup_reconciler"

module OfflineComposition
  NOW = Time.utc(2030, 1, 1)
  class Hardware
    def profile_for(model)
      RunpodOllamaFleet::ExecutionPoolHardware::Profile.new(
        model:, cloud: "SECURE", gpu_ids: ["NVIDIA A40", "NVIDIA L40S"],
        shared_model: "shared/#{model}", global_volume_id: "fixture-volume", ollama_store_path: "/models"
      )
    end
  end

  class Guardian
    def arm!(budget:, request:)
      budget.arm!(budget: request, guardian_heartbeat_at_utc: NOW)
    end
    def status(budget:)
      {
        "budget_id" => budget.budget_id, "plan_sha256" => budget.plan_sha256,
        "enabled" => true, "launchd_loaded" => true, "ready" => true, "pid" => Process.pid + 1,
        "provider_probe_at_utc" => NOW.iso8601, "ledger_heartbeat_at_utc" => NOW.iso8601,
        "state" => budget.status.fetch("state"), "last_error" => nil
      }
    end
  end

  class ProcessInspector
    def same_process?(_identity) = false
  end

  class Runtime
    def initialize(&reconcile) = @reconcile = reconcile
    def current_worker_count = 1
    def ensure_workers!(**) = raise("unexpected replacement or scale-up")
    def reconcile_bringup!(desired_workers:, transition_guard:)
      raise "desired changed" unless desired_workers == 1
      transition_guard.call
      [@reconcile.call]
    end
    def status = { "current_workers" => 1, "ready_workers" => 1, "fleet_id" => "fixture-fleet", "fleet_status" => "active", "worker_readiness" => { "active" => 1 } }
  end

  class Stage
    attr_reader :calls
    def initialize(requirement)
      @requirement = requirement
      @calls = 0
    end
    def inspect(identity:, **)
      @result
    end
    def ensure!(identity:) = perform(identity)
    def verify!(identity:) = perform(identity)
    def start!(identity:, attempt:)
      perform(identity).merge!("attempt_id" => attempt.fetch("attempt_id"))
    end
    def perform(identity)
      @calls += 1
      @result = {
        "identity_sha256" => Digest::SHA256.hexdigest(JSON.generate(identity)), "status" => "passed",
        "evidence" => identity.slice("worker_id", "generation_id", "provider_resource_id").merge(
          "observed_at_utc" => NOW.iso8601,
          "endpoint" => identity.dig("tunnel_target", "ollama_endpoint"),
          "model" => @requirement.fetch("model"), "digest" => @requirement.fetch("expected_digest"),
          "context_length" => @requirement.fetch("required_context_length"),
          "fully_gpu_resident" => @requirement.fetch("require_fully_gpu_resident"),
          "gpu_id" => @requirement.fetch("required_gpu_id", "NVIDIA A40")
        )
      }
    end
  end

  def self.profile(request)
    request.document.fetch("ollama").reject { |k, _| k == "required_gpu_id" }.merge(
      "profile_id" => "profile-1", "min_workers" => 1, "desired_workers" => 1, "max_workers" => 1
    )
  end

  def self.campaign_document(profile)
    {
      "contract_version" => "rpof-capacity-campaign/v0.1", "campaign_id" => "fixture-campaign",
      "max_workers" => 1, "max_hourly_rate_usd" => 1.0, "profiles" => [profile]
    }
  end

  def self.worker(request)
    {
      "index" => 1, "generation" => 1, "pod_id" => "resource-1", "worker_id" => "worker-1",
      "generation_id" => "generation-1", "host" => "198.51.100.1", "ssh_port" => 22_001,
      "local_ollama_url" => "http://127.0.0.1:11441",
      "gpu_id" => request.document.fetch("ollama").fetch("required_gpu_id", "NVIDIA A40")
    }
  end

  def self.identity(request, campaign_sha)
    worker = worker(request)
    RunpodOllamaFleet::WorkerBringupIdentity.new(
      campaign_identity_sha256: campaign_sha, profile: profile(request), worker:,
      generation_id: worker.fetch("generation_id"), capability_request: request
    )
  end

  def self.files(root)
    Dir.glob("#{root}/**/*", File::FNM_DOTMATCH).select { |p| File.file?(p) }.to_h { |p| [p, File.binread(p)] }
  end
end

identities_only = ARGV.delete("--identities")
requests = ARGV.map { |path| RunpodOllamaFleet::OllamaCapabilityRequest.load(path) }
results = []
Dir.mktmpdir("rpof-composition-") do |root|
  campaign = nil
  binding = nil
  runner = nil
  authority_before = nil
  loaded = false
  launches = 0
  stages = nil
  reconciler = nil
  request_path = File.join(root, "capability.json")
  requests.each_with_index do |request, index|
    path = ARGV.fetch(index)
    bytes = File.binread(path)
    profile = OfflineComposition.profile(request)
    document = OfflineComposition.campaign_document(profile)
    campaign_result = "accepted"
    begin
      current_campaign = RunpodOllamaFleet::CapacityCampaign.new(JSON.generate(document), hardware: OfflineComposition::Hardware.new)
    rescue RunpodOllamaFleet::CapacityCampaign::Error => e
      raise unless request.document.dig("ollama", "require_fully_gpu_resident") == false && e.message.include?("must be true")
      campaign_result = "unsupported_false_residency"
    end
    # Hold all provider/generation inputs constant even for runtime variants.
    bringup = OfflineComposition.identity(request, identities_only ? "c" * 64 : current_campaign.identity_sha256)
    result = {
      "fingerprint" => request.fingerprint, "artifact_sha256" => Digest::SHA256.hexdigest(bytes),
      "bringup_identity" => bringup.sha256, "generation_id" => "generation-1", "campaign_result" => campaign_result
    }
    unless identities_only
      if index.zero?
        campaign = current_campaign
        declaration = {
          "contract_version" => "rpof-capacity-campaign-budget/v0.1",
          "campaign_identity" => campaign.identity, "campaign_identity_sha256" => campaign.identity_sha256,
          "budget_id" => "fixture-budget", "max_cumulative_compute_usd" => 30.0,
          "max_aggregate_hourly_rate_usd" => campaign.max_hourly_rate_usd, "max_workers" => campaign.max_workers,
          "max_runtime_seconds" => 5400.0, "guardian_poll_seconds" => 5.0,
          "orchestrator_heartbeat_timeout_seconds" => 30.0, "teardown_reserve_seconds" => 120.0
        }
        binding = RunpodOllamaFleet::CampaignBudgetBinding.new(
          root:, repo_root: Dir.pwd, campaign:, declaration:,
          wall_clock: -> { OfflineComposition::NOW }, guardian_supervisor: OfflineComposition::Guardian.new
        )
        binding.arm!
        # Seed one existing worker through real authority accounting and a fake
        # provider result. Subsequent reconciliation must never create capacity.
        admission = RunpodOllamaFleet::CampaignCapacityAdmission.new(binding:, profile_id: "profile-1")
        handle = admission.reserve!(
          operation_type: "create", logical_resource_id: "burst_1", max_hourly_rate_delta_usd: 0.5,
          gpu_id: "NVIDIA A40", cloud: "SECURE", reservation_id: "fixture-reservation"
        )
        admission.attempt_provider_create!(handle) { "resource-1" }
        admission.commit!(handle, provider_resource_id: "resource-1", actual_hourly_rate_usd: 0.5)
        authority_before = [binding.state_path, binding.parent_budget.state_path].to_h { |p| [p, File.binread(p)] }
        { "campaign.json" => document, "budget.json" => declaration, "hardware.json" => campaign.hardware_bindings }.each do |name, value|
          File.write(File.join(root, name), JSON.generate(value))
        end
      end
      raise "provider campaign changed" unless campaign.identity_sha256 == current_campaign.identity_sha256
      File.binwrite(request_path, bytes)
      controller_root = File.join(File.dirname(binding.state_path), "controller")
      runner = lambda do |argv|
        case argv[1]
        when "print" then ["", "", loaded ? 0 : 1]
        when "bootstrap" then loaded = true; ["", "", 0]
        when "kickstart"
          launches += 1
          retained = JSON.parse(File.binread(File.join(controller_root, "request.json")))
          File.write(File.join(controller_root, "runtime.json"), JSON.generate(
            "contract_version" => RunpodOllamaFleet::CampaignController::CONTRACT_VERSION,
            "campaign_identity_sha256" => campaign.identity_sha256, "binding_sha256" => binding.binding_sha256,
            "budget_id" => "fixture-budget", "generation_id" => retained.fetch("generation_id"),
            "pid" => Process.pid + 1, "state" => "RUNNING", "started_at_utc" => OfflineComposition::NOW.iso8601,
            "last_heartbeat_at_utc" => OfflineComposition::NOW.iso8601,
            "last_reconciliation_at_utc" => OfflineComposition::NOW.iso8601, "last_action" => "none", "last_error" => nil
          ))
          ["", "", 0]
        else raise "unexpected OS operation: #{argv.inspect}"
        end
      end
      supervisor = RunpodOllamaFleet::CampaignControllerSupervisor.new(
        root:, repo_root: Dir.pwd, campaign_path: File.join(root, "campaign.json"),
        budget_path: File.join(root, "budget.json"), hardware_path: File.join(root, "hardware.json"),
        capability_request_paths: { "profile-1" => request_path }, command_runner: runner,
        sleeper: ->(*) {}, monotonic_clock: -> { 0 }, wall_clock: -> { OfflineComposition::NOW }, platform: "arm64-darwin"
      )
      supervisor.validate_requirements!(binding:)
      controller = supervisor.ensure_running!(binding:, ssh_public_key_path: "unused.pub", heartbeat_timeout_seconds: 30)
      result["generation_id"] = controller.fetch("generation_id")
      store = RunpodOllamaFleet::WorkerBringupState.new(root:)
      stages ||= Array.new(3) { OfflineComposition::Stage.new(request.document.fetch("ollama")) }
      reconciler ||= RunpodOllamaFleet::WorkerBringupReconciler.new(
        root:, tunnel: stages[0], bootstrap: stages[1], capability: stages[2],
        process_inspector: OfflineComposition::ProcessInspector.new,
        clock: -> { OfflineComposition::NOW }
      )
      reconcile = lambda do
        reconciler.reconcile!(
          campaign_identity_sha256: campaign.identity_sha256, profile:,
          worker: OfflineComposition.worker(request), generation_id: "generation-1", capability_request: request
        )
      end
      reconciled = reconcile.call
      raise "bringup not ready" unless reconciled.fetch("readiness_prerequisites_satisfied")
      before_read = OfflineComposition.files(File.join(root, "worker-bringup-v0.1"))
      state = store.read_current(worker_id: "worker-1")
      raise "state read rewrote evidence" unless before_read == OfflineComposition.files(File.join(root, "worker-bringup-v0.1"))
      raise "wrong retained format" unless state.dig("model_requirement", "contract_version") == "ollama-capability-request/v0.1"
      runtime = OfflineComposition::Runtime.new(&reconcile)
      lifecycle = RunpodOllamaFleet::CampaignLifecycle.new(
        campaign:, binding:, runtime_factory: ->(*) { runtime },
        wall_clock: -> { OfflineComposition::NOW }, price_resolver: ->(*) { 0.5 }
      )
      lifecycle.reconcile_once(ssh_public_key_path: "unused.pub")
      raise "bringup restarted for equivalent request" unless stages.all? { |stage| stage.calls == 1 }
      raise "authority rewritten or widened" unless authority_before.all? { |p, b| File.binread(p) == b }
      result.merge!("authority_unchanged" => true, "no_replacement" => true, "controller_launches" => launches)
    end
    raise "artifact changed" unless File.binread(path) == bytes
    results << result
  end
  unless identities_only
    # Temporary historical fixtures: keep the real finite authority and model
    # evidence, but record the original FO-10/FO-11 contract envelopes explicitly.
    legacy_document = {
      "contract_version" => "adventurefinder-model-requirement/v0.1",
      "batch_handle" => "39", "production_batch_id" => "production-batch-039",
      "plan_id" => "retained-plan", "plan_sha256" => "e" * 64,
      "alias" => "retained-alias", "pool_id" => "retained-pool", "required_labels" => ["inference"],
      "ollama" => requests.first.document.fetch("ollama")
    }
    legacy_path = File.join(root, "retained-requirement.json")
    File.write(legacy_path, JSON.pretty_generate(legacy_document) + "\n")
    legacy = RunpodOllamaFleet::ModelRequirement.load(legacy_path)
    controller_root = File.join(File.dirname(binding.state_path), "controller")
    controller_path = File.join(controller_root, "request.json")
    retained = JSON.parse(File.binread(controller_path))
    retained["contract_version"] = RunpodOllamaFleet::CampaignControllerSupervisor::LEGACY_REQUEST_CONTRACT_VERSION
    retained.delete("capability_requests")
    retained["model_requirements"] = [{
      "profile_id" => "profile-1", "path" => legacy_path,
      "artifact_sha256" => Digest::SHA256.file(legacy_path).hexdigest, "requirement_sha256" => legacy.fingerprint
    }]
    File.write(controller_path, JSON.pretty_generate(retained) + "\n")
    worker = OfflineComposition.worker(requests.first).merge("worker_id" => "retained-worker")
    legacy_identity = RunpodOllamaFleet::WorkerBringupIdentity.new(
      campaign_identity_sha256: campaign.identity_sha256, profile: campaign.profiles.first,
      worker:, generation_id: worker.fetch("generation_id"), capability_request: legacy
    )
    store = RunpodOllamaFleet::WorkerBringupState.new(root:)
    store.with_current(legacy_identity) { |_state, _checkpoint| }
    before = OfflineComposition.files(root)
    historical = RunpodOllamaFleet::CampaignControllerSupervisor.new(
      root:, repo_root: Dir.pwd, campaign_path: File.join(root, "campaign.json"),
      budget_path: File.join(root, "budget.json"), hardware_path: File.join(root, "hardware.json"),
      capability_request_paths: {}, command_runner: runner,
      wall_clock: -> { OfflineComposition::NOW }, platform: "arm64-darwin"
    )
    loaded_legacy = historical.resolved_capability_requests(binding:).fetch("profile-1")
    raise "historical format lost" unless loaded_legacy.document == legacy.document
    state = store.read_current(worker_id: "retained-worker")
    raise "historical evidence migrated" unless state.fetch("model_requirement") == legacy.document
    historical.status(binding:)
    binding.status
    raise "historical read rewrote state or authority" unless before == OfflineComposition.files(root)
    results.last["historical_read_unchanged"] = true
  end
end
raise "provider isolation violated" if $LOADED_FEATURES.any? { |p| p.match?(%r{/lib/(?:workload_orchestrator|local_ollama_workers|adventure_finder)}) }
puts JSON.generate(results)
