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
require "adventure_finder_staged_workload_preparation"

class IG14EStagedWorkloadRestartAcceptanceTest < Minitest::Test
  OPERATION_ID = "11111111-1111-4111-8111-111111111111"
  WORKLOAD_ID = "synthetic-operation-1"

  def setup
    front = File.expand_path("../..", __dir__)
    components = ENV["AF_PROJECT_ROOT"] || File.expand_path("../adventure-finder-components", front)
    @pipeline = ENV["AF_DATA_PIPELINE_ROOT"] || File.join(components, "af-data-pipeline")
    @afw_source = ENV["AF_TEST_HISTORICAL_AFW_ROOT"] || ENV["AF_AFW_ROOT"] || ENV["AF_WORKLOADS_ROOT"] || File.join(components, "af-workloads")
    @scorer_source = ENV["AF_SCORER_ROOT"] || File.join(components, "af-cli-scoring-utility")
    @pipeline = File.expand_path(@pipeline)
    @afw_source = File.expand_path(@afw_source)
    @scorer_source = File.expand_path(@scorer_source)
    required = [File.join(@pipeline, "bin", "af-staged-scoring-authority"),
                File.join(@afw_source, "lib", "af_workloads.rb"),
                File.join(@scorer_source, "bin", "af-score")]
    skip "IG-14E component checkouts are unavailable" unless required.all? { |path| File.file?(path) }
    $LOAD_PATH.unshift(File.join(@pipeline, "lib")) unless $LOAD_PATH.include?(File.join(@pipeline, "lib"))
    require File.join(@pipeline, "lib", "af_data_pipeline")
    require File.join(@pipeline, "test", "support", "staged_scoring_fixture")
    extend StagedScoringFixture unless singleton_class.ancestors.include?(StagedScoringFixture)

    @temporary = Dir.mktmpdir("ig14e-acceptance")
    @afw = File.join(@temporary, "af-workloads")
    @scorer = File.join(@temporary, "af-cli-scoring-utility")
    clone_fixture(@afw_source, @afw)
    clone_fixture(@scorer_source, @scorer)
    @source_snapshots = [@pipeline, @afw_source, @scorer_source].to_h { |root| [root, git_observation(root)] }
  end

  def teardown
    if @source_snapshots
      @source_snapshots.each { |root, before| assert_equal before, git_observation(root), "source tree changed: #{root}" }
    end
    FileUtils.remove_entry(@temporary) if @temporary && File.exist?(@temporary)
  end

  def test_actual_owner_contracts_preserve_mixed_allocation_across_process_restart
    fixture = File.join(@temporary, "evidence-mixed")
    FileUtils.mkdir_p(fixture)
    result, shared_before = prepare_fixture(fixture, [{start: 10, end: 11}, {start: 12, end: 111}])

    assert_equal "PREPARED", result.fetch("status")
    assert_equal "afw-staged-selection/v0.1", result.dig("selection", "schema_version")
    assert_equal %w[ADV-0003], result.fetch("selection").fetch("selected_ids")
    dispositions = result.fetch("selection").fetch("dispositions")
    assert_equal %w[selected-qualified legitimately-deferred], dispositions.map { |row| row.fetch("disposition") }
    assert_equal "ADV-0004", dispositions.last.fetch("adventure_id")
    assert_equal 100, dispositions.last.dig("evidence", "page_count")
    assert_equal "afw-workload-inspection/v0.1", result.dig("inspection", "contract_version")
    assert_equal "reuse", result.dig("inspection", "action")
    assert result.fetch("manifest")

    replay = restart_preparation(fixture)
    assert_equal result, replay
    assert_equal shared_before, shared_snapshot(fixture)
  end

  private

  def prepare_fixture(root, units)
    evidence = build_authority_fixture(root, cache_namespace: root, units:)
    inputs = File.join(root, "authority-inputs.json")
    File.write(inputs, JSON.pretty_generate(
      "schema_version" => "af-staged-scoring-evidence-locators/v0.1",
      "evidence" => evidence.transform_keys(&:to_s)
    ) + "\n")
    store = File.join(root, "authorities")
    state = File.join(root, "PROJECT_STATE.yml")
    authority = StagedScoringFixture::AUTH.new(
      evidence:, store_root: store, mode: "synthetic"
    ).issue!(current_state_path: state).fetch("authority")
    catalog = File.join(root, authority.dig("staged_amc", "filename"))
    write_scorer_fixture(root, catalog, authority)
    @fixture_options = {root:, inputs:, store:, state:, catalog:}
    before = shared_snapshot(root)
    [coordinator_for(root).prepare(
      operation_id: OPERATION_ID, workload_id: WORKLOAD_ID, catalog_path: catalog
    ), before]
  end

  def coordinator_for(root)
    options = @fixture_options
    raise "fixture root mismatch" unless options && options.fetch(:root) == root
    AdventureFinderWorkspace::AFWStagedWorkloadCoordinator.new(
      afw_root: @afw, scorer_root: @scorer, pipeline_root: @pipeline,
      authority_inputs_path: options.fetch(:inputs), authority_store: options.fetch(:store),
      current_project_state_path: options.fetch(:state), mode: "synthetic"
    )
  end

  def restart_preparation(root)
    raise "fixture root mismatch" unless @fixture_options.fetch(:root) == root
    front = File.expand_path("../..", __dir__)
    script = <<~'RUBY'
      require "json"
      require "adventure_finder_staged_workload_preparation"
      afw, scorer, pipeline, inputs, store, state, catalog = ARGV
      coordinator = AdventureFinderWorkspace::AFWStagedWorkloadCoordinator.new(
        afw_root: afw, scorer_root: scorer, pipeline_root: pipeline,
        authority_inputs_path: inputs, authority_store: store,
        current_project_state_path: state, mode: "synthetic"
      )
      puts JSON.generate(coordinator.prepare(
        operation_id: "11111111-1111-4111-8111-111111111111",
        workload_id: "synthetic-operation-1", catalog_path: catalog
      ))
    RUBY
    Dir.mktmpdir("ig14e-restart") do |elsewhere|
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, "-I", File.join(front, "lib"),
        "-I", File.join(@pipeline, "lib"), "-I", File.join(@afw, "lib"),
        "-I", File.join(@scorer, "lib"), "-e", script,
        @afw, @scorer, @pipeline, @fixture_options.fetch(:inputs),
        @fixture_options.fetch(:store), @fixture_options.fetch(:state),
        @fixture_options.fetch(:catalog), chdir: elsewhere
      )
      assert status.success?, "restart failed: #{stderr}"
      JSON.parse(stdout)
    end
  end

  def write_scorer_fixture(root, catalog, authority)
    template = {
      "contract_version" => "afsu-prepared-source/v0.1",
      "adventure" => {"id" => "__ADVENTURE_ID__"},
      "source_policy" => {
        "allow_full_source_fallback" => false,
        "allow_inward_boundary_clamp" => false,
        "max_inward_boundary_clamp_gap" => nil
      }
    }
    {
      "catalog" => catalog,
      "source_registry" => File.join(root, "source", "source_registry.yml"),
      "source_file" => File.join(root, "source", "fixture.md")
    }.each do |key, path|
      template[key] = {"path" => path, "sha256" => Digest::SHA256.file(path).hexdigest}
    end
    File.write(File.join(@scorer, "prepared-template.json"), JSON.pretty_generate(template) + "\n")
    executable = File.join(@scorer, "bin", "af-score")
    File.write(executable, <<~'SCRIPT')
      #!/bin/sh
      set -eu
      allowed=0
      destination=""
      dimension="null"
      prepare=0
      id=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --prepare-source) destination="$2"; allowed=1; prepare=1; shift 2 ;;
          --render-preflight) destination="$2"; shift 2 ;;
          --preflight) allowed=1; shift ;;
          --dimension) dimension="\"$2\""; shift 2 ;;
          --config|--model|--output|--prepared-source) shift 2 ;;
          *) id="$1"; shift ;;
        esac
      done
      [ "$allowed" -eq 1 ] || { echo "inference prohibited" >&2; exit 99; }
      scorer_root=$(cd "$(dirname "$0")/.." && pwd)
      if [ "$prepare" -eq 1 ]; then
        sed "s/__ADVENTURE_ID__/$id/g" "$scorer_root/prepared-template.json" > "$destination"
      elif [ -n "$destination" ]; then
        printf '{"synthetic":true,"id":"%s","dimension":%s}' "$id" "$dimension" > "$destination"
      fi
    SCRIPT
    FileUtils.chmod(0o755, executable)
    assert_equal authority.fetch("staged_amc").except("filename"),
                 StagedScoringFixture::AUTH.file_binding(catalog)
  end

  def shared_snapshot(root)
    state = YAML.safe_load_file(File.join(root, "PROJECT_STATE.yml"), aliases: false)
    paths = [File.join(root, "PROJECT_STATE.yml")]
    state.fetch("catalog_head").then { |entry| paths << File.join(root, entry.fetch("filename")) }
    state.fetch("matcher_authorized_baseline").then { |entry| paths << File.join(root, entry.fetch("filename")) }
    state.fetch("production_dependency_floor").then { |entry| paths << File.join(root, entry.fetch("filename")) }
    paths.uniq.to_h { |path| [path, [File.size(path), Digest::SHA256.file(path).hexdigest]] }
  end

  def clone_fixture(source, destination)
    _stdout, stderr, status = Open3.capture3("git", "clone", "--quiet", "--shared", source, destination)
    raise "fixture clone failed: #{stderr}" unless status.success?
  end

  def git_observation(root)
    head, head_status = Open3.capture2("git", "-C", root, "rev-parse", "HEAD")
    status, status_status = Open3.capture2("git", "-C", root, "status", "--porcelain=v1", "--untracked-files=all")
    raise "cannot observe fixture source #{root}" unless head_status.success? && status_status.success?
    [head.strip, status]
  end
end
