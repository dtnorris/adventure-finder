# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"
require "yaml"

require "adventure_finder_batch"
require_relative "support/wlo_contract"
require File.join(WLO_ROOT, "lib/workload_orchestrator")

class BatchFrontDoorTest < Minitest::Test
  PLAN_ID = "production-batch-039-fixture"

  class Executor
    attr_reader :calls

    def initialize(result = nil)
      @result = result
      @calls = []
    end

    def call(environment, argv, chdir:)
      @calls << { environment:, argv:, chdir: }
      @result
    end
  end

  Status = Struct.new(:successful) { def success? = successful }
  Result = Struct.new(:stdout, :stderr, :status, keyword_init: true)

  class ComponentRunner
    attr_reader :calls
    attr_accessor :action_result

    def initialize(*results, action_result: nil)
      @results = results
      self.action_result = action_result
      @calls = []
    end

    def capture(environment, argv, chdir:)
      @calls << { environment:, argv:, chdir: }
      if argv.include?("action-check")
        raise "missing action-check result" unless action_result

        return action_result.respond_to?(:call) ? action_result.call(argv) : action_result
      end
      @results.shift || raise("unexpected component call")
    end
  end

  def setup
    @root = Dir.mktmpdir("af-batch-front-door-")
    @afw = File.join(@root, "af-workloads-production")
    @wlo = File.join(@root, "workload-orchestrator-production")
    @rpof = File.join(@root, "runpod-ollama-fleet-production")
    @low = File.join(@root, "local-ollama-workers")
    @workload = File.join(@afw, "workloads", PLAN_ID)
    @plan_path = File.join(@workload, "execution-plan.json")
    @output = File.join(@wlo, "output", PLAN_ID)
    [@workload, File.join(@wlo, "bin"), File.join(@rpof, "bin"), File.join(@low, "bin"),
     File.join(@rpof, "output", "runpod-fleets")].each { |path| FileUtils.mkdir_p(path) }
    write_executable(File.join(@wlo, "bin", "wlo"), "exit 0")
    write_executable(File.join(@rpof, "bin", "rpof"), "exit 0")
    write_executable(File.join(@low, "bin", "low"), "exit 0")
    File.write(File.join(@rpof, "Gemfile"), "source 'https://example.invalid'\n")
    File.write(File.join(@low, "Gemfile"), "source 'https://example.invalid'\n")
    File.write(File.join(@wlo, "Gemfile"), "source 'https://example.invalid'\n")
    write_plan
    write_registry
    @env = write_executable(File.join(@root, "env"), "exit 0")
    @bundle = write_executable(File.join(@root, "bundle"), "exit 0")
    @executor = Executor.new
    @out = StringIO.new
    @action_checks = {}
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_bs01_bs03_bs13_bs16_first_start_uses_exact_plan_and_wlo_foreground_only
    assert_equal 0, front_door.run("start", "39")
    call = @executor.calls.fetch(0)
    argv = call.fetch(:argv)

    assert_equal File.join(@wlo, "bin", "wlo"), argv.fetch(0)
    assert_equal "run", argv.fetch(1)
    assert_equal @plan_path, argv.fetch(2)
    assert_option argv, "--workdir", @afw
    assert_option argv, "--output", @output
    config_path = argv.fetch(argv.index("--worker-sources-config") + 1)
    config = YAML.safe_load_file(config_path, aliases: false)
    assert_equal "wlo-worker-sources/v0.2", config.fetch("contract_version")
    assert_equal %w[local remote], config.fetch("sources").map { |source| source.fetch("name") }
    local, remote = config.fetch("sources")
    [local, remote].each do |source|
      assert source.fetch("environment").values.all?(String)
      refute source.fetch("environment").key?("BUNDLE_LOCKFILE")
    end
    assert_equal [@env, "-u", "BUNDLE_LOCKFILE", @bundle, "exec", File.join(@low, "bin", "low"), "workers", "--json"],
                 [local.fetch("command"), *local.fetch("args")]
    assert_equal [@env, "-u", "BUNDLE_LOCKFILE", @bundle, "exec", File.join(@rpof, "bin", "rpof"), "workers", "--json"],
                 [remote.fetch("command"), *remote.fetch("args")]
    assert_equal File.join(@rpof, "output", "runpod-fleets"),
                 remote.dig("environment", "RPOF_STATE_ROOT")
    refute argv.any? { |value| value.include?("af-workers") }
    refute_includes argv, "bootstrap"
    refute argv.any? { |value| value.match?(/build|compile|manifest|retry-failed|acknowledge|campaign|desired/) }
    assert_equal @wlo, call.fetch(:chdir)
    assert_empty call.fetch(:environment)
    assert_includes @out.string, "Ctrl-C: cancel this foreground WLO execution"
    refute_includes @out.string, "[="
  end

  def test_local_only_source_does_not_require_remote_checkout
    write_registry(worker_sources: ["local"])
    FileUtils.rm_rf(@rpof)

    assert_equal 0, front_door.run("start", "39")
    config = launched_worker_config
    assert_equal ["local"], config.fetch("sources").map { |source| source.fetch("name") }
    assert_equal @low, config.dig("sources", 0, "workdir")
  end

  # Exercise AF's actual YAML with the owner loader; invalid environments raise
  # WLO::Error rather than passing through a copied or stubbed validator.
  def test_generated_configuration_loads_with_real_wlo
    front_door.run("start", "39")
    argv = @executor.calls.last.fetch(:argv)
    path = argv.fetch(argv.index("--worker-sources-config") + 1)
    sources = WorkloadOrchestrator::WorkerSourceConfiguration.load(path)
    assert_equal %w[local remote], sources.entries.map(&:name)
    assert_equal %w[optional optional], sources.entries.map(&:policy)
  end

  # Missing policies default to optional for explicit and implicit selections.
  # Real WLO loads exact rows; unselected, unregistered publishers are absent.
  def test_default_policies_load_for_explicit_and_implicit_selections
    [["local"], ["remote"], %w[local remote]].product([true, false]).each do |names, explicit|
      write_registry(worker_sources: names)
      mutate_registry do |batch|
        batch.delete("worker_sources") unless explicit
        batch.delete("local_workers") unless names.include?("local")
        batch["associated_fleets"] = [] unless names.include?("remote")
      end
      document = YAML.safe_load_file(@registry)
      document.dig("contexts", "fleet").clear unless names.include?("remote")
      File.write(@registry, YAML.dump(document))
      front_door.run("start", "39")
      argv = @executor.calls.last.fetch(:argv)
      path = argv.fetch(argv.index("--worker-sources-config") + 1)
      document = YAML.safe_load_file(path, aliases: false)
      assert_equal %w[contract_version sources], document.keys.sort
      assert_equal "wlo-worker-sources/v0.2", document.fetch("contract_version")
      document.fetch("sources").each do |row|
        assert_equal %w[args command environment name policy workdir], row.keys.sort
      end
      loaded = WorkloadOrchestrator::WorkerSourceConfiguration.load(path)
      assert_equal names, loaded.entries.map(&:name)
      assert_equal ["optional"] * names.length, loaded.entries.map(&:policy)
      loaded.entries.each do |entry|
        root, executable = entry.name == "local" ? [@low, "low"] : [@rpof, "rpof"]
        environment = {"BUNDLE_GEMFILE" => File.join(root, "Gemfile")}
        if entry.name == "remote"
          environment.merge!("RPOF_STATE_ROOT" => File.join(root, "output/runpod-fleets"), "RPOF_STATE_REPO_ROOT" => root)
        end
        assert_equal [@env, "-u", "BUNDLE_LOCKFILE", @bundle, "exec", File.join(root, "bin", executable), "workers", "--json"], entry.source.argv
        assert_equal environment, entry.source.environment
        assert_equal root, entry.source.workdir
      end
    end
  end

  # Explicit mixed and all-required mappings remain exact owner authority.
  def test_explicit_policies_remain_authoritative
    [%w[optional required], %w[required optional], %w[required required]].each do |policies|
      mutate_registry { |batch| batch["worker_source_policies"] = %w[local remote].zip(policies).to_h }
      front_door.run("start", "39")
      argv = @executor.calls.last.fetch(:argv)
      path = argv.fetch(argv.index("--worker-sources-config") + 1)
      assert_equal policies, WorkloadOrchestrator::WorkerSourceConfiguration.load(path).entries.map(&:policy)
    end
  end

  # Generating on start/resume leaves retained legacy and explicit YAML bytes
  # untouched. Direct WLO reads still treat v0.1 as required.
  def test_generation_preserves_retained_source_files
    front_door.run("start", "39")
    document = launched_worker_config
    directory = File.join(File.dirname(@output), "worker-sources")
    retained = ["wlo-worker-sources/v0.1", "wlo-worker-sources/v0.2"].to_h do |version|
      previous = Marshal.load(Marshal.dump(document))
      previous["contract_version"] = version
      previous.fetch("sources").each do |row|
        row["policy"] = "required"
        row.delete("policy") if version.end_with?("v0.1")
      end
      bytes = YAML.dump(previous)
      path = File.join(directory, "#{PLAN_ID}-#{Digest::SHA256.hexdigest(bytes)[0, 12]}.yml")
      File.binwrite(path, bytes)
      [path, bytes]
    end
    prepare_retained(status: "paused", jobs: [{"status" => "pending"}], paused: true)
    before = evidence
    front_door.run("resume", "39")
    assert_equal before, evidence
    retained.each do |path, bytes|
      assert_equal %w[required required], WorkloadOrchestrator::WorkerSourceConfiguration.load(path).entries.map(&:policy)
      assert_equal bytes, File.binread(path)
    end
    assert_equal %w[optional optional], launched_worker_config.fetch("sources").map { |row| row.fetch("policy") }
  end

  # Malformed rows fail at WLO's real loader without execution or file repair.
  def test_malformed_generated_rows_are_rejected_by_wlo
    front_door.run("start", "39")
    original = launched_worker_config
    [
      ->(row) { row.delete("policy") },
      ->(row) { row["policy"] = nil },
      ->(row) { row["policy"] = "ignored" },
      ->(row) { row["environment"]["BUNDLE_LOCKFILE"] = nil },
      ->(row) { row["args"] = "workers --json" },
      ->(row) { row["command"] = "" },
      ->(row) { row["workdir"] = File.join(@root, "missing") },
      ->(row) { row["extra"] = true }
    ].each do |corrupt|
      document = Marshal.load(Marshal.dump(original))
      corrupt.call(document.fetch("sources").first)
      path = File.join(@root, "malformed.yml")
      bytes = YAML.dump(document)
      File.binwrite(path, bytes)
      assert_raises(WorkloadOrchestrator::Error) { WorkloadOrchestrator::WorkerSourceConfiguration.load(path) }
      assert_equal bytes, File.binread(path)
    end
    assert_equal 1, @executor.calls.length
  end

  # Configuration errors must refuse before action-check or execution, even
  # when every declared publisher would otherwise be optional.
  def test_invalid_source_selections_and_policy_maps_refuse_before_launch
    prepare_retained(status: "paused", jobs: [{"status" => "pending"}], paused: true)
    before = evidence
    [
      {"worker_sources" => []},
      {"worker_sources" => %w[local local]},
      {"worker_sources" => ["unknown"]},
      {"worker_source_policies" => {}},
      {"worker_source_policies" => {"local" => "optional"}},
      {"worker_source_policies" => {"local" => "optional", "remote" => "optional", "extra" => "optional"}},
      {"worker_source_policies" => {"local" => "ignored", "remote" => "optional"}},
      {"worker_source_policies" => {"local" => nil, "remote" => "optional"}},
      {"worker_source_policies" => []},
      {"worker_source_policies" => nil},
      {"worker_source_policies" => false},
      {"worker_source_policies" => "optional"},
      {"worker_sources" => [nil], "worker_source_policies" => {"local" => "optional"}}
    ].each do |changes|
      write_registry
      mutate_registry { |batch| batch.merge!(changes) }
      assert_raises(AdventureFinderWorkspace::Error, changes.inspect) { front_door.run("start", "39") }
      assert_empty @executor.calls
      assert_equal before, evidence
      assert_empty Dir.glob(File.join(File.dirname(@output), "worker-sources", "*"))
    end
    write_registry
    mutate_registry do |batch|
      batch.delete("worker_sources")
      batch["worker_source_policies"] = {"local" => "optional", "remote" => "optional"}
    end
    assert_raises(AdventureFinderWorkspace::Error) { front_door.run("start", "39") }
    assert_equal before, evidence
  end

  # Psych normally discards earlier duplicate keys. Ambiguous policy authority
  # must instead raise AF::Error before either selected publisher is launched.
  def test_duplicate_yaml_policy_keys_refuse
    source = File.read(@registry).sub("      worker_sources:",
      "      worker_source_policies:\n        local: required\n        local: optional\n        remote: optional\n      worker_sources:")
    File.write(@registry, source)
    error = assert_raises(AdventureFinderWorkspace::Error) { front_door.run("start", "39") }
    assert_includes error.message, "duplicate YAML mapping key"
    assert_empty @executor.calls
  end

  # Optional availability never excuses a missing authority or publisher file.
  def test_optional_sources_keep_component_file_and_authority_refusals
    [File.join(@low, "bin/low"), File.join(@low, "Gemfile"),
     File.join(@rpof, "bin/rpof"), File.join(@rpof, "Gemfile")].each do |path|
      bytes, mode = File.binread(path), File.stat(path).mode
      File.delete(path)
      assert_raises(AdventureFinderWorkspace::Error) { front_door.run("start", "39") }
      assert_empty @executor.calls
      File.binwrite(path, bytes)
      File.chmod(mode, path)
    end
    [@low, @rpof].each do |path|
      File.rename(path, "#{path}.retained")
      begin
        assert_raises(AdventureFinderWorkspace::Error) { front_door.run("start", "39") }
        assert_empty @executor.calls
      ensure
        File.rename("#{path}.retained", path)
      end
    end
    mutate_registry { |batch| batch.delete("local_workers") }
    assert_raises(AdventureFinderWorkspace::Error) { front_door.run("start", "39") }
    write_registry
    mutate_registry { |batch| batch["associated_fleets"] = [] }
    assert_raises(AdventureFinderWorkspace::Error) { front_door.run("start", "39") }
  end

  # Distinct registered RPOF roots are ambiguous even when both are optional.
  # A policy may change availability handling, never publisher authority.
  def test_optional_remote_refuses_ambiguous_fleet_authority
    document = YAML.safe_load_file(@registry, aliases: false)
    batch = document.dig("contexts", "batch", "39")
    batch.fetch("associated_fleets") << "B"
    other = Marshal.load(Marshal.dump(document.dig("contexts", "fleet", "A")))
    other.fetch("rpof")["repository_root"] = "other-rpof"
    document.dig("contexts", "fleet")["B"] = other
    File.write(@registry, YAML.dump(document))
    error = assert_raises(AdventureFinderWorkspace::Error) { front_door.run("start", "39") }
    assert_includes error.message, "one registered RPOF worker-registry authority"
    assert_empty @executor.calls
  end

  def test_remote_only_source_does_not_require_local_checkout
    write_registry(worker_sources: ["remote"])
    FileUtils.rm_rf(@low)

    assert_equal 0, front_door.run("start", "39")
    config = launched_worker_config
    assert_equal ["remote"], config.fetch("sources").map { |source| source.fetch("name") }
    assert_equal @rpof, config.dig("sources", 0, "workdir")
  end

  def test_bs02_plan_sha_drift_fails_before_wlo_launch
    File.open(@plan_path, "a") { |file| file.write(" ") }
    error = assert_raises(AdventureFinderWorkspace::Error) { front_door.run("start", "39") }
    assert_includes error.message, "SHA-256 mismatch"
    assert_empty @executor.calls
  end

  def test_plan_identity_and_contract_drift_fail_closed
    write_plan("plan_id" => "wrong")
    update_registered_sha
    assert_raises(AdventureFinderWorkspace::Error) { front_door.run("start", "39") }
    write_plan("contract_version" => "wlo-execution-plan/v9")
    update_registered_sha
    error = assert_raises(AdventureFinderWorkspace::Error) { front_door.run("start", "39") }
    assert_includes error.message, "unsupported foreground plan contract"
  end

  def test_bs04_bs05_completed_batch_is_untouched_and_not_executed
    prepare_retained(status: "completed", jobs: [{ "status" => "complete", "attempt" => 1 }])
    before = evidence

    assert_equal 0, front_door.run("start", "39")

    assert_empty @executor.calls
    assert_equal before, evidence
    assert_includes @out.string, "retained scoring evidence is unchanged"
  end

  def test_bs06_paused_start_refuses_without_clearing_pause
    prepare_retained(status: "paused", jobs: [{ "status" => "pending" }], paused: true)
    error = assert_raises(AdventureFinderWorkspace::Error) { front_door.run("start", "39") }

    assert_includes error.message, "bin/af-batch resume 39"
    assert File.file?(File.join(@output, "control", "pause"))
    assert_empty @executor.calls
  end

  def test_bs07_resume_requires_retained_state_then_delegates_only_to_wlo_resume
    error = assert_raises(AdventureFinderWorkspace::Error) { front_door.run("resume", "39") }
    assert_includes error.message, "no retained execution"
    prepare_retained(status: "paused", jobs: [{ "status" => "pending" }], paused: true)

    assert_equal 0, front_door.run("resume", "39")
    argv = @executor.calls.fetch(0).fetch(:argv)
    assert_equal "resume", argv.fetch(1)
    refute_includes argv, "--acknowledge-circuit-breaker"
    refute_includes argv, "retry-failed"
  end

  def test_bs08_failed_execution_requires_explicit_recovery
    prepare_retained(status: "workload_failed", jobs: [{ "status" => "failed", "attempt" => 1 }])
    before = evidence
    %w[start resume].each do |action|
      error = assert_raises(AdventureFinderWorkspace::Error) { front_door.run(action, "39") }
      assert_includes error.message, "retry-failed explicitly"
    end
    assert_equal before, evidence
    assert_empty @executor.calls
  end

  def test_bs08_failed_jobs_are_preserved_when_pending_work_is_safe
    prepare_retained(
      status: "pending",
      jobs: [{ "status" => "failed", "attempt" => 1 }, { "status" => "pending", "attempt" => nil }]
    )
    before = evidence

    assert_equal 0, front_door.run("start", "39")
    argv = @executor.calls.fetch(0).fetch(:argv)
    refute_includes argv, "retry-failed"
    refute_includes argv, "--resume"
    assert_equal before, evidence
  end

  def test_bs09_interrupted_work_is_never_implicitly_retried_or_unpaused
    prepare_retained(status: "paused", jobs: [{ "status" => "interrupted", "attempt" => 1 }], paused: true)
    before = evidence
    %w[start resume].each do |action|
      error = assert_raises(AdventureFinderWorkspace::Error) { front_door.run(action, "39") }
      assert_includes error.message, "explicit retry authorization"
    end
    assert_equal before, evidence
    assert_empty @executor.calls
  end

  def test_bs10_breaker_is_not_acknowledged_or_pause_cleared
    prepare_retained(
      status: "paused", jobs: [{ "status" => "pending" }], paused: true,
      breaker: { "tripped" => true, "reason" => "limit" }
    )
    before = evidence
    error = assert_raises(AdventureFinderWorkspace::Error) { front_door.run("resume", "39") }
    assert_includes error.message, "circuit breaker is tripped"
    assert_equal before, evidence
    assert_empty @executor.calls
  end

  def test_dispatch_halt_requires_explicit_recovery
    prepare_retained(status: "infrastructure_failed", jobs: [{ "status" => "pending" }],
                     extra: { "dispatch_halt" => { "kind" => "worker_registry" } })
    error = assert_raises(AdventureFinderWorkspace::Error) { front_door.run("start", "39") }
    assert_includes error.message, "dispatch is halted"
    assert_empty @executor.calls
  end

  def test_bs11_active_executor_lock_prevents_second_foreground_owner
    prepare_retained(status: "running", jobs: [{ "status" => "running", "attempt" => 1 }])
    set_action_check("run", "blocked", "executor_active", "already has an active executor")
    error = assert_raises(AdventureFinderWorkspace::Error) { front_door.run("start", "39") }
    assert_includes error.message, "active executor"
    assert_empty @executor.calls
  end

  def test_orphaned_running_state_requires_review
    prepare_retained(status: "running", jobs: [{ "status" => "running", "attempt" => 1 }])
    error = assert_raises(AdventureFinderWorkspace::Error) { front_door.run("start", "39") }
    assert_includes error.message, "without an active executor"
  end

  def test_bs12_foreground_executor_is_a_true_exec_handoff
    source = File.read(File.expand_path("../lib/adventure_finder_batch.rb", __dir__))
    assert_includes source, "Kernel.exec(environment, *argv, chdir:)"
    assert_includes source, '"action-check"'
    %w[execution.json jobs.json .execution.lock].each { |internal| refute_includes source, internal }
    refute_includes source, "retained_disposition!"
    refute_match(/def retained_(execution|disposition)/, source)
    refute_match(/Process\.spawn|system\(/, source)
  end

  def test_ar_batch_retry_resolves_exact_short_handles_and_delegates_selected_jobs
    write_plan("jobs" => [
                 { "job_id" => "production-batch-039-adv0946-structural-openness",
                   "pool_id" => "qwen", "argv" => ["bin/afw-score-job"] },
                 { "job_id" => "production-batch-039-adv0946-ee",
                   "pool_id" => "qwen", "argv" => ["bin/afw-score-job"] }
               ])
    update_registered_sha
    prepare_retained(
      status: "workload_failed",
      jobs: [{ "status" => "failed", "attempt" => 1 }, { "status" => "failed", "attempt" => 1 }]
    )
    before = evidence
    runner = ComponentRunner.new(
      diagnostic_result("0946-openness", "production-batch-039-adv0946-structural-openness"),
      diagnostic_result("0946-ee", "production-batch-039-adv0946-ee")
    )

    assert_equal 0, front_door(component_runner: runner).run(
      "retry", "39", jobs: %w[0946-openness 0946-ee], reason: "confirmed transient timeout",
      dry_run: true, acknowledge_circuit_breaker: true
    )

    argv = @executor.calls.fetch(0).fetch(:argv)
    assert_equal [@bundle, "exec", File.join(@wlo, "bin", "wlo"), "retry-failed"], argv.first(4)
    assert_equal 2, argv.count("--job")
    assert_includes argv, "production-batch-039-adv0946-structural-openness"
    assert_includes argv, "production-batch-039-adv0946-ee"
    assert_option argv, "--reason", "confirmed transient timeout"
    assert_includes argv, "--dry-run"
    assert_includes argv, "--acknowledge-circuit-breaker"
    refute_includes argv, "--all"
    refute_includes argv, File.join(@rpof, "bin", "rpof")
    assert_equal before, evidence
    assert_equal 3, runner.calls.length
    assert_includes runner.calls.fetch(1).fetch(:argv), "production-batch-039-adv0946-structural-openness"
    assert_includes runner.calls.fetch(2).fetch(:argv), "production-batch-039-adv0946-ee"
  end

  def test_ar_retry_requires_reason_and_fails_closed_on_ambiguous_or_duplicate_handles
    prepare_retained(status: "workload_failed", jobs: [{ "status" => "failed", "attempt" => 1 }])
    assert_raises(AdventureFinderWorkspace::Error) do
      front_door.run("retry", "39", jobs: ["job-1"], reason: " ")
    end
    assert_raises(AdventureFinderWorkspace::Error) do
      front_door.run("retry", "39", jobs: %w[job-1 job-1], reason: "reviewed")
    end

    write_plan("jobs" => [
                 { "job_id" => "first-adv0946-structural-openness", "group_id" => "ADV-0946",
                   "pool_id" => "qwen", "argv" => ["bin/afw-score-job"] },
                 { "job_id" => "second-adv0946-visual-openness", "group_id" => "ADV-0946",
                   "pool_id" => "qwen", "argv" => ["bin/afw-score-job"] }
    ])
    update_registered_sha
    prepare_retained(
      status: "workload_failed",
      jobs: [{ "status" => "failed", "attempt" => 1 }, { "status" => "failed", "attempt" => 1 }]
    )
    runner = ComponentRunner.new
    error = assert_raises(AdventureFinderWorkspace::Error) do
      front_door(component_runner: runner).run("retry", "39", jobs: ["0946-openness"], reason: "reviewed")
    end
    assert_includes error.message, "ambiguous"
    assert_equal 1, runner.calls.length
    assert_includes runner.calls.fetch(0).fetch(:argv), "action-check"
    assert_empty @executor.calls
  end

  def test_ar_recovery_is_read_only_and_repair_is_a_distinct_fail_closed_delegation
    prepare_retained(status: "workload_failed", jobs: [{ "status" => "failed", "attempt" => 1 }])
    before = evidence

    assert_equal 0, front_door.run("recovery", "39")
    recovery = @executor.calls.pop.fetch(:argv)
    assert_equal "recovery", recovery.fetch(3)
    refute_includes recovery, "retry-failed"

    assert_equal 0, front_door.run(
      "repair", "39", reason: "reviewed retained metadata", dry_run: true
    )
    repair = @executor.calls.pop.fetch(:argv)
    assert_equal "repair", repair.fetch(3)
    assert_option repair, "--reason", "reviewed retained metadata"
    assert_includes repair, "--dry-run"
    refute_includes repair, "retry-failed"
    assert_equal before, evidence
  end

  def test_bs14_unknown_handle_fails_closed
    error = assert_raises(AdventureFinderWorkspace::Error) { front_door.run("start", "40") }
    assert_includes error.message, "unknown production context: batch 40"
    assert_empty @executor.calls
  end

  def test_bs15_binary_honors_af_project_root
    recorder = File.join(@root, "wlo-argv.json")
    write_executable(File.join(@wlo, "bin", "wlo"), <<~RUBY)
      require "json"
      if ARGV.fetch(0) == "action-check"
        action = ARGV.fetch(ARGV.index("--action") + 1)
        puts JSON.generate(
          "contract_version" => "wlo-execution-action-check/v0.1",
          "action" => action,
          "disposition" => "execute",
          "reason" => "new_execution",
          "execution_status" => nil
        )
        exit 0
      end
      File.write(#{recorder.dump}, JSON.generate(ARGV))
      exit 0
    RUBY
    path = File.expand_path("../bin/af-batch", __dir__)
    _stdout, stderr, status = Open3.capture3(
      { "AF_PROJECT_ROOT" => @root }, RbConfig.ruby, path, "start", "39", "--registry", @registry
    )

    assert status.success?, stderr
    argv = JSON.parse(File.read(recorder))
    assert_equal "run", argv.fetch(0)
    assert_includes argv, @plan_path
    assert_includes argv, @output
  end

  def test_wlo_action_check_failure_or_invalid_result_fails_before_launch
    failed = Result.new(stdout: "", stderr: "retained execution identity mismatch", status: Status.new(false))
    runner = ComponentRunner.new(action_result: failed)
    error = assert_raises(AdventureFinderWorkspace::Error) do
      front_door(component_runner: runner).run("start", "39")
    end
    assert_includes error.message, "WLO action check failed"

    invalid = Result.new(stdout: JSON.generate("disposition" => "execute"), stderr: "", status: Status.new(true))
    runner = ComponentRunner.new(action_result: invalid)
    assert_raises(AdventureFinderWorkspace::Error) do
      front_door(component_runner: runner).run("start", "39")
    end
    assert_empty @executor.calls
  end

  private

  # Update fixture Batch 39 authority; receives its mutable context and rewrites
  # fixture YAML only. File/YAML errors propagate to the test.
  def mutate_registry
    document = YAML.safe_load_file(@registry, aliases: false)
    yield document.dig("contexts", "batch", "39")
    File.write(@registry, YAML.dump(document))
  end

  def front_door(component_runner: nil)
    action_result = lambda do |argv|
      action = argv.fetch(argv.index("--action") + 1)
      @action_checks.fetch(action) { default_action_check(action) }
    end
    component_runner ||= ComponentRunner.new(action_result:)
    component_runner.action_result ||= action_result if component_runner.respond_to?(:action_result=)
    AdventureFinderWorkspace::BatchFrontDoor.new(
      registry_path: @registry, workspace_root: @root, executor: @executor,
      component_runner:, env_executable: @env, bundle_executable: @bundle, out: @out
    )
  end

  def diagnostic_result(handle, id)
    Result.new(
      stdout: JSON.generate("subject" => { "handle" => handle, "id" => id }), stderr: "",
      status: Status.new(true)
    )
  end

  def action_check_result(action, disposition, reason, message = nil, status: nil)
    document = {
      "contract_version" => "wlo-execution-action-check/v0.1",
      "action" => action,
      "disposition" => disposition,
      "reason" => reason,
      "execution_status" => status
    }
    document["message"] = message if message
    Result.new(stdout: JSON.generate(document), stderr: "", status: Status.new(true))
  end

  def set_action_check(action, disposition, reason, message = nil, status: nil)
    @action_checks[action] = action_check_result(action, disposition, reason, message, status:)
  end

  def default_action_check(action)
    if action == "run"
      action_check_result(action, "execute", "new_execution")
    else
      action_check_result(action, "blocked", "no_retained_execution", "has no retained execution")
    end
  end

  def write_plan(overrides = {})
    document = {
      "contract_version" => "wlo-execution-plan/v0.3",
      "plan_id" => PLAN_ID,
      "failure_policy" => { "max_consecutive_failures" => 2, "max_total_failures" => 4 },
      "pools" => [{ "pool_id" => "qwen" }],
      "jobs" => [{ "job_id" => "job-1", "pool_id" => "qwen", "argv" => ["bin/afw-score-job"] }]
    }.merge(overrides)
    File.write(@plan_path, JSON.generate(document))
  end

  def write_registry(worker_sources: %w[local remote])
    @registry = File.join(@root, "production_contexts.yml")
    data = {
      "schema_version" => "adventurefinder-production-context/v0.1",
      "contexts" => {
        "batch" => {
          "39" => {
            "production_batch_id" => PLAN_ID,
            "afw" => { "repository_root" => "af-workloads-production",
                       "workload_root" => "af-workloads-production/workloads/#{PLAN_ID}",
                       "plan_path" => "af-workloads-production/workloads/#{PLAN_ID}/execution-plan.json" },
            "wlo" => { "repository_root" => "workload-orchestrator-production",
                       "output_root" => "workload-orchestrator-production/output/#{PLAN_ID}" },
            "local_workers" => { "repository_root" => "local-ollama-workers" },
            "worker_sources" => worker_sources,
            "plan" => { "plan_id" => PLAN_ID, "sha256" => Digest::SHA256.file(@plan_path).hexdigest },
            "associated_fleets" => ["A"]
          }
        },
        "fleet" => {
          "A" => {
            "campaign_id" => PLAN_ID,
            "rpof" => { "repository_root" => "runpod-ollama-fleet-production",
                        "campaign_path" => "runpod-ollama-fleet-production/campaign.json",
                        "budget_path" => "runpod-ollama-fleet-production/budget.json",
                        "state_root" => "runpod-ollama-fleet-production/output/runpod-fleets",
                        "binding_path" => "runpod-ollama-fleet-production/binding.json" },
            "associated_batches" => ["39"]
          }
        }
      }
    }
    File.write(@registry, YAML.dump(data))
  end

  def update_registered_sha
    data = YAML.safe_load_file(@registry, aliases: false)
    data.dig("contexts", "batch", "39", "plan", "sha256").replace(Digest::SHA256.file(@plan_path).hexdigest)
    File.write(@registry, YAML.dump(data))
  end

  def prepare_retained(status:, jobs:, paused: false, breaker: nil, extra: {})
    FileUtils.mkdir_p(@output)
    File.write(File.join(@output, "execution.json"), JSON.generate(
      execution_state(status, breaker:).merge(extra)
    ))
    FileUtils.cp(@plan_path, File.join(@output, "plan.json"))
    plan_jobs = JSON.parse(File.read(@plan_path)).fetch("jobs")
    normalized = jobs.each_with_index.map do |job, index|
      id = plan_jobs[index]&.fetch("job_id") || "job-#{index + 1}"
      { "job_id" => id, "pool_id" => "qwen" }.merge(job)
    end
    File.write(File.join(@output, "jobs.json"), JSON.generate("jobs" => normalized))
    File.write(File.join(@output, "retained.log"), "retained evidence\n")
    if paused
      FileUtils.mkdir_p(File.join(@output, "control"))
      File.write(File.join(@output, "control", "pause"), "requested\n")
    end
    FileUtils.touch(File.join(@output, ".execution.lock"))
    configure_retained_action_checks(status:, jobs:, paused:, breaker:, extra:)
  end

  def configure_retained_action_checks(status:, jobs:, paused:, breaker:, extra:)
    %w[retry-failed recovery repair].each do |action|
      set_action_check(action, "execute", "retained_execution", status:)
    end
    disposition, reason, message = retained_execution_check(status:, jobs:, paused:, breaker:, extra:)
    %w[run resume].each do |action|
      action_disposition, action_reason, action_message = disposition, reason, message
      if reason == "paused" && action == "resume"
        action_disposition, action_reason, action_message = "execute", "resume_paused_execution", nil
      end
      set_action_check(action, action_disposition, action_reason, action_message, status:)
    end
  end

  def retained_execution_check(status:, jobs:, paused:, breaker:, extra:)
    if breaker&.fetch("tripped", false)
      return ["blocked", "circuit_breaker", "circuit breaker is tripped; explicit reviewed recovery is required"]
    end
    if extra.key?("dispatch_halt")
      return ["blocked", "dispatch_halt", "dispatch is halted; explicit reviewed recovery is required"]
    end
    if jobs.any? { |job| job["status"] == "interrupted" }
      return ["blocked", "interrupted_attempts", "has interrupted work; explicit retry authorization is required"]
    end
    return ["already_complete", "completed", nil] if status == "completed"
    if status == "workload_failed"
      return ["blocked", "workload_failed", "has failed work; review evidence and use retry-failed explicitly"]
    end
    if status == "running"
      return ["blocked", "inactive_running_state",
              "retains running state without an active executor; review before recovery"]
    end
    return ["blocked", "paused", "is paused"] if status == "paused" || paused

    ["execute", "retained_pending_execution", nil]
  end

  def execution_state(status, breaker: nil)
    {
      "contract_version" => "wlo-execution-state/v0.1",
      "plan_id" => PLAN_ID,
      "plan_sha256" => Digest::SHA256.file(@plan_path).hexdigest,
      "workdir" => @afw,
      "status" => status,
      "circuit_breaker" => breaker || { "tripped" => false, "reason" => nil }
    }
  end

  def evidence
    Dir.glob(File.join(@output, "**", "*"), File::FNM_DOTMATCH)
       .select { |path| File.file?(path) }
       .to_h { |path| [path.delete_prefix("#{@output}/"), File.binread(path)] }
  end

  def write_executable(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#!/usr/bin/env ruby\n#{body}\n")
    FileUtils.chmod(0o755, path)
    path
  end

  def assert_option(argv, name, value)
    index = argv.index(name)
    refute_nil index, "missing #{name}"
    assert_equal value, argv.fetch(index + 1)
  end

  def launched_worker_config
    argv = @executor.calls.last.fetch(:argv)
    path = argv.fetch(argv.index("--worker-sources-config") + 1)
    YAML.safe_load_file(path, aliases: false)
  end
end
