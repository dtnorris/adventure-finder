# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "../../lib/adventure_finder_deadline_proposals"

# Opt-in cross-owner proof; all retained state lives in a temporary directory.
# No production adapter or new authority document is introduced.
class Fo21dDeadlineAdmissionTest < Minitest::Test
  A40 = "NVIDIA A40"
  BLACKWELL = "NVIDIA RTX PRO 6000 Blackwell Server Edition"
  PROFILE = "qwen35"
  class SelectionError < StandardError; end

  class Guardian
    attr_accessor :healthy, :missing
    def initialize(clock)
      @clock = clock
      @healthy = true
    end

    def arm!(budget:, request:)
      budget.arm!(budget: request, guardian_heartbeat_at_utc: @clock.call)
    end

    def status(budget:)
      raise LocalModelEvaluation::RunpodBudgetGuardianSupervisor::Error, "guardian unavailable" if missing
      { "budget_id" => budget.budget_id, "plan_sha256" => budget.plan_sha256,
        "enabled" => healthy, "launchd_loaded" => healthy, "ready" => healthy,
        "pid" => Process.pid + 1000, "ledger_heartbeat_at_utc" => @clock.call.iso8601,
        "state" => "ARMED" }
    end
  end

  # Only the provider operations used by the real RPOF fleet path are supported.
  # No HTTP client, subprocess, SSH, bootstrap or inference is permitted.
  class Provider
    attr_accessor :rate, :available, :behavior, :before_create
    attr_reader :creates, :deletes
    def initialize
      @rate = 0.5
      @available = true
      @creates = []
      @deletes = []
      @pods = {}
    end

    def list_gpu_types(cloud:, count:)
      raise "unexpected catalog query" unless cloud == "SECURE" && count.positive?
      [A40, BLACKWELL].map do |id|
        { "id" => id, "memory" => 96, "secure" => true,
          "availability" => available ? "HIGH" : "NONE", "price" => { "secure" => rate } }
      end
    end

    def list_pods = @pods.values

    def create_pod(body)
      before_create.call(body)
      @creates << body
      raise "provider response lost" if behavior == :ambiguous
      if behavior == :unavailable
        raise LocalModelEvaluation::RunpodClient::Error.new(409, "capacity unavailable")
      end
      id = "offline-#{creates.length}"
      @pods[id] = {
        "id" => id, "name" => body.fetch("name"), "status" => "RUNNING",
        "cloud" => body.fetch("cloud"), "gpu" => body.fetch("gpu"), "cost" => rate,
        "runtime" => { "ports" => [{ "private" => 22, "public" => 22000 + creates.length,
                                    "type" => "tcp", "ip" => "198.51.100.10" }] }
      }
      { "id" => id }
    end

    def get_pod(id)
      @pods.fetch(id) { raise LocalModelEvaluation::RunpodClient::Error.new(404, "not found") }
    end

    def delete_pod(id)
      @deletes << id
      @pods.delete(id)
      { "id" => id, "status" => "TERMINATED" }
    end
  end

  class Bringup
    def reconcile!(worker:, **)
      stage = { "status" => "passed", "evidence" => {} }
      { "identity" => worker.slice("worker_id", "generation_id"),
        "overall_status" => "prerequisites_passed", "readiness_prerequisites_satisfied" => true,
        "tunnel" => stage, "bootstrap" => stage, "capability" => stage }
    end
  end

  def setup
    workspace = ENV["AF_FO21_WORKSPACE_ROOT"]
    skip "set AF_FO21_WORKSPACE_ROOT to the sibling-repository workspace" if workspace.to_s.empty?
    @rpof = File.join(workspace, "runpod-ollama-fleet")
    require File.join(@rpof, "lib/runpod_ollama_fleet")
    @root = Dir.mktmpdir("fo21d-")
    @now = Time.utc(2026, 10, 4, 12)
    @clock = -> { @now }
    hardware = RunpodOllamaFleet::ExecutionPoolHardware.new(path: File.join(@rpof, "config/execution_pool_hardware.yml"))
    @campaign = RunpodOllamaFleet::CapacityCampaign.load(
      path: File.join(@rpof, "test/fixtures/rpof-capacity-campaign-v0.1.json"), hardware:)
    @declaration = JSON.parse(File.binread(File.join(@rpof, "test/fixtures/rpof-capacity-campaign-budget-v0.1.json")))
    # Small original authority makes post-planning expenditure falsifiable within the original deadline.
    @declaration["max_cumulative_compute_usd"] = 0.2
    @guardian = Guardian.new(@clock)
    @binding = RunpodOllamaFleet::CampaignBudgetBinding.new(root: @root, repo_root: @rpof,
      campaign: @campaign, declaration: @declaration, wall_clock: @clock, guardian_supervisor: @guardian)
    @binding.arm!
    @desired = RunpodOllamaFleet::DesiredCapacity.new(binding: @binding, wall_clock: @clock)
    @desired.update!(profile_counts: @campaign.profiles.to_h { |p| [p.fetch("profile_id"), 0] },
      expected_revision: 0, reason: "offline fixture starts with no requested capacity")
    @provider = Provider.new
    @events = []
    @provider.before_create = lambda do |body|
      assert_equal A40, body.dig("gpu", "id")
      assert_equal "SECURE", body.fetch("cloud")
      assert_includes @events, :safety_pass
      assert_equal :reserved, @events.last
      assert ledger.fetch("reservations").values.any? { |row| row["status"] == "pending" }
      assert_equal "ARMED", ledger.fetch("state")
      @events << :provider_create
    end
    @key = File.join(@root, "offline.pub")
    File.write(@key, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFallbackOfflineOnly operator@example\n")
    @consumer = RunpodOllamaFleet::ConsumerCapacity.new(binding: @binding, wall_clock: @clock,
      source: ->(argv) { demand(argv.last) })
    @demand_count = 3
    @lifecycle = RunpodOllamaFleet::CampaignLifecycle.new(campaign: @campaign, binding: @binding,
      desired_capacity: @desired, consumer_capacity: @consumer, wall_clock: @clock,
      runtime_factory: method(:runtime), price_resolver: lambda do |profile, hardware_row|
        RunpodOllamaFleet::AuthorizedCandidates.observe(client: @provider,
          gpu_ids: [request(profile).required_gpu_id], cloud: hardware_row.fetch("cloud"))
          .find { |row| row.fetch("eligible") }&.fetch("hourly_rate_usd")
      end)
    @trace = TracePoint.new(:call, :c_call, :return) do |event|
      if event.event != :return && (event.self.is_a?(LocalModelEvaluation::RunpodClient) ||
          (%i[spawn exec system fork `].include?(event.method_id) &&
            caller_locations.any? { |location| location.path.start_with?(File.join(@rpof, "lib")) }) ||
          event.defined_class.to_s.match?(/TCPSocket|Socket|Net::HTTP/))
        raise "unexpected network/process operation: #{event.defined_class}##{event.method_id}"
      end
      next unless event.event == :return
      if event.self.equal?(@binding) && event.method_id == :assert_safety_gate! && event.return_value&.fetch("safety_gate", nil) == "PASS"
        @events << :safety_pass
      elsif event.self.is_a?(RunpodOllamaFleet::CampaignCapacityAdmission)
        @events << :reserved if event.method_id == :reserve! && event.return_value
        @events << :committed if event.method_id == :commit! && event.return_value
      end
    end
    @trace.enable
    @limits_before = authority_bytes
    @proposals = compose
    assert_equal "feasible", @proposals.fetch("status")
    assert_equal 2, @proposals.dig("preferred_proposal", "worker_count")
  end

  def teardown
    @trace&.disable
    FileUtils.remove_entry(@root) if @root
  end

  def test_real_composition_is_read_only_then_existing_lifecycle_reserves_and_commits
    before = tree
    assert_equal @proposals, compose
    assert_equal before, tree
    assert_empty @provider.creates
    assert_empty ledger.fetch("reservations")
    assert_empty @events
    result = handoff
    assert_equal "PASS", result.dig("safety_report", "safety_gate")
    assert_equal 2, @provider.creates.length
    assert_equal 2, ledger.fetch("owned_resources").length
    assert ledger.fetch("reservations").values.all? { |row| row["status"] == "committed" }
    assert_equal %i[reserved provider_create reserved provider_create committed committed], @events.reject { |v| v == :safety_pass }
    assert_equal @limits_before, authority_bytes
    refute @proposals.fetch("mutation_permission")
    refute @proposals.fetch("preferred_proposal").fetch("preferred_hardware").dig("admission_preview", "mutation_permission")
    state = runtime_for_profile.status
    assert_equal 2, state.fetch("current_workers")
    assert_equal [A40], fleet.fetch("workers").map { |row| row.fetch("gpu_id") }.uniq
    assert_equal @binding.binding_sha256, fleet.dig("campaign_authority", "binding_sha256")
  end

  def test_each_campaign_binding_profile_and_capability_mismatch_fails_before_any_mutation
    @proposals.fetch("association").each_key do |key|
      document = copy(@proposals)
      document["association"][key] = "wrong"
      before = tree
      assert_raises(SelectionError, key) { handoff(document:) }
      assert_equal before, tree, key
    end
    assert_empty @provider.creates
    assert_empty ledger.fetch("reservations")
  end

  def test_count_and_hardware_selection_cannot_be_replaced_or_widened
    changes = [{ "worker_count" => 3 }, { "worker_count" => 7 },
      { "preferred_hardware" => { "gpu_id" => "UNAUTHORIZED" } },
      { "preferred_hardware" => @proposals.dig("preferred_proposal", "preferred_hardware").merge("gpu_id" => BLACKWELL) },
      { "max_cumulative_compute_usd" => 1_000_000 }, { "consumer_id" => "replacement" }]
    changes.each do |change|
      selected = @proposals.fetch("preferred_proposal").merge(change)
      before = tree
      assert_raises(SelectionError) { handoff(selected:) }
      assert_equal before, tree
    end
    assert_empty @provider.creates
  end

  def test_required_gpu_is_enforced_even_if_both_advisory_copies_are_tampered
    document = copy(@proposals)
    document["preferred_proposal"]["preferred_hardware"]["gpu_id"] = BLACKWELL
    document["proposals"].find { |row| row["worker_count"] == 2 }["preferred_hardware"]["gpu_id"] = BLACKWELL
    assert_raises(SelectionError) { handoff(document:) }
    assert_empty ledger.fetch("reservations")
    assert_empty @provider.creates
  end

  def test_expired_original_deadline_cannot_be_rearmed_by_old_proposal
    @now += 5401
    refresh_heartbeats
    assert_refused(/deadline|ARMED|teardown/i)
    assert_equal @limits_before, authority_bytes
  end

  def test_unhealthy_guardian_overrides_feasible_proposal
    @guardian.healthy = false
    assert_refused(/guardian|safety/i)
  end

  def test_unavailable_guardian_overrides_feasible_proposal
    @guardian.missing = true
    assert_refused(/guardian|unavailable|safety/i)
  end

  def test_new_guardian_failure_after_intent_update_blocks_controller_admission
    error = assert_raises(RunpodOllamaFleet::CampaignLifecycle::Error) do
      handoff { @guardian.healthy = false }
    end
    assert_match(/guardian/i, error.message)
    assert_empty ledger.fetch("reservations")
    assert_empty @provider.creates
    assert_equal @limits_before, authority_bytes
  end

  def test_even_consistently_forged_counts_cannot_raise_owner_maxima
    [4, 7].each do |count|
      document = copy(@proposals)
      document["preferred_proposal"]["worker_count"] = count
      document["proposals"].find { |row| row["worker_count"] == 2 }["worker_count"] = count
      assert_raises(RunpodOllamaFleet::CampaignLifecycle::Error) { handoff(document:) }
      assert_empty ledger.fetch("reservations")
      assert_empty @provider.creates
      assert_equal @limits_before, authority_bytes
    end
  end

  def test_nearly_consumed_budget_refuses_additional_crash_liability
    record_compute_after_planning(0.199)
    assert_operator ledger.fetch("accrued_compute_usd"), :<, 0.2
    assert_refused(/cumulative|safety/i)
    assert_operator ledger.fetch("accrued_compute_usd"), :>=, 0.199
  end

  def test_price_drift_exceeds_hourly_ceiling
    @provider.rate = 4.0
    assert_refused(/hourly|safety/i)
  end

  def test_unavailable_hardware_cannot_be_replaced_with_another_gpu
    @provider.available = false
    assert_refused(/rate|safety|available|candidate/i)
  end

  def test_new_profile_commitments_cannot_be_created_around
    3.times { |i| reserve_existing(PROFILE, "existing-#{i}") }
    count = ledger.fetch("reservations").length
    handoff
    assert_empty @provider.creates
    assert_equal count, ledger.fetch("reservations").length
    assert_raises(RunpodOllamaFleet::CampaignCapacityAdmission::Error) { reserve_existing(PROFILE, "overflow") }
    assert_equal @limits_before, authority_bytes
  end

  def test_campaign_ceiling_cannot_be_bypassed_when_all_profiles_are_committed
    @campaign.profiles.each do |profile|
      profile.fetch("max_workers").times { |i| reserve_existing(profile.fetch("profile_id"), "max-#{i}") }
    end
    handoff
    assert_empty @provider.creates
    assert_raises(RunpodOllamaFleet::CampaignCapacityAdmission::Error) { reserve_existing(PROFILE, "overflow") }
    assert_equal 6, ledger.fetch("reservations").length
    assert_equal @limits_before, authority_bytes
  end

  def test_consumed_budget_and_cumulative_liability_override_advisory_authority
    record_compute_after_planning(0.2)
    accrued = ledger.fetch("accrued_compute_usd")
    assert_operator accrued, :>=, 0.2
    assert_refused(/cumulative|budget|ARMED|safety/i)
    assert_operator ledger.fetch("accrued_compute_usd"), :>=, accrued
    assert_equal @limits_before, authority_bytes
  end

  def test_forged_advisory_limits_do_not_change_retained_limits_or_create_a_budget
    @provider.rate = 4.0
    document = copy(@proposals)
    document.fetch("proposals").each do |row|
      row["rpof_authority"]["limits"].transform_values! { 1_000_000 }
      row["rpof_campaign_deadline_utc"] = "2099-01-01T00:00:00Z"
      row["rpof_authority"]["original_deadline_at_utc"] = "2099-01-01T00:00:00Z"
      row["rpof_authority"]["profile_max_workers"] = 1_000_000
      row["rpof_authority"]["accrued_compute_usd"] = 0
    end
    budgets = Dir.glob(File.join(@root, "**", "*budget*"))
    assert_raises(RunpodOllamaFleet::CampaignLifecycle::Error) { handoff(document:) }
    assert_equal budgets, Dir.glob(File.join(@root, "**", "*budget*"))
    assert_equal @limits_before, authority_bytes
    assert_empty @provider.creates
  end

  def test_consumer_shrink_keeps_effective_target_and_binding_authoritative
    bind_consumer
    binding_bytes = File.binread(@consumer.path)
    @demand_count = 0
    result = handoff
    assert_equal 0, result.fetch("profiles").find { |row| row["profile_id"] == PROFILE }.fetch("desired_workers")
    assert_equal 2, @desired.current.fetch("profiles").find { |row| row["profile_id"] == PROFILE }.fetch("desired_workers")
    assert_empty @provider.creates
    assert_empty ledger.fetch("reservations")
    %w[consumer_id pool_id].each do |key|
      changed = JSON.parse(binding_bytes)
      changed["profiles"][0][key] = "f" * 64
      assert_raises(RunpodOllamaFleet::ConsumerCapacity::Error) { @consumer.bind!(changed) }
      assert_equal binding_bytes, File.binread(@consumer.path)
    end
  end

  def test_stopped_campaign_cannot_be_reactivated
    @lifecycle.stop
    assert_refused(/ARMED|closed|teardown/i)
    assert_equal @limits_before, authority_bytes
  end

  def test_draining_worker_is_not_removed_or_reactivated_by_replaying_proposal
    handoff
    original = fleet.fetch("workers").first
    options = original.slice("worker_id", "generation_id", "pod_id").transform_keys(&:to_sym)
      .merge(profile_id: PROFILE, fleet_id: fleet.fetch("fleet_id"), expected_revision: 0, reason: "offline drain")
    @lifecycle.select_worker(operation: "drain", **options)
    assert_equal "draining", fleet.fetch("workers").first.dig("lifecycle", "phase")
    assert_raises(RunpodOllamaFleet::CampaignLifecycle::Error) do
      @lifecycle.select_worker(operation: "remove", confirm: true, **options.merge(expected_revision: 1))
    end
    handoff
    assert_equal 2, @provider.creates.length
    assert_empty @provider.deletes
    assert_equal original.fetch("generation_id"), fleet.fetch("workers").first.fetch("generation_id")
    assert_equal "draining", fleet.fetch("workers").first.dig("lifecycle", "phase")
    assert_equal @limits_before, authority_bytes
  end

  def test_retired_generation_cannot_be_reused_by_selected_worker_command
    handoff
    original = fleet.fetch("workers").first
    options = original.slice("worker_id", "generation_id", "pod_id").transform_keys(&:to_sym)
      .merge(profile_id: PROFILE, fleet_id: fleet.fetch("fleet_id"), expected_revision: 0, reason: "offline retirement")
    @lifecycle.select_worker(operation: "drain", **options)
    @lifecycle.set_desired(profile_counts: { PROFILE => 1 }, expected_revision: @desired.current.fetch("revision"), reason: "operator lowers target")
    @lifecycle.select_worker(operation: "remove", confirm: true, **options.merge(expected_revision: 1))
    @lifecycle.reconcile_once(ssh_public_key_path: @key)
    retired = fleet.fetch("workers").first
    assert_equal "retired", retired.dig("lifecycle", "phase")
    assert_equal [original.fetch("pod_id")], @provider.deletes
    # An operator may request capacity again, but RPOF must use a fresh generation.
    handoff
    replacement = fleet.fetch("workers").first
    refute_equal original.fetch("generation_id"), replacement.fetch("generation_id")
    assert_equal "retired", replacement.fetch("history").last.dig("lifecycle", "phase")
    assert_raises(RunpodOllamaFleet::CampaignLifecycle::Error) do
      @lifecycle.select_worker(operation: "drain", **options)
    end
    assert_equal @limits_before, authority_bytes
  end

  def test_provider_ambiguity_keeps_pending_liability_without_burst_retry
    @provider.behavior = :ambiguous
    assert_raises(RunpodOllamaFleet::CampaignLifecycle::Error) { handoff }
    assert_equal 1, @provider.creates.length
    assert_equal 1, ledger.fetch("reservations").values.count { |row| row["status"] == "pending" }
    # A new controller pass must not create around the unresolved reservation.
    @lifecycle.reconcile_once(ssh_public_key_path: @key)
    assert_equal 1, @provider.creates.length
    assert_equal @limits_before, authority_bytes
  end

  def test_provider_capacity_failure_preserves_existing_absence_and_fallback_rules
    @provider.behavior = :unavailable
    assert_raises(RunpodOllamaFleet::CampaignLifecycle::Error) { handoff }
    assert_equal 1, @provider.creates.length
    assert_equal ["released"], ledger.fetch("reservations").values.map { |row| row.fetch("status") }
    assert_equal "exhausted", runtime_for_profile.status.dig("availability_fallback", "state")
    refute @provider.creates.any? { |body| body.dig("gpu", "id") != A40 }
    assert_equal @limits_before, authority_bytes
  end

  private

  def copy(value) = Marshal.load(Marshal.dump(value))
  def ledger = @binding.parent_budget.status

  def profile(id = PROFILE) = @campaign.profiles.find { |row| row["profile_id"] == id }
  def hardware(id = PROFILE) = @campaign.hardware_bindings.find { |row| row["profile_id"] == id }

  def request(row = profile)
    RunpodOllamaFleet::OllamaCapabilityRequest.new(JSON.generate(
      "contract_version" => "ollama-capability-request/v0.1",
      "ollama" => row.slice("model", "expected_digest", "required_context_length", "require_fully_gpu_resident")
        .merge("required_gpu_id" => hardware(row.fetch("profile_id")).fetch("qualified_gpu_ids").first)))
  end

  def association
    { "campaign_id" => @campaign.campaign_id, "campaign_identity_sha256" => @campaign.identity_sha256,
      "binding_sha256" => @binding.binding_sha256, "budget_id" => @binding.declaration.fetch("budget_id"),
      "profile_id" => PROFILE, "capability_fingerprint" => request.fingerprint }
  end

  def compose
    evidence = (1..3).to_h do |count|
      [count, RunpodOllamaFleet::CapacityPlanningEvidence.new(binding: @binding, profile_id: PROFILE,
        capability_request: request, client: @provider, clock: @clock).document(proposed_workers: count)]
    end
    wlo = {
      "contract_version" => "wlo-execution-measurements/v0.1", "read_only" => true,
      "measured_at_utc" => @now.iso8601,
      "execution" => { "plan_id" => "offline", "plan_sha256" => "d" * 64, "status" => "running",
        "window" => { "status" => "available", "started_at_utc" => (@now - 3600).iso8601,
          "ended_at_utc" => @now.iso8601, "end_basis" => "measurement_clock", "elapsed_seconds" => 3600.0 } },
      "work" => { "total_jobs" => 18, "completed" => 6, "pending" => 12, "running" => 0,
        "failed" => 0, "interrupted" => 0, "retry_pending" => 0, "remaining_jobs" => 12 },
      "samples" => { "completed_successful_attempts" => 6, "failed_attempts" => 0,
        "interrupted_attempts" => 0, "currently_running_attempts" => 0, "attempts_excluded_missing_or_invalid_timing" => 0 },
      "throughput" => { "status" => "available", "sample_count" => 6,
        "denominator_seconds" => 3600.0, "jobs_per_hour" => 6.0 },
      "queue_wait" => { "status" => "unavailable", "reason" => "not retained" }
    }
    AdventureFinderDeadlineProposals.compose(wlo:, deadline: (@now + 3600).iso8601,
      baseline_workers: 1, max_workers: 3, as_of: @now.iso8601, max_evidence_age_seconds: 0,
      association:, rpof_evidence: evidence)
  end

  # Test-only operator handoff. Validate the exact FO-21C selection and retained
  # identities; pass only absolute intent through existing add/reconciliation.
  # Never forward advisory budget, price, deadline, safety or consumer fields.
  # This fixture already requires A40, so preserving hardware does not change
  # the capability fingerprint or introduce a new runtime pinning mechanism.
  def handoff(document: @proposals, selected: document.fetch("preferred_proposal"))
    unless document["contract_version"] == AdventureFinderDeadlineProposals::CONTRACT_VERSION &&
        document["mutation_permission"] == false && document["association"] == association &&
        selected == document["preferred_proposal"]
      raise SelectionError, "proposal identity or selection mismatch"
    end
    row = document.fetch("proposals").find { |p| p["worker_count"] == selected.fetch("worker_count") }
    unless row && row.slice(*selected.keys) == selected &&
        row["status"] == "feasible" && row["mathematically_meets_deadline"] == true &&
        Time.iso8601(row.fetch("rpof_observed_at_utc")) <= @now &&
        selected.dig("preferred_hardware", "gpu_id") == request.required_gpu_id &&
        selected.dig("preferred_hardware", "cloud") == hardware.fetch("cloud")
      raise SelectionError, "selected count/hardware/evidence mismatch"
    end
    request.validate_profile!(profile:, hardware:)
    admission = RunpodOllamaFleet::CampaignCapacityAdmission.new(binding: @binding, profile_id: PROFILE)
    admission.assert_matches!(admission.authority_identity.merge(
      document.fetch("association").slice("campaign_identity_sha256", "binding_sha256", "budget_id", "profile_id")))
    @lifecycle.add(profile_counts: { PROFILE => selected.fetch("worker_count") },
      expected_revision: @desired.current.fetch("revision"), reason: "explicit offline selected proposal")
    yield if block_given?
    @lifecycle.reconcile_once(ssh_public_key_path: @key)
  end

  def runtime(row, hardware_row, admission)
    RunpodOllamaFleet::CampaignRunpodRuntime.new(root: @root, repo_root: @rpof, profile: row,
      hardware: hardware_row, client: @provider, admission:, out: StringIO.new, wall_clock: @clock,
      capability_request: request(row), campaign_identity_sha256: @campaign.identity_sha256,
      binding: @binding, bringup_reconciler_factory: ->(_guard) { Bringup.new })
  end

  def runtime_for_profile
    runtime(profile, hardware, RunpodOllamaFleet::CampaignCapacityAdmission.new(binding: @binding, profile_id: PROFILE))
  end

  def fleet
    namespace = LocalModelEvaluation::RunpodFleetNamespace.new(root: @root, repo_root: @rpof, fleet_key: PROFILE)
    LocalModelEvaluation::RunpodFleetState.new(root: namespace.state_root).current
  end

  def authority_bytes
    binding = File.binread(@binding.state_path)
    budget = JSON.parse(File.binread(@binding.parent_budget.state_path))
    JSON.generate([binding, budget.slice("budget_id", "plan_sha256", "limits", "armed_at_utc", "deadline_at_utc"),
      @campaign.profiles, @campaign.hardware_bindings])
  end

  def tree
    Dir.glob(File.join(@root, "**", "*"), File::FNM_DOTMATCH).select { |p| File.file?(p) }
      .sort.to_h { |p| [p.delete_prefix(@root), File.binread(p)] }
  end

  def assert_refused(pattern)
    reservations = ledger.fetch("reservations")
    error = assert_raises(RunpodOllamaFleet::CampaignLifecycle::Error) { handoff }
    assert_match pattern, error.message
    assert_equal reservations, ledger.fetch("reservations")
    assert_empty @provider.creates
    assert_equal @limits_before, authority_bytes
  end

  def reserve_existing(id, logical)
    RunpodOllamaFleet::CampaignCapacityAdmission.new(binding: @binding, profile_id: id).reserve!(
      operation_type: "create", logical_resource_id: logical, max_hourly_rate_delta_usd: 0.5,
      gpu_id: hardware(id).fetch("qualified_gpu_ids").first, cloud: "SECURE")
  end

  def record_compute_after_planning(amount)
    # Another actor commits capacity after planning; real elapsed time accrues tracked cost.
    @binding.parent_budget.reserve_mutation!(operation_type: "create", fleet_key: PROFILE,
      logical_resource_id: "historical", max_hourly_rate_delta_usd: 0.5, reservation_id: "history")
    @binding.parent_budget.commit_mutation!(reservation_id: "history", provider_resource_id: "historical-pod",
      actual_hourly_rate_usd: 0.5, started_at_utc: @now)
    @now += (amount * 7200).ceil
    refresh_heartbeats
    @binding.parent_budget.mark_resource_absent!(provider_resource_id: "historical-pod", verified_absent: true,
      stopped_at_utc: @now)
  end

  def refresh_heartbeats
    @binding.parent_budget.heartbeat!(source: "guardian")
    @binding.parent_budget.heartbeat!(source: "orchestrator")
  end

  def bind_consumer
    @consumer.bind!("contract_version" => "rpof-consumer-binding/v0.1",
      "campaign_identity_sha256" => @campaign.identity_sha256, "binding_sha256" => @binding.binding_sha256,
      "idle_grace_seconds" => 0, "profiles" => @campaign.profiles.map do |row|
        { "profile_id" => row.fetch("profile_id"), "consumer_id" => "c" * 64, "plan_sha256" => "d" * 64,
          "pool_id" => row.fetch("profile_id"), "source_argv" => ["/offline-only", row.fetch("profile_id")],
          "capability_request" => JSON.parse(request(row).normalized_json).merge("contract_version" => "ollama-capability-request/v0.1") }
      end)
  end

  def demand(id)
    { "contract_version" => "wlo-consumer-demand/v0.1", "consumer_id" => "c" * 64,
      "plan_sha256" => "d" * 64, "pool_id" => id, "capability_fingerprint" => request(profile(id)).fingerprint,
      "observed_at" => @now.iso8601, "heartbeat_at" => @now.iso8601, "fresh" => true,
      "state" => "active", "runnable_count" => @demand_count, "bound_count" => 0,
      "uncertain_count" => 0, "quiescent" => true }
  end
end
