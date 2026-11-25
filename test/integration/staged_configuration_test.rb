# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "yaml"
require "open3"
require "adventure_finder_staged_workload_preparation"

# Compose the AF coordinator with real pipeline authority and public scorer owners.
# Synthetic approvals authorize only this marker-only offline fixture, never production.
class StagedConfigurationTest < Minitest::Test
  # Allocate independent caller code and mechanical inputs; no private corpus is read.
  def setup
    components = ENV.fetch("AF_PROJECT_ROOT", File.expand_path("../../..", __dir__))
    public_pipeline = ENV["AF_TEST_PUBLIC_PIPELINE_ROOT"]
    @pipeline = public_pipeline || ENV.fetch("AF_DATA_PIPELINE_ROOT", File.join(components, "af-data-pipeline"))
    skip "select the public pipeline or set AF_SCORER_ROOT for this offline journey" unless
      public_pipeline || ENV["AF_SCORER_ROOT"]
    @afw = File.realpath(ENV.fetch("AF_TEST_PUBLIC_AFW_ROOT", File.join(components, "af-workloads")))
    @scorer = AdventureFinderWorkspace::WorkloadPaths.scorer_root!(components, override: ENV["AF_SCORER_ROOT"]).to_s
    @temporary = Dir.mktmpdir("staged-config-")
    @data = File.join(@temporary, "workload-store")
    FileUtils.mkdir(@data)
    $LOAD_PATH.unshift(File.join(@pipeline, "lib"))
    require File.join(@pipeline, "lib/af_data_pipeline")
    require File.join(@pipeline, "test/support/staged_scoring_fixture")
    extend StagedScoringFixture
    @fixture = File.join(@temporary, "inputs")
    FileUtils.mkdir_p(@fixture)
    @evidence = build_authority_fixture(@fixture, cache_namespace: @temporary)
    @state = File.join(@fixture, "PROJECT_STATE.yml")
    @store = File.join(@temporary, "authority")
    @inputs = File.join(@temporary, "inputs.json")
    File.write(@inputs, JSON.generate("schema_version" => "af-staged-scoring-evidence-locators/v0.1", "evidence" => @evidence))
    @authority = AfDataPipeline::StagedScoringAuthority.new(evidence: @evidence, store_root: @store, mode: "synthetic")
      .issue!(current_state_path: @state).fetch("authority")
    @catalog = staged_catalog_path(@fixture)
    @config = File.join(@temporary, "selection.yml")
    @public = File.join(@temporary, "public")
    FileUtils.mkdir_p(@public)
    %w[documents.json AdventureFinder_Analysis_Ontology_AFAO_v1.6.1.md AdventureFinder_Analysis_Data_Assessment_Specification_v0.1.md].each do |name|
      FileUtils.cp(File.join(ENV.fetch("AF_TEST_SPEC_ROOT", File.join(components, "af-specification-md")), name), @public)
    end
    @selection = {"paths" => {"xlsx_root" => @fixture, "source_root" => File.join(@fixture, "source"),
      "specification_root" => @public, "output_root" => File.join(@data, "output")}}
    File.write(@config, YAML.dump(@selection))
    @bytes = File.binread(@config)
  end

  # Remove only this test's disposable roots.
  def teardown
    if @temporary && ENV["AF_TEST_EVIDENCE_ROOT"]
      evidence = File.join(ENV.fetch("AF_TEST_EVIDENCE_ROOT"), File.basename(@temporary))
      FileUtils.mkdir_p(evidence)
      %w[inputs inputs.json selection.yml authority workload-store/workloads workload-store/build].each do |name|
        source = File.join(@temporary, name)
        next unless File.exist?(source)
        destination = File.join(evidence, name)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp_r(source, destination)
      end
    end
    FileUtils.remove_entry(@temporary) if @temporary
  end

  # Prepare, inspect, revalidate via pipeline's actual subprocess owner call, then
  # refuse changed/missing selectors and source bytes and accept exact restoration.
  def test_explicit_configuration_survives_preparation_and_owner_revalidation
    result = coordinator.prepare(**arguments)
    assert_equal "PREPARED", result.fetch("status"), result.dig("refusal", "reason").inspect
    assert_equal "reuse", result.dig("inspection", "action")
    selected = result.fetch("selection")
    assert_equal Digest::SHA256.hexdigest(@bytes), selected.dig("scorer_config", "sha256")
    assert_equal "afsu-prepared-source/v0.2", selected.dig("dispositions", 0, "evidence", "source_preflight", "contract_version")
    assert_equal "PREPARED", coordinator.prepare(**arguments).fetch("status")
    verify = pipeline_validation
    assert verify.fetch("preparation_allowed")
    assert verify.fetch("workload_frozen")
    File.unlink(@config)
    assert_raises(AdventureFinderWorkspace::AFWStagedWorkloadCoordinator::Failure) { coordinator.prepare(**arguments) }
    assert_raises(AfDataPipeline::StagedScoringAuthority::Failure) { pipeline_validation }
    File.binwrite(@config, @bytes + "\n# changed bytes\n")
    assert_raises(AdventureFinderWorkspace::AFWStagedWorkloadCoordinator::Failure) { coordinator.prepare(**arguments) }
    assert_raises(AfDataPipeline::StagedScoringAuthority::Failure) { pipeline_validation }
    changed = Marshal.load(Marshal.dump(@selection))
    changed.fetch("paths")["xlsx_root"] = @public
    File.write(@config, YAML.dump(changed))
    assert_raises(AfDataPipeline::StagedScoringAuthority::Failure) { pipeline_validation }
    File.binwrite(@config, @bytes)
    assert_equal "PREPARED", coordinator.prepare(**arguments).fetch("status")
    assert pipeline_validation.fetch("preparation_allowed")
    assert_raises(AdventureFinderWorkspace::AFWStagedWorkloadCoordinator::Failure) { coordinator(config: nil).prepare(**arguments) }
    source = File.join(@fixture, "source/fixture.md")
    saved = File.binread(source)
    File.unlink(source)
    assert_raises(AfDataPipeline::ValidationError) { pipeline_validation }
    File.binwrite(source, saved + "0\n")
    assert_raises(AfDataPipeline::ValidationError) { pipeline_validation }
    File.binwrite(source, saved)
    assert pipeline_validation.fetch("preparation_allowed")
    assert_equal "PREPARED", coordinator.prepare(**arguments).fetch("status")
    case_path = Dir[File.join(@data, "build/workloads", arguments.fetch(:workload_id), "cases/*-ee.yml")].fetch(0)
    verify_command = [File.join(@afw, "bin/afw-score-job"), "--data-root", @data, "--verify-only", case_path]
    _stdout, stderr, status = Open3.capture3(*verify_command)
    assert status.success?, stderr
    _stdout, stderr, status = Open3.capture3({"WLO_WORKER_ENDPOINT" => "http://127.0.0.1:1"},
      File.join(@afw, "bin/afw-score-job"), "--data-root", @data, case_path)
    refute status.success?
    assert_match(/public method execution requires separate qualification/, stderr)
  end

  private

  # Return the supported AF owner with explicit component selectors.
  def coordinator(config: @config)
    AdventureFinderWorkspace::AFWStagedWorkloadCoordinator.new(afw_root: @afw, afw_data_root: @data, scorer_root: @scorer,
      pipeline_root: @pipeline, authority_inputs_path: @inputs, authority_store: @store,
      current_project_state_path: @state, scorer_config: config, mode: "synthetic")
  end

  # Return identities issued by the synthetic authority, without caller ID selection.
  def arguments
    {operation_id: @authority.dig("operation", "operation_id"), workload_id: @authority.dig("intent", "workload_id"), catalog_path: @catalog}
  end

  # Exercise the downstream owner API and its real afw-staged-selection verifier.
  def pipeline_validation
    manifest = File.join(@data, "workloads", arguments.fetch(:workload_id))
    binding = JSON.parse(File.binread(File.join(manifest, "staged-scoring.json"))).fetch("binding")
    paths = {"plan" => File.join(manifest, "execution-plan.json"), "snapshot" => File.join(manifest, "snapshot.yml"),
      "index" => File.join(manifest, "case_index.csv"), "generated" => File.join(@data, "build/workloads", arguments.fetch(:workload_id))}
    AfDataPipeline::StagedScoringAuthority.new(evidence: @evidence, store_root: @store, mode: "synthetic",
      selection_afw_root: @afw, selection_project_root: @data, selection_scorer_root: @scorer, selection_scorer_config: @config)
      .validate!(current_state_path: @state, selection_path: File.join(@data, "workloads/.selections", arguments.fetch(:workload_id), "selection.json"),
        frozen_workload: binding, workload_paths: paths)
  end
end
