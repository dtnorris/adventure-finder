# frozen_string_literal: true

# Reuses the FO-21D strict provider and the real RPOF admission/runtime seams.
# The fixture uses the same root and capability association as the release flow.
require_relative "../fo21d_deadline_admission"

class Fo24cCapacity < Fo21dDeadlineAdmissionTest
  def self.runnable_methods = []
  attr_reader :binding, :campaign, :declaration, :desired, :lifecycle, :provider, :guardian, :events, :key
  attr_accessor :now

  def initialize(root)
    super("fixture")
    @fixture_root = root
    FileUtils.mkdir_p(root)
  end

  def setup
    workspace = ENV["AF_FO21_WORKSPACE_ROOT"]
    skip "set AF_FO21_WORKSPACE_ROOT to the sibling-repository workspace" if workspace.to_s.empty?
    @rpof = File.join(workspace, "runpod-ollama-fleet")
    require File.join(@rpof, "lib/runpod_ollama_fleet")
    @root = @fixture_root
    @now = Time.now.utc
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
    @limits_before = authority_bytes
  end

  def evidence(count)
    RunpodOllamaFleet::CapacityPlanningEvidence.new(binding: @binding, profile_id: PROFILE,
      capability_request: request, client: @provider, clock: @clock).document(proposed_workers: count)
  end

  def select(document)
    @proposals = document
    handoff
  end

  def authority = authority_bytes
  def state = ledger
  def current_fleet = fleet
  def runtime_status = runtime_for_profile.status
  def capability = request
  def identity = association

  def method_missing(name, *)
    Fo24aOfflineGuard.deny!("unsupported capacity fixture method #{name}")
  end
end
