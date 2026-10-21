# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "minitest/mock"
require "open3"
require "stringio"
require "tmpdir"
require "yaml"
require_relative "../../lib/adventure_finder_final_promotion"
require_relative "../support/ig19_git_fixture"

class FinalPromotionPipelineSeamTest < Minitest::Test
  Status = Struct.new(:exitstatus) do
    def success? = exitstatus.zero?
  end
  Result = Struct.new(:stdout, :stderr, :status, keyword_init: true)

  def setup
    component_root = ENV.fetch("AF_PROJECT_ROOT", "/Users/davidnorris/code/adventure-finder-components")
    @pipeline_root = File.expand_path(ENV.fetch("AF_DATA_PIPELINE_ROOT", File.join(component_root, "af-data-pipeline")))
    skip "composed pipeline checkout is unavailable" unless File.file?(File.join(@pipeline_root, "lib", "af_data_pipeline.rb"))

    $LOAD_PATH.unshift(File.join(@pipeline_root, "lib")) unless $LOAD_PATH.include?(File.join(@pipeline_root, "lib"))
    require "af_data_pipeline"
    require File.join(@pipeline_root, "test", "support", "compatibility_amc_fixture")
    self.class.include CompatibilityAmcFixture unless self.class < CompatibilityAmcFixture
  end

  def test_front_door_delegates_exact_approval_to_real_pipeline_transaction
    Dir.mktmpdir("final-promotion-composed-") do |root|
      fixture = build_fixture(root)
      unrelated = File.join(fixture.fetch(:catalog), "unrelated-dirty.txt")
      File.binwrite(unrelated, "operator work in progress\n")
      original_roles = fixture.fetch(:roles)
      original_git = git_observation(fixture.fetch(:catalog))
      original_preserved = [fixture.fetch(:base), fixture.fetch(:baseline), unrelated]
        .to_h { |path| [path, File.binread(path)] }
      runner = DirectPipelineRunner.new(
        package: fixture.fetch(:package), package_path: fixture.fetch(:package_path),
        pipeline_root: @pipeline_root, catalog: fixture.fetch(:catalog)
      )
      output = StringIO.new
      door = AdventureFinderWorkspace::FinalPromotion.new(
        front_door_root: fixture.fetch(:front_door), project_root: fixture.fetch(:components),
        pipeline_root: @pipeline_root, component_runner: runner, input: StringIO.new("APPROVE\n"),
        out: output, clock: -> { Time.utc(2026, 10, 12, 1, 45, 0) }
      )

      assert_equal 0, door.run(
        inputs_path: fixture.fetch(:inputs), package_path: fixture.fetch(:package_path),
        approver: "David Norris", operation_dir: fixture.fetch(:operation)
      )

      state = AfDataPipeline::ProjectState.new(manifest_path: fixture.fetch(:manifest))
      state.validate!
      promoted = role_binding(state.resolve("catalog_head"))
      assert_equal fixture.fetch(:candidate_binding), promoted
      current_roles = AfDataPipeline::ProjectState::ROLES.to_h do |role|
        [role, role_binding(state.resolve(role))]
      end
      assert_equal original_roles.except("catalog_head"), current_roles.except("catalog_head")
      assert_equal fixture.fetch(:head), git(fixture.fetch(:catalog), "rev-parse", "HEAD").strip
      destination = File.join(fixture.fetch(:catalog), fixture.dig(:candidate_binding, "filename"))
      assert File.file?(destination)
      assert_includes output.string, "Final promotion: PROMOTED."
      assert_includes output.string, "git add PROJECT_STATE.yml #{fixture.dig(:candidate_binding, 'filename')}"
      refute_includes output.string, "git add ."
      refute_includes output.string, "unrelated-dirty.txt"
      assert_includes output.string, "# push remains an explicit operator choice"
      assert_equal %w[prepare approve adopt], runner.adoption_actions

      assert_equal original_git, git_observation(fixture.fetch(:catalog))
      original_preserved.each { |path, bytes| assert_equal bytes, File.binread(path), path }
      manifest_after = File.binread(fixture.fetch(:manifest))
      destination_after = File.binread(destination)
      result_path = File.join(fixture.fetch(:operation), "adoption-result.json")
      durable_result = File.binread(result_path)
      assert_equal "PROMOTED", JSON.parse(durable_result).fetch("status")

      calls_after_promotion = runner.adoption_actions.length
      replay_output = StringIO.new
      replay = AdventureFinderWorkspace::FinalPromotion.new(
        front_door_root: fixture.fetch(:front_door), project_root: fixture.fetch(:components),
        pipeline_root: @pipeline_root, component_runner: runner, input: StringIO.new,
        out: replay_output, clock: -> { Time.utc(2026, 10, 12, 1, 46, 0) }
      )
      assert_equal 0, replay.run(
        inputs_path: fixture.fetch(:inputs), package_path: fixture.fetch(:package_path),
        approver: "David Norris", operation_dir: fixture.fetch(:operation)
      )
      assert_equal %w[adopt], runner.adoption_actions.drop(calls_after_promotion)
      assert_equal [""], runner.prepare_manifest_statuses
      assert_includes replay_output.string, "Final promotion: ALREADY_PROMOTED."
      refute_includes replay_output.string, "git add ."
      refute_includes replay_output.string, "unrelated-dirty.txt"
      assert_equal manifest_after, File.binread(fixture.fetch(:manifest))
      assert_equal destination_after, File.binread(destination)
      assert_equal durable_result, File.binread(result_path)
      assert_equal original_git, git_observation(fixture.fetch(:catalog))
      original_preserved.each { |path, bytes| assert_equal bytes, File.binread(path), path }
    ensure
      close_catalogs
    end
  end

  def test_front_door_decline_records_exact_authority_without_catalog_or_git_mutation
    Dir.mktmpdir("final-promotion-decline-") do |root|
      fixture = build_fixture(root)
      before = snapshot_catalog(fixture.fetch(:catalog))
      runner = DirectPipelineRunner.new(
        package: fixture.fetch(:package), package_path: fixture.fetch(:package_path),
        pipeline_root: @pipeline_root, catalog: fixture.fetch(:catalog)
      )
      output = StringIO.new
      door = AdventureFinderWorkspace::FinalPromotion.new(
        front_door_root: fixture.fetch(:front_door), project_root: fixture.fetch(:components),
        pipeline_root: @pipeline_root, component_runner: runner, input: StringIO.new("DECLINE\n"),
        out: output, clock: -> { Time.utc(2026, 10, 12, 1, 45, 0) }
      )

      assert_equal 3, door.run(
        inputs_path: fixture.fetch(:inputs), package_path: fixture.fetch(:package_path),
        approver: "David Norris", operation_dir: fixture.fetch(:operation)
      )
      assert_equal before, snapshot_catalog(fixture.fetch(:catalog))
      assert_equal %w[prepare decline adopt], runner.adoption_actions
      assert_equal [""], runner.prepare_manifest_statuses
      assert_includes output.string, "Final promotion: DECLINED. Catalog state is unchanged."
      refute_includes output.string, "git add ."
      refute File.exist?(File.join(fixture.fetch(:catalog), fixture.dig(:candidate_binding, "filename")))
      %w[adoption-decision.json coordination-decision.json adoption-result.json].each do |name|
        assert File.file?(File.join(fixture.fetch(:operation), name)), name
      end
    ensure
      close_catalogs
    end
  end

  def test_front_door_refuses_same_filename_different_bytes_without_overwrite
    Dir.mktmpdir("final-promotion-collision-") do |root|
      fixture = build_fixture(root)
      destination = File.join(fixture.fetch(:catalog), fixture.dig(:candidate_binding, "filename"))
      File.binwrite(destination, "pre-existing different bytes\n")
      before = snapshot_catalog(fixture.fetch(:catalog))
      runner = DirectPipelineRunner.new(
        package: fixture.fetch(:package), package_path: fixture.fetch(:package_path),
        pipeline_root: @pipeline_root, catalog: fixture.fetch(:catalog)
      )
      door = AdventureFinderWorkspace::FinalPromotion.new(
        front_door_root: fixture.fetch(:front_door), project_root: fixture.fetch(:components),
        pipeline_root: @pipeline_root, component_runner: runner, input: StringIO.new("APPROVE\n"),
        out: StringIO.new
      )

      error = assert_raises(AdventureFinderWorkspace::Error) do
        door.run(
          inputs_path: fixture.fetch(:inputs), package_path: fixture.fetch(:package_path),
          approver: "David Norris", operation_dir: fixture.fetch(:operation)
        )
      end
      assert_includes error.message, "refusing to overwrite existing AMC artifact"
      assert_equal before, snapshot_catalog(fixture.fetch(:catalog))
      assert_equal %w[prepare], runner.adoption_actions
      assert_equal [""], runner.prepare_manifest_statuses
    ensure
      close_catalogs
    end
  end

  private

  class DirectPipelineRunner
    attr_reader :adoption_actions, :prepare_manifest_statuses

    def initialize(package:, package_path:, pipeline_root:, catalog:)
      @package = package
      @package_path = package_path
      @pipeline_root = pipeline_root
      @catalog = catalog
      @adoption_actions = []
      @prepare_manifest_statuses = []
    end

    # Dispatch the supplied component argv/cwd within the sealed Git interval.
    # Returns the public result; unexpected commands and owner errors propagate.
    def capture(argv, chdir:)
      Ig19GitFixture.with_read_only_git { dispatch(argv, chdir:) }
    end

    # Execute the existing in-process component adapter and return its streams
    # and exit status; invalid roots/commands and owner exceptions propagate.
    def dispatch(argv, chdir:)
      raise "unexpected pipeline root" unless File.expand_path(chdir) == File.expand_path(@pipeline_root)

      script_index = File.basename(argv.first).start_with?("ruby") ? 1 : 0
      executable = File.basename(argv.fetch(script_index))
      action = argv.fetch(script_index + 1)
      out = StringIO.new
      err = StringIO.new
      code = case executable
             when "af-final-release-package"
               out.write(AfDataPipeline::StagedScoringAuthority.document_bytes(@package))
               0
             when "af-final-release-adoption"
               @adoption_actions << action
               if action == "prepare"
                 status = manifest_status
                 @prepare_manifest_statuses << status
                 raise "PROJECT_STATE.yml became dirty before adoption preparation: #{status}" unless status.empty?
               end
               validation = AfDataPipeline::FinalReleasePackage::Result.new(
                 package: @package, path: @package_path, reused: true
               )
               AfDataPipeline::FinalReleasePackage.stub(:validate!, validation) do
                 AfDataPipeline::FinalReleaseAdoption.run(argv.drop(script_index + 1), out:, err:)
               end
             when "af-project-state"
               manifest = argv.fetch(argv.index("--manifest") + 1)
               state = AfDataPipeline::ProjectState.new(manifest_path: manifest)
               state.validate!
               out.puts "Project state: PASS"
               AfDataPipeline::ProjectState::ROLES.each do |role|
                 resolved = state.resolve(role)
                 out.puts "#{role}: #{resolved.version} #{resolved.filename} #{resolved.sha256}"
               end
               0
             else
               raise "unexpected executable #{executable}"
             end
      Result.new(stdout: out.string, stderr: err.string, status: Status.new(code))
    end

    private

    def manifest_status
      stdout, stderr, status = Open3.capture3(
        "git", "-C", @catalog, "status", "--porcelain=v1", "--", "PROJECT_STATE.yml"
      )
      raise "git status failed before adoption preparation: #{stderr}" unless status.success?

      stdout.strip
    end
  end

  def build_fixture(root)
    front_door = File.join(root, "adventure-finder")
    components = File.join(root, "adventure-finder-components")
    catalog = File.join(components, "af-xlsx-data-sources")
    FileUtils.mkdir_p(front_door)
    sealed = Ig19GitFixture.load("promotion", catalog)
    (@sealed_catalogs ||= []) << sealed
    base = File.join(catalog, "5e_Adventure_Master_Catalog_1.0.xlsx")
    baseline = File.join(catalog, "5e_Adventure_Master_Catalog_0.5.xlsx")
    manifest = File.join(catalog, "PROJECT_STATE.yml")
    head = git(catalog, "rev-parse", "HEAD").strip

    candidate = File.join(root, "finalized-candidate.xlsx")
    write_compatible_amc(candidate, rows: [
      compatible_row("ADV-0001", title: "Existing", scores: {"Seriousness" => 4}),
      compatible_row("ADV-0002", title: "Added", scores: {})
    ])
    candidate_binding = {"version" => "2.0", "filename" => "5e_Adventure_Master_Catalog_2.0.xlsx",
                         **AfDataPipeline::StandingBulkScorePolicy.file_binding(candidate)}
    inputs = File.join(root, "package-inputs.json")
    File.binwrite(inputs, "{\"schema_version\":\"synthetic-inputs/v0.1\"}\n")
    evidence = File.join(root, "release-accounting.json")
    File.binwrite(evidence, "{\"synthetic\":true}\n")
    roles = current_roles(manifest)
    package = package_document(candidate, candidate_binding, base, evidence, manifest, roles, catalog, head)
    package_path = File.join(root, "package.json")
    File.binwrite(package_path, AfDataPipeline::StagedScoringAuthority.document_bytes(package))
    assert_fixture_manifest_clean!(catalog, "after fixture creation")
    {front_door:, components:, catalog:, manifest:, base:, baseline:, inputs:, package:, package_path:, candidate_binding:, roles:, head:,
     operation: File.join(front_door, "operations", "final-promotions", package.fetch("package_id"))}
  end

  def package_document(candidate, candidate_binding, base, evidence, manifest, roles, catalog, head)
    nodes = {
      "current_project_state" => {"path" => manifest, **AfDataPipeline::StandingBulkScorePolicy.file_binding(manifest)},
      "current_role:catalog_head" => {"path" => base, **AfDataPipeline::StandingBulkScorePolicy.file_binding(base)},
      "release_manifest" => {"path" => evidence, **AfDataPipeline::StandingBulkScorePolicy.file_binding(evidence)}
    }
    document = {
      "schema_version" => AfDataPipeline::FinalReleasePackage::SCHEMA,
      "candidate" => {"selection" => "original_ig17", "version" => "2.0", "frontier" => nil,
                      "selected" => {"path" => candidate, **AfDataPipeline::StandingBulkScorePolicy.file_binding(candidate)}},
      "release" => {
        "counts" => {"standing_directive_accepted" => 1, "individual_human_accepted" => 0,
                     "ig16b_machine_accepted" => 0, "historical_mechanical_accepted" => 0,
                     "human_hold" => 0, "human_reject" => 0, "source_holds" => 0,
                     "deferred_or_unsupported" => 0, "unscored_or_unresolved" => 0},
        "population" => {"intended_cases" => 1, "intended_metrics" => 1, "present_metrics" => 1,
                         "remaining_blank_metrics" => 0, "terminal_gap_metrics" => 0,
                         "residual_gap_metrics" => 0, "hard_exceptions" => 0,
                         "unresolved_execution_cases" => 0, "conflicting_targets" => 0, "gaps" => []},
        "preview" => {"requested" => false, "available" => false, "authority_effect" => "none"}
      },
      "compatibility" => {"status" => "PASS", "afw_execution_compatibility" => "not validated by this static workbook gate",
                          "consumer_contracts" => ["pipeline catalog", "static scorer columns"],
                          "canonical_adventure_count" => 2, "mirror_mode" => "mirrored"},
      "scoring_concurrency" => {"decision" => "SAFE_REUSE", "reason" => "UNCHANGED_BASE"},
      "readiness" => {"ready" => true, "full_scoring" => true,
                      "approval_authorized" => false, "catalog_adoption_authorized" => false},
      "transition" => {
        "catalog_repository" => {"remote_url" => "fixture://catalog", "head" => head},
        "current_project_state" => nodes.fetch("current_project_state"),
        "original_frozen_base" => role_for(base, "1.0"), "current_roles" => roles,
        "proposed_catalog_head" => candidate_binding, "independent_roles_preserved" => true,
        "delta" => {"added_ids" => ["ADV-0002"], "removed_ids" => [],
                    "changed_cells" => [{"adventure_id" => "ADV-0001", "field" => "Seriousness"}],
                    "concurrent_changes_preserved" => true}
      },
      "provenance" => {"nodes" => nodes, "edges" => []}
    }
    document["package_id"] = AfDataPipeline::StandingBulkScorePolicy.digest(document)
    document
  end

  def current_roles(manifest)
    state = AfDataPipeline::ProjectState.new(manifest_path: manifest)
    state.validate!
    AfDataPipeline::ProjectState::ROLES.to_h { |role| [role, role_binding(state.resolve(role))] }
  end

  def role_binding(role)
    {"version" => role.version, "filename" => role.filename, "sha256" => role.sha256, "bytes" => role.bytes}
  end

  def role_for(path, version)
    {"version" => version, "filename" => File.basename(path),
     **AfDataPipeline::StandingBulkScorePolicy.file_binding(path)}
  end

  def git(root, *args)
    stdout, stderr, status = Open3.capture3(Ig19GitFixture::GIT_ENV, "git", "-C", root, *args)
    raise "git #{args.join(' ')} failed: #{stderr}" unless status.success?

    stdout
  end

  def assert_fixture_manifest_clean!(root, phase)
    status = git(root, "status", "--porcelain=v1", "--", "PROJECT_STATE.yml").strip
    committed = git(root, "show", "HEAD:PROJECT_STATE.yml")
    actual = File.binread(File.join(root, "PROJECT_STATE.yml"))
    raise "PROJECT_STATE.yml bytes changed #{phase}" unless actual == committed
    raise "PROJECT_STATE.yml is dirty #{phase}: #{status}" unless status.empty?
  end

  # Check the complete metadata inventory at the end of this bounded seam.
  def close_catalogs
    Array(@sealed_catalogs).each(&:close)
    @sealed_catalogs = []
  end

  def git_observation(root)
    {
      "literal_metadata" => Ig19GitFixture.inventory(File.join(root, ".git"), directories: true),
      "head" => git(root, "rev-parse", "HEAD"),
      "refs" => git(root, "show-ref"),
      "index" => git(root, "ls-files", "--stage")
    }
  end

  def snapshot_catalog(root)
    files = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)
      .select { |path| File.file?(path) && !path.start_with?(File.join(root, ".git") + File::SEPARATOR) }
      .to_h { |path| [path.delete_prefix(root + File::SEPARATOR), File.binread(path)] }
    {"git" => git_observation(root), "files" => files}
  end
end
