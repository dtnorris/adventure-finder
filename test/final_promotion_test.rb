# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "stringio"
require "tmpdir"
require "time"
require_relative "../lib/adventure_finder_final_promotion"

class FinalPromotionTest < Minitest::Test
  Status = Struct.new(:exitstatus) do
    def success? = exitstatus.zero?
  end
  Result = Struct.new(:stdout, :stderr, :status, keyword_init: true)

  class OwnerRunner
    attr_reader :calls
    attr_accessor :reject_live_validation, :fail_replay

    def initialize(package:, fail_adopt: false, decision_exit: nil, decision_transform: nil, decision_stdout: nil)
      @package = package
      @fail_adopt = fail_adopt
      @decision_exit = decision_exit
      @decision_transform = decision_transform
      @decision_stdout = decision_stdout
      @calls = []
    end

    def capture(argv, chdir:)
      script_index = File.basename(argv.first).start_with?("ruby") ? 1 : 0
      executable = File.basename(argv.fetch(script_index))
      action = argv.fetch(script_index + 1)
      @calls << [executable, action, argv, chdir]
      @inputs_path = option(argv, "--inputs") if argv.include?("--inputs")
      @package_path = option(argv, "--package") if argv.include?("--package")
      case [executable, action]
      when ["af-final-release-package", "validate"]
        if @reject_live_validation
          return Result.new(stdout: "", stderr: "package reference changed: current_project_state", status: Status.new(2))
        end
        result(@package, @package.dig("readiness", "ready") ? 0 : 2)
      when ["af-final-release-adoption", "prepare"]
        request = adoption_request
        write(option(argv, "--output"), request)
        result(request)
      when ["af-final-release-adoption", "approve"], ["af-final-release-adoption", "decline"]
        decision = {
          "schema_version" => AdventureFinderWorkspace::FinalPromotion::DECISION_SCHEMA,
          "decision" => action == "approve" ? "APPROVE" : "DECLINE",
          "decided_by" => option(argv, "--decided-by"),
          "decision_id" => "d" * 64
        }
        decision = @decision_transform.call(decision) if @decision_transform
        write(option(argv, "--output"), decision)
        code = @decision_exit.nil? ? (action == "decline" ? 3 : 0) : @decision_exit
        Result.new(
          stdout: @decision_stdout || JSON.pretty_generate(decision) + "\n",
          stderr: code.zero? ? "" : "synthetic decision failure",
          status: Status.new(code)
        )
      when ["af-final-release-adoption", "adopt"]
        return Result.new(stdout: JSON.generate("status" => "FAILED"), stderr: "stale package", status: Status.new(2)) if @fail_adopt || @fail_replay

        decision = JSON.parse(File.binread(option(argv, "--approval")))
        request = adoption_request
        replayed = File.file?(option(argv, "--result"))
        status = decision.fetch("decision") == "DECLINE" ? "DECLINED" : (replayed ? "ALREADY_PROMOTED" : "PROMOTED")
        File.binwrite(request.dig("catalog", "project_state", "path"), "promoted manifest\n") if status == "PROMOTED"
        document = {
          "schema_version" => AdventureFinderWorkspace::FinalPromotion::RESULT_SCHEMA,
          "status" => status,
          "request_id" => request.fetch("request_id"),
          "decision_id" => decision.fetch("decision_id"),
          "package_id" => @package.fetch("package_id"),
          "candidate" => request.fetch("candidate").slice("version", "filename", "sha256", "bytes"),
          "catalog" => %w[PROMOTED ALREADY_PROMOTED].include?(status) ? {
            "project_state" => @package.dig("provenance", "nodes", "current_project_state").merge(binding(request.dig("catalog", "project_state", "path"))),
            "repository_root" => request.dig("catalog", "repository_root"),
            "catalog_head" => request.fetch("candidate").slice("version", "filename", "sha256", "bytes"),
            "independent_roles" => request.dig("catalog", "roles").except("catalog_head")
          } : nil
        }
        write(option(argv, "--result"), document) unless replayed
        result(document, status == "DECLINED" ? 3 : 0)
      when ["af-project-state", "validate"]
        candidate = adoption_request.fetch("candidate")
        stdout = "Project state: PASS\ncatalog_head: #{candidate['version']} #{candidate['filename']} #{candidate['sha256']}\n"
        Result.new(stdout:, stderr: "", status: Status.new(0))
      else
        raise "unexpected component call: #{argv.inspect}"
      end
    end

    private

    def adoption_request
      candidate = @package.dig("transition", "proposed_catalog_head").merge(
        "selection" => @package.dig("candidate", "selection"),
        "path" => @package.dig("candidate", "selected", "path"),
        "destination" => "/catalog/#{@package.dig('transition', 'proposed_catalog_head', 'filename')}"
      )
      {
        "schema_version" => AdventureFinderWorkspace::FinalPromotion::REQUEST_SCHEMA,
        "request_id" => "c" * 64,
        "package" => {"package_id" => @package.fetch("package_id"), "path" => @package_path, **binding(@package_path),
                      "inputs" => {"path" => @inputs_path, **binding(@inputs_path)}},
        "candidate" => candidate,
        "catalog" => {
          "repository_root" => "/catalog",
          "project_state" => @package.dig("provenance", "nodes", "current_project_state"),
          "roles" => @package.dig("transition", "current_roles")
        }
      }
    end

    # Bind a fixture file for the simulated owner response; filesystem errors propagate.
    def binding(path)
      {"sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => File.size(path)}
    end

    def option(argv, name) = argv.fetch(argv.index(name) + 1)

    def write(path, document)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, JSON.pretty_generate(document) + "\n")
    end

    def result(document, code = 0)
      Result.new(stdout: JSON.pretty_generate(document) + "\n", stderr: "", status: Status.new(code))
    end
  end

  def test_clean_standing_release_reaches_one_gate_and_reports_exact_persistence
    with_front_door(input: "APPROVE\n") do |door, runner, output, paths|
      assert_equal 0, door.run(inputs_path: paths[:inputs], package_path: paths[:package],
                               approver: "David Norris", operation_dir: paths[:operation])
      assert_equal 1, runner.calls.count { |call| call[0, 2] == ["af-final-release-adoption", "approve"] }
      assert_equal 1, runner.calls.count { |call| call[0, 2] == ["af-final-release-adoption", "adopt"] }
      assert_includes output.string, "Pipeline readiness: READY"
      assert_includes output.string, "Scoring completeness: FULL"
      assert_includes output.string, "standing directive 4/4; individual human 0/4; IG-16B machine 0/4"
      assert_includes output.string, "historical V1 mechanical 0/4"
      assert_includes output.string, "human HOLD 0; human REJECT 0; source holds 0"
      assert_includes output.string, "Role change: catalog_head only"
      assert_includes output.string, "git add PROJECT_STATE.yml 5e_Adventure_Master_Catalog_8.0.xlsx"
      refute_includes output.string, "Record\\ declined"
      refute_includes output.string, "git add ."
      refute_includes output.string, "unrelated.txt"
      coordination = JSON.parse(File.binread(File.join(paths[:operation], "coordination-decision.json")))
      assert_equal "2026-10-12T01:30:00.000000Z", coordination.fetch("decided_at_utc")
      assert_equal "David Norris", coordination.fetch("decided_by")
    end
  end

  def test_ready_release_with_terminal_gaps_reaches_gate_without_ig17f_producer
    package = fixture_package(full_scoring: false, gaps: 1)
    with_front_door(package:, input: "APPROVE\n") do |door, runner, output, paths|
      assert_equal 0, door.run(inputs_path: paths[:inputs], package_path: paths[:package],
                               approver: "David Norris", operation_dir: paths[:operation])
      assert_includes output.string, "AUTHORIZED RELEASE WITH GAPS"
      assert_includes output.string, "Optional IG-17F continuation: unavailable"
      assert_includes output.string, "Promotion may continue under the package's independently validated terminal-gap authority."
      assert runner.calls.any? { |call| call[0, 2] == ["af-final-release-adoption", "adopt"] }
    end
  end

  def test_returned_frontier_result_is_attributed_to_newly_validated_package
    package = fixture_package(full_scoring: false, gaps: 1)
    package["candidate"]["selection"] = "ig17f_derived"
    package["candidate"]["frontier"] = {
      "result_id" => "f" * 64, "disposition" => "APPLIED", "writes" => 1,
      "no_writes" => 0, "authority" => "frontier_manual"
    }
    with_front_door(package:, input: "APPROVE\n") do |door, _runner, output, paths|
      assert_equal 0, door.run(inputs_path: paths[:inputs], package_path: paths[:package],
                               approver: "David Norris", operation_dir: paths[:operation])
      assert_includes output.string, "Optional frontier result: APPLIED #{'f' * 64}"
      assert_includes output.string, "independently revalidated in this new package"
    end
  end

  def test_owner_validated_human_and_machine_acceptance_remain_separate
    package = fixture_package
    package["release"]["counts"].merge!(
      "standing_directive_accepted" => 2,
      "individual_human_accepted" => 1,
      "ig16b_machine_accepted" => 1
    )
    with_front_door(package:, input: "APPROVE\n") do |door, _runner, output, paths|
      assert_equal 0, door.run(inputs_path: paths[:inputs], package_path: paths[:package],
                               approver: "David Norris", operation_dir: paths[:operation])
      assert_includes output.string, "standing directive 2/4; individual human 1/4; IG-16B machine 1/4"
    end
  end

  def test_missing_approval_stops_before_decision_and_catalog_mutation
    with_front_door(input: "") do |door, runner, output, paths|
      assert_equal 3, door.run(inputs_path: paths[:inputs], package_path: paths[:package],
                               approver: "David Norris", operation_dir: paths[:operation])
      refute runner.calls.any? { |call| %w[approve decline adopt].include?(call[1]) }
      assert_includes output.string, "No approval recorded."
      assert_includes output.string, "Catalog state is unchanged."
      assert_includes output.string, "git add operations/final-promotions/#{'a' * 64}/adoption-request.json"
      refute_includes output.string, "adoption-decision.json"
    end
  end

  # A versionless AFDP base reference must render and replay without granting
  # approval. Exact fixture inputs and request bytes remain unchanged.
  def test_versionless_original_base_review_preserves_exact_unapproved_request
    package = fixture_package
    with_front_door(package:, input: "") do |door, runner, output, paths|
      before = Marshal.dump(package)
      inputs = [paths[:inputs], paths[:package]].to_h { |path| [path, File.binread(path)] }
      request_path = File.join(paths[:operation], "adoption-request.json")
      request_bytes = nil
      2.times do
        assert_equal 3, door.run(inputs_path: paths[:inputs], package_path: paths[:package],
                                 approver: "David Norris", operation_dir: paths[:operation])
        request_bytes ||= File.binread(request_path)
        assert_equal request_bytes, File.binread(request_path)
        inputs.each { |path, bytes| assert_equal bytes, File.binread(path) }
        %w[adoption-decision.json coordination-decision.json adoption-result.json].each do |name|
          refute File.exist?(File.join(paths[:operation], name)), name
        end
      end
      assert_equal before, Marshal.dump(package)
      assert_includes output.string, "Original frozen base: 5e_Adventure_Master_Catalog_7.5.1.xlsx sha256=#{'1' * 64} bytes=80"
      assert_includes output.string, "Current catalog_head: 7.5.1 5e_Adventure_Master_Catalog_7.5.1.xlsx sha256=#{'1' * 64} bytes=80"
      assert_includes output.string, "Finalized candidate: 8.0 5e_Adventure_Master_Catalog_8.0.xlsx sha256=#{'b' * 64} bytes=99"
      assert_includes output.string, "Catalog delta: +1 / -0 IDs; 1 existing IDs (1 cells) changed"
      %w[matcher_authorized_baseline production_dependency_floor].each do |role|
        assert_includes output.string, "#{role}: unchanged (6.0 5e_Adventure_Master_Catalog_6.0.xlsx sha256=#{'2' * 64} bytes=80)"
      end
      assert_equal 2, output.string.scan("No approval recorded.").length
      assert_equal 1, runner.calls.count { |call| call[0, 2] == ["af-final-release-adoption", "prepare"] }
      refute runner.calls.any? { |call| %w[approve decline adopt].include?(call[1]) }
    end
  end

  # Missing base artifact fields still raise KeyError before any decision;
  # only the absent version is permitted by the original-base contract.
  def test_original_base_review_requires_filename_hash_and_byte_count
    %w[filename sha256 bytes].each do |field|
      package = fixture_package
      package.fetch("transition").fetch("original_frozen_base").delete(field)
      with_front_door(package:, input: "APPROVE\n") do |door, runner, _output, paths|
        error = assert_raises(KeyError) do
          door.run(inputs_path: paths[:inputs], package_path: paths[:package],
                   approver: "David Norris", operation_dir: paths[:operation])
        end
        assert_equal field, error.key
        refute runner.calls.any? { |call| %w[approve decline adopt].include?(call[1]) }
      end
    end
  end

  # Versioned role and candidate identities retain their required version;
  # the base-only display fix must not add a general missing-version fallback.
  def test_role_and_candidate_identity_formatting_still_requires_version
    package = fixture_package
    transition = package.fetch("transition")
    identities = transition.fetch("current_roles").values + [transition.fetch("proposed_catalog_head")]
    with_front_door(package:, input: "") do |door, _runner, _output, _paths|
      identities.each do |value|
        error = assert_raises(KeyError) { door.send(:identity, value.except("version")) }
        assert_equal "version", error.key
      end
    end
  end

  def test_decline_is_durable_and_does_not_observe_a_promotion
    with_front_door(input: "DECLINE\n") do |door, runner, output, paths|
      assert_equal 3, door.run(inputs_path: paths[:inputs], package_path: paths[:package],
                               approver: "David Norris", operation_dir: paths[:operation])
      assert runner.calls.any? { |call| call[0, 2] == ["af-final-release-adoption", "decline"] }
      refute runner.calls.any? { |call| call[0] == "af-project-state" }
      assert_includes output.string, "Final promotion: DECLINED"
      %w[adoption-decision.json coordination-decision.json adoption-result.json].each do |name|
        assert File.file?(File.join(paths.fetch(:operation), name)), name
      end
    end
  end

  def test_decision_exit_must_match_the_exact_disposition_contract
    with_front_door(input: "DECLINE\n", decision_exit: 2) do |door, runner, _output, paths|
      error = assert_raises(AdventureFinderWorkspace::Error) do
        door.run(inputs_path: paths[:inputs], package_path: paths[:package],
                 approver: "David Norris", operation_dir: paths[:operation])
      end
      assert_includes error.message, "pipeline final-promotion decision failed"
      refute runner.calls.any? { |call| call[1] == "adopt" }
    end

    with_front_door(input: "APPROVE\n", decision_exit: 3) do |door, runner, _output, paths|
      error = assert_raises(AdventureFinderWorkspace::Error) do
        door.run(inputs_path: paths[:inputs], package_path: paths[:package],
                 approver: "David Norris", operation_dir: paths[:operation])
      end
      assert_includes error.message, "pipeline final-promotion decision failed"
      refute runner.calls.any? { |call| call[1] == "adopt" }
    end
  end

  def test_decline_decision_rejects_malformed_json_and_wrong_identity
    with_front_door(input: "DECLINE\n", decision_stdout: "{not-json\n") do |door, runner, _output, paths|
      error = assert_raises(AdventureFinderWorkspace::Error) do
        door.run(inputs_path: paths[:inputs], package_path: paths[:package],
                 approver: "David Norris", operation_dir: paths[:operation])
      end
      assert_includes error.message, "pipeline adoption decision returned invalid JSON"
      refute runner.calls.any? { |call| call[1] == "adopt" }
    end

    transform = ->(decision) { decision.merge("decided_by" => "Different Operator") }
    with_front_door(input: "DECLINE\n", decision_transform: transform) do |door, runner, _output, paths|
      error = assert_raises(AdventureFinderWorkspace::Error) do
        door.run(inputs_path: paths[:inputs], package_path: paths[:package],
                 approver: "David Norris", operation_dir: paths[:operation])
      end
      assert_includes error.message, "does not preserve the exact operator disposition and identity"
      refute runner.calls.any? { |call| call[1] == "adopt" }
    end
  end

  def test_owner_revalidation_failure_after_display_is_a_focused_gate
    with_front_door(input: "APPROVE\n", fail_adopt: true) do |door, _runner, output, paths|
      error = assert_raises(AdventureFinderWorkspace::Error) do
        door.run(inputs_path: paths[:inputs], package_path: paths[:package],
                 approver: "David Norris", operation_dir: paths[:operation])
      end
      assert_includes output.string, "AdventureFinder final-promotion review"
      assert_includes error.message, "pipeline final-release adoption failed: stale package"
    end
  end

  def test_restart_reuses_exact_durable_decision_without_manufacturing_approval
    with_front_door(input: "APPROVE\n") do |door, runner, _output, paths|
      assert_equal 0, door.run(inputs_path: paths[:inputs], package_path: paths[:package],
                               approver: "David Norris", operation_dir: paths[:operation])
      calls_after_first = runner.calls.length
      replay_output = StringIO.new
      replay = build_door(paths, runner, input: "", output: replay_output)
      assert_equal 0, replay.run(inputs_path: paths[:inputs], package_path: paths[:package],
                                 approver: "David Norris", operation_dir: paths[:operation])
      replay_calls = runner.calls.drop(calls_after_first)
      refute replay_calls.any? { |call| call[1] == "prepare" }
      refute replay_calls.any? { |call| %w[approve decline].include?(call[1]) }
      assert replay_calls.any? { |call| call[1] == "adopt" }
    end
  end

  def test_restart_before_decision_reuses_request_but_pipeline_revalidates_on_approval
    with_front_door(input: "") do |door, runner, _output, paths|
      assert_equal 3, door.run(inputs_path: paths[:inputs], package_path: paths[:package],
                               approver: "David Norris", operation_dir: paths[:operation])
      calls_after_prepare = runner.calls.length
      resumed = build_door(paths, runner, input: StringIO.new("APPROVE\n"), output: StringIO.new)
      assert_equal 0, resumed.run(inputs_path: paths[:inputs], package_path: paths[:package],
                                  approver: "David Norris", operation_dir: paths[:operation])
      resumed_calls = runner.calls.drop(calls_after_prepare)
      refute resumed_calls.any? { |call| call[1] == "prepare" }
      assert resumed_calls.any? { |call| call[1] == "approve" }
      assert resumed_calls.any? { |call| call[1] == "adopt" }
    end
  end

  def test_blocked_package_never_prepares_an_adoption_request
    package = fixture_package
    package["readiness"]["ready"] = false
    package["readiness"]["reasons"] = [{"code" => "STALE", "detail" => "synthetic"}]
    with_front_door(package:, input: "APPROVE\n") do |door, runner, output, paths|
      assert_equal 2, door.run(inputs_path: paths[:inputs], package_path: paths[:package],
                               approver: "David Norris", operation_dir: paths[:operation])
      assert_equal [["af-final-release-package", "validate"]], runner.calls.map { |call| call[0, 2] }
      assert_includes output.string, "Final promotion: BLOCKED"
    end
  end

  def test_preview_is_inspected_only_when_requested_and_never_adds_an_approval
    Dir.mktmpdir("final-promotion-preview-") do |root|
      release_dir = File.join(root, "release")
      FileUtils.mkdir_p(release_dir)
      preview = File.join(release_dir, "preview.xlsx")
      File.binwrite(preview, "synthetic preview")
      manifest = File.join(release_dir, "release-accounting.json")
      binding = {"filename" => "preview.xlsx", "sha256" => Digest::SHA256.file(preview).hexdigest,
                 "bytes" => File.size(preview)}
      File.binwrite(manifest, JSON.generate("artifacts" => {"explicit_red_cell_preview" => binding}))
      package = fixture_package
      package["release"]["preview"] = {"requested" => true, "available" => true, "authority_effect" => "none"}
      package["provenance"]["nodes"]["release_manifest"] = {"path" => manifest}
      with_front_door(root:, package:, input: "APPROVE\n") do |door, runner, output, paths|
        assert_equal 0, door.run(inputs_path: paths[:inputs], package_path: paths[:package],
                                 approver: "David Norris", operation_dir: paths[:operation], preview: true)
        assert_includes output.string, preview
        assert_equal 1, runner.calls.count { |call| call[1] == "approve" }
      end
    end
  end

  def test_pipeline_root_defaults_under_configured_component_root
    Dir.mktmpdir("final-promotion-roots-") do |root|
      prior_pipeline_root = ENV.delete("AF_DATA_PIPELINE_ROOT")
      package = fixture_package
      paths = workspace_paths(root, package)
      runner = OwnerRunner.new(package:)
      output = StringIO.new
      door = AdventureFinderWorkspace::FinalPromotion.new(
        front_door_root: paths.fetch(:front_door), project_root: paths.fetch(:components),
        component_runner: runner, input: StringIO.new("APPROVE\n"), out: output,
        clock: -> { Time.utc(2026, 10, 12, 1, 30, 0) }
      )

      assert_equal 0, door.run(inputs_path: paths[:inputs], package_path: paths[:package],
                               approver: "David Norris", operation_dir: paths[:operation])
      assert runner.calls.all? { |call| call[3] == paths.fetch(:pipeline) }
    ensure
      ENV["AF_DATA_PIPELINE_ROOT"] = prior_pipeline_root if prior_pipeline_root
    end
  end


  # Reproduce the live-manifest rejection after promotion. A new front door must
  # call only the owner replay and observation, preserving all durable bytes.
  def test_cold_replay_reaches_owner_before_live_preapproval_validation
    with_front_door(input: "APPROVE\n") do |door, runner, output, paths|
      assert_equal 0, door.run(inputs_path: paths[:inputs], package_path: paths[:package], approver: "David Norris")
      before = Dir[File.join(paths[:operation], "*")].to_h { |path| [path, File.binread(path)] }
      runner.reject_live_validation = true
      calls = runner.calls.length
      replay_output = StringIO.new
      replay = build_door(paths, runner, input: StringIO.new, output: replay_output)
      assert_equal 0, replay.run(inputs_path: paths[:inputs], package_path: paths[:package], approver: "David Norris")
      assert_equal [["af-final-release-adoption", "adopt"], ["af-project-state", "validate"]], runner.calls.drop(calls).map { |call| call[0, 2] }
      assert_includes replay_output.string, "Final promotion: ALREADY_PROMOTED."
      refute_includes replay_output.string, "Type APPROVE"
      refute_includes replay_output.string, "Current catalog_head:"
      before.each { |path, bytes| assert_equal bytes, File.binread(path), path }
    end
  end

  # Owner refusal must override the retained success; no success may be cached.
  def test_cold_replay_refuses_owner_failure_despite_retained_promoted_result
    with_front_door(input: "APPROVE\n") do |door, runner, _output, paths|
      door.run(inputs_path: paths[:inputs], package_path: paths[:package], approver: "David Norris", operation_dir: paths[:operation])
      runner.reject_live_validation = true
      runner.fail_replay = true
      output = StringIO.new
      replay = build_door(paths, runner, input: StringIO.new, output:)
      error = assert_raises(AdventureFinderWorkspace::Error) do
        replay.run(inputs_path: paths[:inputs], package_path: paths[:package], approver: "David Norris", operation_dir: paths[:operation])
      end
      assert_includes error.message, "pipeline final-release adoption failed"
      refute_includes output.string, "Final promotion: ALREADY_PROMOTED."
    end
  end

  # A retained decision without completed publication evidence requires explicit
  # recovery. Neither a missing result nor a cached PROMOTED flag can publish.
  def test_cold_replay_rejects_interrupted_or_inconsistent_state_before_adopt
    %w[missing_result missing_request missing_coordination altered_decision replaced_request replaced_package changed_inputs changed_manifest reviewed_manifest wrong_approver].each do |scenario|
      with_front_door(input: "APPROVE\n") do |door, runner, _output, paths|
        original_manifest = File.binread(File.join(File.dirname(paths[:inputs]), "PROJECT_STATE.yml"))
        door.run(inputs_path: paths[:inputs], package_path: paths[:package], approver: "David Norris", operation_dir: paths[:operation])
        case scenario
        when "missing_result" then File.unlink(File.join(paths[:operation], "adoption-result.json"))
        when "missing_request" then File.unlink(File.join(paths[:operation], "adoption-request.json"))
        when "missing_coordination" then File.unlink(File.join(paths[:operation], "coordination-decision.json"))
        when "altered_decision" then File.open(File.join(paths[:operation], "adoption-decision.json"), "ab") { |file| file.write(" ") }
        when "replaced_request"
          path = File.join(paths[:operation], "adoption-request.json")
          value = JSON.parse(File.binread(path)); value["request_id"] = "e" * 64
          File.binwrite(path, JSON.generate(value))
        when "replaced_package" then File.open(paths[:package], "ab") { |file| file.write(" ") }
        when "changed_inputs" then File.open(paths[:inputs], "ab") { |file| file.write(" ") }
        when "changed_manifest" then File.open(File.join(File.dirname(paths[:inputs]), "PROJECT_STATE.yml"), "ab") { |file| file.write(" ") }
        when "reviewed_manifest" then File.binwrite(File.join(File.dirname(paths[:inputs]), "PROJECT_STATE.yml"), original_manifest)
        end
        before = runner.calls.length
        replay = build_door(paths, runner, input: StringIO.new("APPROVE\n"), output: StringIO.new)
        assert_raises(AdventureFinderWorkspace::Error, scenario) do
          replay.run(inputs_path: paths[:inputs], package_path: paths[:package], approver: scenario == "wrong_approver" ? "Another operator" : "David Norris", operation_dir: paths[:operation])
        end
        refute runner.calls.drop(before).any? { |call| %w[prepare approve decline adopt].include?(call[1]) }, scenario
      end
    end
  end

  # Missing approval cannot bypass current validation even with serialized success.
  def test_serialized_result_without_approval_keeps_preapproval_validation
    with_front_door(input: "") do |door, runner, _output, paths|
      door.run(inputs_path: paths[:inputs], package_path: paths[:package], approver: "David Norris", operation_dir: paths[:operation])
      File.binwrite(File.join(paths[:operation], "adoption-result.json"), JSON.generate("status" => "PROMOTED"))
      runner.reject_live_validation = true
      before = runner.calls.length
      assert_raises(AdventureFinderWorkspace::Error) do
        door.run(inputs_path: paths[:inputs], package_path: paths[:package], approver: "David Norris", operation_dir: paths[:operation])
      end
      assert_equal [["af-final-release-package", "validate"]], runner.calls.drop(before).map { |call| call[0, 2] }
    end
  end

  private

  def with_front_door(root: nil, package: fixture_package, input:, fail_adopt: false,
                      decision_exit: nil, decision_transform: nil, decision_stdout: nil)
    owned_root = root.nil?
    root ||= Dir.mktmpdir("final-promotion-")
    paths = workspace_paths(root, package)
    runner = OwnerRunner.new(
      package:, fail_adopt:, decision_exit:, decision_transform:, decision_stdout:
    )
    output = StringIO.new
    door = build_door(paths, runner, input: StringIO.new(input), output:)
    yield door, runner, output, paths
  ensure
    FileUtils.remove_entry(root) if owned_root && root && File.directory?(root)
  end

  def build_door(paths, runner, input:, output:)
    AdventureFinderWorkspace::FinalPromotion.new(
      front_door_root: paths.fetch(:front_door), project_root: paths.fetch(:components),
      pipeline_root: paths.fetch(:pipeline), component_runner: runner, input:, out: output,
      clock: -> { Time.utc(2026, 10, 12, 1, 30, 0) }
    )
  end

  def workspace_paths(root, package)
    front_door = File.join(root, "adventure-finder")
    components = File.join(root, "adventure-finder-components")
    pipeline = File.join(components, "af-data-pipeline")
    FileUtils.mkdir_p(File.join(pipeline, "bin"))
    %w[af-final-release-package af-final-release-adoption af-project-state].each do |name|
      path = File.join(pipeline, "bin", name)
      File.binwrite(path, "#!/bin/sh\n")
      FileUtils.chmod(0o755, path)
    end
    FileUtils.mkdir_p(front_door)
    manifest = File.join(root, "PROJECT_STATE.yml")
    File.binwrite(manifest, "reviewed manifest\n")
    package["provenance"]["nodes"]["current_project_state"] = {
      "path" => manifest, "sha256" => Digest::SHA256.file(manifest).hexdigest, "bytes" => File.size(manifest)
    }
    inputs = File.join(root, "inputs.json")
    package_path = File.join(root, "package.json")
    File.binwrite(inputs, "{}\n")
    File.binwrite(package_path, JSON.pretty_generate(package) + "\n")
    {front_door:, components:, pipeline:, inputs:, package: package_path,
     operation: File.join(front_door, "operations", "final-promotions", package.fetch("package_id"))}
  end

  def fixture_package(full_scoring: true, gaps: 0)
    role = lambda do |version, filename, sha|
      {"version" => version, "filename" => filename, "sha256" => sha, "bytes" => 80}
    end
    gap_rows = gaps.times.map do |index|
      {"candidate_key" => "ADV-000#{index + 2}::Seriousness", "category" => "unsupported_scope",
       "reason" => "synthetic unsupported metric", "adventure_id" => "ADV-000#{index + 2}", "dimension" => "Seriousness"}
    end
    intended = 4
    {
      "schema_version" => AdventureFinderWorkspace::FinalPromotion::PACKAGE_SCHEMA,
      "package_id" => "a" * 64,
      "candidate" => {"selection" => "original_ig17", "version" => "8.0", "frontier" => nil,
                      "selected" => {"path" => "/release/final.xlsx", "sha256" => "b" * 64, "bytes" => 99}},
      "release" => {
        "counts" => {"standing_directive_accepted" => intended - gaps, "individual_human_accepted" => 0,
                     "ig16b_machine_accepted" => 0, "historical_mechanical_accepted" => 0,
                     "human_hold" => 0, "human_reject" => 0, "source_holds" => 0,
                     "deferred_or_unsupported" => gaps, "unscored_or_unresolved" => 0},
        "population" => {"intended_cases" => 3, "intended_metrics" => intended, "present_metrics" => intended - gaps,
                         "remaining_blank_metrics" => gaps, "terminal_gap_metrics" => gaps,
                         "residual_gap_metrics" => gaps, "hard_exceptions" => 0,
                         "unresolved_execution_cases" => 0, "conflicting_targets" => 0, "gaps" => gap_rows},
        "preview" => {"requested" => false, "available" => false, "authority_effect" => "none"}
      },
      "transition" => {
        "original_frozen_base" => role.call("7.5.1", "5e_Adventure_Master_Catalog_7.5.1.xlsx", "1" * 64).except("version"),
        "current_roles" => {
          "catalog_head" => role.call("7.5.1", "5e_Adventure_Master_Catalog_7.5.1.xlsx", "1" * 64),
          "matcher_authorized_baseline" => role.call("6.0", "5e_Adventure_Master_Catalog_6.0.xlsx", "2" * 64),
          "production_dependency_floor" => role.call("6.0", "5e_Adventure_Master_Catalog_6.0.xlsx", "2" * 64)
        },
        "proposed_catalog_head" => role.call("8.0", "5e_Adventure_Master_Catalog_8.0.xlsx", "b" * 64).merge("bytes" => 99),
        "delta" => {"added_ids" => ["ADV-0004"], "removed_ids" => [],
                    "changed_cells" => [{"adventure_id" => "ADV-0001", "field" => "Seriousness"}],
                    "concurrent_changes_preserved" => true}
      },
      "compatibility" => {"status" => "PASS", "afw_execution_compatibility" => "not validated by this static workbook gate",
                          "consumer_contracts" => ["pipeline catalog", "static scorer columns"],
                          "canonical_adventure_count" => 4, "mirror_mode" => "mirrored"},
      "scoring_concurrency" => {"decision" => "SAFE_REUSE", "reason" => "UNCHANGED_BASE"},
      "readiness" => {"ready" => true, "full_scoring" => full_scoring, "reasons" => [],
                      "approval_authorized" => false, "catalog_adoption_authorized" => false},
      "provenance" => {"nodes" => {}, "edges" => []}
    }
  end
end
