# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"
require "yaml"

require "adventure_finder_local_capacity"

class LocalCapacityTest < Minitest::Test
  class Executor
    attr_reader :calls
    def initialize = @calls = []
    def call(environment, argv, chdir:) = @calls << { environment:, argv:, chdir: }
  end

  def setup
    @root = Dir.mktmpdir("af-local-capacity-")
    @afw = File.join(@root, "af-workloads-production")
    @wlo = File.join(@root, "workload-orchestrator-production")
    @low = File.join(@root, "local-ollama-workers")
    @plan = File.join(@afw, "workloads", "batch-39", "execution-plan.json")
    FileUtils.mkdir_p(File.dirname(@plan))
    FileUtils.mkdir_p(File.join(@low, "bin"))
    File.write(File.join(@low, "Gemfile"), "source 'https://example.invalid'\n")
    File.write(File.join(@low, "bin", "low"), "#!/usr/bin/env ruby\n")
    FileUtils.chmod(0o755, File.join(@low, "bin", "low"))
    @requirement = { "model" => "qwen3.6:35b-a3b", "expected_digest" => "a" * 64,
                     "required_context_length" => 131_072, "require_fully_gpu_resident" => true }
    File.write(@plan, JSON.generate(
      "contract_version" => "wlo-execution-plan/v0.3", "plan_id" => "batch-39",
      "pools" => [{ "pool_id" => "qwen", "requirements" => { "ollama" => @requirement } }],
      "jobs" => []
    ))
    @registry_path = File.join(@root, "contexts.yml")
    File.write(@registry_path, YAML.dump(
      "schema_version" => "adventurefinder-production-context/v0.1",
      "contexts" => {
        "batch" => { "39" => {
          "production_batch_id" => "batch-39",
          "afw" => { "repository_root" => "af-workloads-production",
                     "workload_root" => "af-workloads-production/workloads/batch-39",
                     "plan_path" => "af-workloads-production/workloads/batch-39/execution-plan.json" },
          "wlo" => { "repository_root" => "workload-orchestrator-production",
                     "output_root" => "workload-orchestrator-production/output/batch-39" },
          "local_workers" => { "repository_root" => "local-ollama-workers" },
          "plan" => { "plan_id" => "batch-39", "sha256" => Digest::SHA256.file(@plan).hexdigest },
          "model_aliases" => { "qwen35" => ["qwen"] }, "associated_fleets" => []
        } },
        "fleet" => {}
      }
    ))
    @bundle = File.join(@root, "bundle")
    File.write(@bundle, "#!/bin/sh\n")
    FileUtils.chmod(0o755, @bundle)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_bootstrap_is_explicit_and_passes_exact_plan_derived_requirement_to_low
    registry = AdventureFinderWorkspace::ProductionContextRegistry.new(@registry_path, workspace_root: @root)
    executor = Executor.new
    action = AdventureFinderWorkspace::LocalCapacity.new(
      registry:, executor:, bundle_executable: @bundle
    )

    assert_equal 0, action.bootstrap(batch_handle: "39", alias_name: "qwen35")
    call = executor.calls.fetch(0)
    path = call.fetch(:argv).fetch(call.fetch(:argv).index("--requirement") + 1)
    refute path.start_with?(File.join(@wlo, "output", "batch-39", ""))
    artifact = JSON.parse(File.read(path))
    assert_equal "adventurefinder-model-requirement/v0.1", artifact.fetch("contract_version")
    assert_equal @requirement, artifact.fetch("ollama")
    assert_equal [@bundle, "exec", File.join(@low, "bin", "low"), "bootstrap"], call.fetch(:argv).first(4)
    assert_equal "--json", call.fetch(:argv).last
    assert_equal({ "BUNDLE_GEMFILE" => File.join(@low, "Gemfile") }, call.fetch(:environment))
    assert_equal @low, call.fetch(:chdir)
  end

  def test_unknown_alias_fails_before_low_is_called
    registry = AdventureFinderWorkspace::ProductionContextRegistry.new(@registry_path, workspace_root: @root)
    executor = Executor.new
    action = AdventureFinderWorkspace::LocalCapacity.new(
      registry:, executor:, bundle_executable: @bundle
    )
    assert_raises(AdventureFinderWorkspace::Error) do
      action.bootstrap(batch_handle: "39", alias_name: "not-a-pool")
    end
    assert_empty executor.calls
  end
end
