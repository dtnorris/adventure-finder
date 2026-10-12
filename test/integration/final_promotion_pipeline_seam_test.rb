# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "stringio"
require "tmpdir"
require "yaml"
require_relative "../../lib/adventure_finder_final_promotion"

class FinalPromotionPipelineSeamTest < Minitest::Test
  Status = Struct.new(:exitstatus) do
    def success? = exitstatus.zero?
  end
  Result = Struct.new(:stdout, :stderr, :status, keyword_init: true)
  GIT_ENV = {
    "GIT_AUTHOR_NAME" => "Synthetic fixture", "GIT_AUTHOR_EMAIL" => "fixture@example.invalid",
    "GIT_COMMITTER_NAME" => "Synthetic fixture", "GIT_COMMITTER_EMAIL" => "fixture@example.invalid"
  }.freeze

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
      original_roles = fixture.fetch(:roles)
      runner = DirectPipelineRunner.new(
        package: fixture.fetch(:package), package_path: fixture.fetch(:package_path),
        pipeline_root: @pipeline_root
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
      assert File.file?(File.join(fixture.fetch(:catalog), fixture.dig(:candidate_binding, "filename")))
      assert_includes output.string, "Final promotion: PROMOTED."
      assert_includes output.string, "git add PROJECT_STATE.yml #{fixture.dig(:candidate_binding, 'filename')}"
      assert_equal %w[prepare approve adopt], runner.adoption_actions
    end
  end

  private

  class DirectPipelineRunner
    attr_reader :adoption_actions

    def initialize(package:, package_path:, pipeline_root:)
      @package = package
      @package_path = package_path
      @pipeline_root = pipeline_root
      @adoption_actions = []
    end

    def capture(argv, chdir:)
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
  end

  def build_fixture(root)
    front_door = File.join(root, "adventure-finder")
    components = File.join(root, "adventure-finder-components")
    catalog = File.join(components, "af-xlsx-data-sources")
    FileUtils.mkdir_p([front_door, catalog])
    base = File.join(catalog, "5e_Adventure_Master_Catalog_1.0.xlsx")
    baseline = File.join(catalog, "5e_Adventure_Master_Catalog_0.5.xlsx")
    write_compatible_amc(base, rows: [compatible_row("ADV-0001", title: "Existing", scores: {"Seriousness" => 3})])
    FileUtils.cp(base, baseline)
    manifest = File.join(catalog, "PROJECT_STATE.yml")
    File.binwrite(manifest, YAML.dump(
      "schema_version" => AfDataPipeline::ProjectState::SCHEMA_VERSION,
      "catalog_head" => role_for(base, "1.0"),
      "matcher_authorized_baseline" => role_for(baseline, "0.5"),
      "production_dependency_floor" => role_for(baseline, "0.5")
    ))
    git(catalog, "init", "-q")
    git(catalog, "remote", "add", "origin", "fixture://catalog")
    git(catalog, "add", ".")
    git(catalog, "commit", "-qm", "synthetic catalog")
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
    {front_door:, components:, catalog:, manifest:, inputs:, package:, package_path:, candidate_binding:, roles:, head:,
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
    stdout, stderr, status = Open3.capture3(GIT_ENV, "git", "-C", root, *args)
    raise "git #{args.join(' ')} failed: #{stderr}" unless status.success?

    stdout
  end
end
