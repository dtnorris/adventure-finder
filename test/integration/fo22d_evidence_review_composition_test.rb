# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"
require "yaml"

class Fo22dEvidenceReviewCompositionTest < Minitest::Test
  WORKLOAD_ID = "batch"
  JOB_ID = "batch-adv0001-combat"
  ADVENTURE_ID = "ADV-0001"
  DIMENSION = "Combat Emphasis"
  MODEL = "qwen-test"
  SCORER_HEAD = "b" * 40
  STARTED_AT = "2026-10-04T12:00:00Z"
  RECORDED_AT = "2026-10-04T12:01:00Z"
  COMPLETED_AT = "2026-10-04T12:02:00Z"
  ASSESSMENT_HEADERS = %w[
    run_id status review_disposition adventure_id adventure_title source_book book_publisher
    start_page end_page afao_version assessment_spec_version provider model source_file source_scope
    group metric_kind metric assessment_state value range_low range_high confidence path_sensitive
    path_variation_affects_anchor rationale adjacent_lower_reason adjacent_higher_reason evidence
    metric_review_flags package_review_flags
  ].freeze

  def setup
    @source_workspace = ENV["AF_FO22_WORKSPACE_ROOT"]
    skip "set AF_FO22_WORKSPACE_ROOT to the sibling-repository workspace" if @source_workspace.to_s.empty?

    @afw_source = File.join(@source_workspace, "af-workloads")
    @pipeline_source = File.join(@source_workspace, "af-data-pipeline")
    @adventure_finder_source = File.expand_path("../..", __dir__)
    require_source!(File.join(@afw_source, "bin", "afw-bind-scoring-evidence"))
    require_source!(File.join(@pipeline_source, "bin", "af-data"))
    require_source!(File.join(@adventure_finder_source, "bin", "af-review"))

    @root = File.realpath(Dir.mktmpdir("fo22d-composition-"))
    install_component(@afw_source, "af-workloads-production", ["lib", "bin/afw-bind-scoring-evidence"])
    install_component(@pipeline_source, "af-data-pipeline", ["lib", "bin/af-data"])
    build_fixture
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def test_real_public_interfaces_compose_to_pending_human_review_without_canonical_mutation
    before = canonical_bytes
    stdout, stderr, status = run_front_door

    assert status.success?, stderr
    attempt = JSON.parse(File.binread(@metadata_path))
    receipt = JSON.parse(File.binread(@receipt_path))
    package = JSON.parse(File.binread(File.join(@review_dir, "review_package.json")))
    ledger = CSV.read(@ledger_path, headers: true)
    assert_equal 0, attempt.fetch("exit_status")
    assert_equal "afw-scoring-evidence-receipt/v0.1", receipt.fetch("contract_version")
    assert_equal "provenance_validated_proposed_scoring_evidence", receipt.fetch("semantic_status")
    assert_equal 2, receipt.dig("attempt", "attempt")
    assert_equal "af-scoring-review-package/v0.1", package.fetch("contract_version")
    assert_equal 1, ledger.length
    assert_empty ledger.first["editorial_decision"].to_s
    assert_includes stdout, "AFW receipt ID: #{receipt.fetch('receipt_id')}"
    assert_includes stdout, "AFW receipt: #{File.realpath(@receipt_path)}"
    assert_includes stdout, "Review package ID: #{package.fetch('package_id')}"
    assert_includes stdout, "Review package: #{@review_dir}"
    assert_includes stdout, "Editorial ledger: #{@audit_dir}"
    assert_includes stdout, "NEXT HUMAN DECISION: edit #{@ledger_path}"
    assert_includes stdout, "Ledger state: pending"
    assert_includes stdout, "Accepted: 0"
    assert_includes stdout, "Pending: 1"
    assert_includes stdout, "choose ACCEPT/HOLD/REJECT"
    refute_match(/assessment accepted|canonical applied|AMC applied/i, stdout)
    assert_equal before, canonical_bytes
    refute_path_exists File.join(@pipeline, "output")
    refute_path_exists File.join(@pipeline, "audits")
  end

  # Exercises the unset-selector compatibility route through both real owners.
  # Returns no value; unexpected process/fixture errors fail the test.
  def test_unset_data_root_preserves_legacy_review_destinations
    select_review_storage(nil)
    stdout, stderr, status = run_front_door
    assert status.success?, stderr
    assert_includes stdout, "Review package: #{@review_dir}"
    assert_includes stdout, "Editorial ledger: #{@audit_dir}"
    assert_path_exists @ledger_path
  end

  # Invalid selectors must leave the complete synthetic workspace unchanged.
  # Restores valid storage and proves recovery; fixture/process errors propagate.
  def test_invalid_private_roots_refuse_without_writes_and_valid_root_recovers
    _stdout, stderr, status = run_afw
    assert status.success?, stderr
    file_root = File.join(@root, "not-a-directory")
    File.binwrite(file_root, "sentinel")
    link_root = File.join(@root, "linked-data")
    File.symlink(@data_root, link_root)
    readonly_root = File.join(@root, "readonly-data")
    FileUtils.mkdir_p(readonly_root)
    File.chmod(0o555, readonly_root)
    invalid = {
      "" => /empty|traversal/,
      "relative-data" => /existing absolute directory/,
      File.join(@root, "missing") => /existing absolute directory/,
      file_root => /existing absolute directory/,
      link_root => /symlink/,
      File.join(@data_root, "..", "private-pipeline-data") => /traversal/,
      @pipeline => /overlaps executable code/,
      @root => /overlaps executable code/,
      readonly_root => /unwritable/
    }
    invalid.each do |data_root, diagnostic|
      before = storage_inventory
      _stdout, stderr, status = run_front_door(data_root:)
      refute status.success?, "accepted invalid private root #{data_root.inspect}"
      assert_match diagnostic, stderr
      assert_equal before, storage_inventory, "invalid root changed durable workspace"
    end
    _stdout, stderr, status = run_front_door
    assert status.success?, stderr
    assert_path_exists @ledger_path
  ensure
    File.chmod(0o755, readonly_root) if readonly_root && File.directory?(readonly_root)
  end

  # Both deterministic destination branches reject escaping links before writes.
  # Returns no value; fixture/process errors propagate.
  def test_symlinked_review_or_audit_destination_refuses_without_writes
    _stdout, stderr, status = run_afw
    assert status.success?, stderr
    outside = File.join(@root, "outside-data")
    FileUtils.mkdir_p(outside)
    File.binwrite(File.join(outside, "sentinel"), "unchanged")
    %w[output audits].each do |branch|
      link = File.join(@data_root, branch)
      File.symlink(outside, link)
      before = storage_inventory
      _stdout, stderr, status = run_front_door
      refute status.success?
      assert_match(/symlink/, stderr)
      assert_equal before, storage_inventory
      File.unlink(link)
    end
    _stdout, stderr, status = run_front_door
    assert status.success?, stderr
  end

  def test_superseded_attempt_artifacts_are_not_current_and_attempt_two_is_bound
    write_archived_attempt(1, status: "failed")
    mutate_json(@request_path) { |request| request["recorded_at"] = "2026-10-04T11:01:00Z" }
    assert_front_door_rejected(/no complete AFSU evidence set/)
    refute_path_exists @review_dir

    mutate_json(@request_path) { |request| request["recorded_at"] = RECORDED_AT }
    stdout, stderr, status = run_front_door
    assert status.success?, stderr
    receipt = JSON.parse(File.binread(@receipt_path))
    assert_equal 2, receipt.dig("attempt", "attempt")
    assert_equal [1], receipt.dig("attempt", "superseded_attempts").map { |row| row.fetch("attempt") }
    assert_includes stdout, "Ledger state: pending"
  end

  def test_attempt_switch_after_selection_is_rejected_before_receipt_persistence
    script = <<~'RUBY'
      require "json"
      require "af_workloads"
      root, wlo, metadata = ARGV
      subject = AFWorkloads::ScoringEvidence.new(root: root, workload_id: "batch", wlo_output: wlo,
                                                 job_id: "batch-adv0001-combat")
      receipt = subject.interpret
      value = JSON.parse(File.binread(metadata))
      value["attempt"] = 3
      File.binwrite(metadata, JSON.pretty_generate(value))
      subject.write(receipt)
    RUBY
    _stdout, stderr, status = run_afw_ruby(script, @metadata_path)
    refute status.success?
    assert_match(/changed after selection/, stderr)
    refute_path_exists @receipt_path
  end

  def test_command_success_with_missing_or_malformed_assessment_fails_before_review
    FileUtils.mv(@assessment_path, "#{@assessment_path}.missing")
    assert_front_door_rejected(/no complete AFSU evidence set/)
    refute_path_exists @review_dir

    rebuild_fixture
    File.binwrite(@assessment_path, "run_id,status\n#{@run_id},PROPOSED\n")
    assert_front_door_rejected(/malformed proposed assessment/)
    refute_path_exists @review_dir
  end

  def test_missing_or_malformed_raw_request_fails_before_review
    FileUtils.mv(@request_path, "#{@request_path}.missing")
    assert_front_door_rejected(/no complete AFSU evidence set/)
    refute_path_exists @review_dir

    rebuild_fixture
    File.binwrite(@request_path, "not json")
    assert_front_door_rejected(/malformed raw request evidence/)
    refute_path_exists @review_dir
  end

  def test_missing_or_malformed_raw_response_fails_before_review
    FileUtils.mv(@response_path, "#{@response_path}.missing")
    assert_front_door_rejected(/no complete AFSU evidence set/)
    refute_path_exists @review_dir

    rebuild_fixture
    File.binwrite(@response_path, "not json")
    assert_front_door_rejected(/malformed raw response evidence/)
    refute_path_exists @review_dir
  end

  def test_wrong_registered_or_wlo_frozen_plan_identity_fails_before_review
    File.open(@plan_path, "ab") { |file| file.write(" ") }
    assert_front_door_rejected(/plan SHA-256 mismatch/)
    refute_path_exists @receipt_path

    rebuild_fixture
    mutate_json(@wlo_plan_path) { |plan| plan["plan_id"] = "different-plan" }
    assert_front_door_rejected(/WLO frozen plan differs/)
    refute_path_exists @review_dir
  end

  def test_wrong_job_or_attempt_identity_fails_before_review
    mutate_json(@metadata_path) { |metadata| metadata["job_id"] = "different-job" }
    assert_front_door_rejected(/not an authoritative terminal success/)

    rebuild_fixture
    mutate_json(@metadata_path) { |metadata| metadata["attempt"] = 0 }
    assert_front_door_rejected(/attempt identity|terminal success/)
    refute_path_exists @review_dir
  end

  def test_wrong_adventure_or_dimension_fails_before_review
    mutate_assessment("adventure_id", "ADV-9999")
    assert_front_door_rejected(/provenance|no complete AFSU evidence set/)

    rebuild_fixture
    mutate_assessment("metric", "Social Interaction")
    assert_front_door_rejected(/provenance|no complete AFSU evidence set/)
    refute_path_exists @review_dir
  end

  def test_scorer_and_source_provenance_mismatches_fail_before_review
    mutate_yaml(@case_path) { |data| data["scorer_commit"] = "c" * 40 }
    assert_front_door_rejected(/scorer_commit/)

    rebuild_fixture
    File.open(@catalog_path, "ab") { |file| file.write("changed") }
    assert_front_door_rejected(/catalog provenance mismatch/)

    rebuild_fixture
    mutate_assessment("source_file", "/wrong/source.md")
    assert_front_door_rejected(/provenance/)
    refute_path_exists @review_dir
  end

  def test_prompt_schema_and_qualified_model_provenance_mismatches_fail_before_review
    mutate_json(@request_path) { |request| request["prompt_sha256"] = "9" * 64 }
    assert_front_door_rejected(/raw request provenance/)

    rebuild_fixture
    mutate_yaml(@case_path) { |data| data["qualified_model_digest"] = "c" * 64 }
    assert_front_door_rejected(/qualified_model_digest/)
    refute_path_exists @review_dir
  end

  def test_bound_evidence_modified_after_selection_is_detected
    script = <<~'RUBY'
      require "af_workloads"
      root, wlo, response = ARGV
      subject = AFWorkloads::ScoringEvidence.new(root: root, workload_id: "batch", wlo_output: wlo,
                                                 job_id: "batch-adv0001-combat")
      receipt = subject.interpret
      File.open(response, "ab") { |file| file.write(" ") }
      subject.write(receipt)
    RUBY
    _stdout, stderr, status = run_afw_ruby(script, @response_path)
    refute status.success?
    assert_match(/changed after selection/, stderr)
    refute_path_exists @receipt_path
  end

  def test_modified_receipt_or_referenced_artifact_is_rejected_by_pipeline
    stdout, stderr, status = run_afw
    assert status.success?, stderr
    assert_match(/Evidence receipt:/, stdout)
    mutate_json(@receipt_path) { |receipt| receipt["workload"]["pool_id"] = "tampered-pool" }
    _stdout, pipeline_stderr, pipeline_status = run_pipeline
    refute pipeline_status.success?
    assert_match(/receipt identity mismatch/, pipeline_stderr)
    refute_path_exists @review_dir

    rebuild_fixture
    _stdout, stderr, status = run_afw
    assert status.success?, stderr
    File.open(@response_path, "ab") { |file| file.write("changed") }
    _stdout, pipeline_stderr, pipeline_status = run_pipeline
    refute pipeline_status.success?
    assert_match(/digest mismatch/, pipeline_stderr)
    refute_path_exists @review_dir
  end

  def test_existing_review_package_conflict_fails_closed
    _stdout, stderr, status = run_front_door
    assert status.success?, stderr
    File.binwrite(File.join(@review_dir, "review_package.json"), "{}\n")
    assert_front_door_rejected(/existing review package conflicts/)
  end

  def test_tampered_human_ledger_fails_without_overwrite
    _stdout, stderr, status = run_front_door
    assert status.success?, stderr
    table = CSV.read(@ledger_path, headers: true)
    table.first["proposed_value"] = "999"
    write_ledger(table)
    tampered = File.binread(@ledger_path)

    assert_front_door_rejected(/immutable ledger field proposed_value changed/)
    assert_equal tampered, File.binread(@ledger_path)
  end

  %w[ACCEPT HOLD REJECT].each do |decision|
    define_method("test_#{decision.downcase}_decision_survives_complete_front_door_reprepare") do
      _stdout, stderr, status = run_front_door
      assert status.success?, stderr
      table = CSV.read(@ledger_path, headers: true)
      table.first["editorial_decision"] = decision
      table.first["editorial_note"] = "reviewed evidence" unless decision == "ACCEPT"
      write_ledger(table)
      ledger_before = File.binread(@ledger_path)
      package_before = package_bytes

      stdout, stderr, status = run_front_door
      assert status.success?, stderr
      assert_equal ledger_before, File.binread(@ledger_path)
      assert_equal package_before, package_bytes
      assert_includes stdout, "Ledger state: decided"
      assert_includes stdout, "Pending: 0"
      assert_includes stdout, "NEXT HUMAN DECISION: none"
      assert_includes stdout, "#{decision == 'ACCEPT' ? 'Accepted' : decision == 'HOLD' ? 'Held' : 'Rejected'}: 1"
    end
  end

  def test_repeated_complete_preparation_is_byte_idempotent_and_preserves_canonical_targets
    canonical_before = canonical_bytes
    first_stdout, first_stderr, first_status = run_front_door
    assert first_status.success?, first_stderr
    receipt_before = File.binread(@receipt_path)
    package_before = package_bytes
    ledger_before = File.binread(@ledger_path)
    inventory_before = storage_inventory

    second_stdout, second_stderr, second_status = run_front_door
    assert second_status.success?, second_stderr
    assert_equal receipt_before, File.binread(@receipt_path)
    assert_equal package_before, package_bytes
    assert_equal ledger_before, File.binread(@ledger_path)
    assert_equal canonical_before, canonical_bytes
    assert_equal inventory_before, storage_inventory
    assert_equal first_stdout[/AFW receipt ID: ([0-9a-f]{64})/, 1], second_stdout[/AFW receipt ID: ([0-9a-f]{64})/, 1]
    assert_equal first_stdout[/Review package ID: ([0-9a-f]{64})/, 1], second_stdout[/Review package ID: ([0-9a-f]{64})/, 1]
    assert_includes second_stdout, "Package reused: true"
  end

  # Uses real owner code in a renamed disposable checkout and a detached CLI.
  # Cold replay must retain exact pending evidence without touching code/targets.
  def test_logical_dual_checkout_and_detached_front_door_cold_replay
    logical_code = File.join(@root, "development-components", "af-pipeline")
    FileUtils.mkdir_p(File.dirname(logical_code))
    FileUtils.mv(@pipeline, logical_code)
    @pipeline = logical_code
    logical_data = File.join(@root, "af-pipeline-data")
    FileUtils.mv(@data_root, logical_data)
    select_review_storage(logical_data)
    detached = File.join(@root, "detached-front-door")
    install_component(@adventure_finder_source, "detached-front-door", ["lib", "bin/af-review"])
    @adventure_finder_source = detached
    # An unrelated conventional checkout must never override an explicit root.
    FileUtils.mkdir_p(File.join(@root, "af-data-pipeline"))
    File.binwrite(File.join(@root, "af-data-pipeline", "sentinel"), "unrelated checkout")

    stdout, stderr, status = run_front_door(pipeline_root: logical_code)
    assert status.success?, stderr
    assert_includes stdout, "Review package: #{@review_dir}"
    assert_includes stdout, "Ledger state: pending"
    before = storage_inventory
    stdout, stderr, status = run_front_door(pipeline_root: logical_code)
    assert status.success?, stderr
    assert_includes stdout, "Package reused: true"
    assert_equal before, storage_inventory
    refute_path_exists File.join(logical_code, "output")
    refute_path_exists File.join(logical_code, "audits")
  end

  # Invalid explicit code roots cannot fall back to the valid conventional
  # checkout or bind new evidence. Restoration proves the positive path remains.
  def test_invalid_explicit_code_roots_fail_without_fallback_or_owner_writes
    unrelated = File.join(@root, "unrelated-code")
    FileUtils.mkdir_p(unrelated)
    linked = File.join(@root, "linked-code")
    File.symlink(@pipeline, linked)
    ["", "relative-code", File.join(@root, "missing-code"), unrelated, linked,
     File.join(@pipeline, "..", "af-data-pipeline")].each do |pipeline_root|
      before = storage_inventory
      _stdout, stderr, status = run_front_door(pipeline_root:)
      refute status.success?, "accepted invalid code root #{pipeline_root.inspect}"
      assert_match(/pipeline|AF_DATA_PIPELINE_ROOT/, stderr)
      assert_equal before, storage_inventory
    end
    _stdout, stderr, status = run_front_door(pipeline_root: @pipeline)
    assert status.success?, stderr
  end

  private

  def require_source!(path)
    raise "required FO-22 sibling source is missing: #{path}" unless File.file?(path)
  end

  def install_component(source, name, entries)
    destination = File.join(@root, name)
    FileUtils.mkdir_p(destination)
    entries.each do |entry|
      source_path = File.join(source, entry)
      destination_path = File.join(destination, entry)
      FileUtils.mkdir_p(File.dirname(destination_path))
      if File.directory?(source_path)
        FileUtils.cp_r(source_path, destination_path)
      else
        FileUtils.cp(source_path, destination_path, preserve: true)
      end
    end
  end

  def rebuild_fixture
    FileUtils.remove_entry(@root)
    FileUtils.mkdir_p(@root)
    install_component(@afw_source, "af-workloads-production", ["lib", "bin/afw-bind-scoring-evidence"])
    install_component(@pipeline_source, "af-data-pipeline", ["lib", "bin/af-data"])
    build_fixture
  end

  def build_fixture
    @afw = File.join(@root, "af-workloads-production")
    @pipeline = File.join(@root, "af-data-pipeline")
    @wlo_root = File.join(@root, "workload-orchestrator-production")
    @wlo = File.join(@wlo_root, "output", WORKLOAD_ID)
    @run_id = "20261004T120100Z_deadbeef"
    %w[workloads/batch build/workloads/batch/cases build/workloads/batch/runtime
       build/workloads/batch/preflight input output/workloads/batch/results/batch-adv0001-combat/assessments].each do |path|
      FileUtils.mkdir_p(File.join(@afw, path))
    end
    FileUtils.mkdir_p(File.join(@wlo, "runs", JOB_ID))
    @plan_path = File.join(@afw, "workloads/batch/execution-plan.json")
    @snapshot_path = File.join(@afw, "workloads/batch/snapshot.yml")
    @case_index_path = File.join(@afw, "workloads/batch/case_index.csv")
    @case_path = File.join(@afw, "build/workloads/batch/cases/#{JOB_ID}.yml")
    @preflight_path = File.join(@afw, "build/workloads/batch/preflight/#{JOB_ID}.json")
    @runtime_path = File.join(@afw, "build/workloads/batch/runtime/#{JOB_ID}.yml")
    @catalog_path = File.join(@afw, "input/catalog.xlsx")
    @qualification_path = File.join(@afw, "input/qualification.yml")
    @metadata_path = File.join(@wlo, "runs", JOB_ID, "metadata.json")
    @wlo_plan_path = File.join(@wlo, "plan.json")
    @source_file = File.join(@afw, "input/source.md")
    @output = File.join(@afw, "output/workloads/batch/results", JOB_ID)
    @receipt_path = File.join(@afw, "output/workloads/batch/evidence/#{JOB_ID}.json")
    data_root = File.join(@root, "private-pipeline-data")
    FileUtils.mkdir_p(data_root)
    select_review_storage(data_root)

    File.binwrite(@catalog_path, "catalog\n")
    File.binwrite(@qualification_path, "qualification\n")
    File.binwrite(@runtime_path, "--- {}\n")
    File.binwrite(@source_file, "source\n")
    build_preflight_and_case
    build_plan_and_context
    build_attempt
    build_scoring_artifacts
    build_canonical_sentinels
  end

  def build_preflight_and_case
    preflight = {
      "adventure_id" => ADVENTURE_ID,
      "run_metadata" => {
        "run_id" => "preflight", "adventure_id" => ADVENTURE_ID,
        "selected_dimension" => DIMENSION, "provider" => "ollama", "model" => MODEL,
        "source_file" => @source_file, "source_scope" => "bounded",
        "afao_version" => "1.6.1", "assessment_spec_version" => "0.1"
      },
      "targets" => [{
        "artifact_name" => "dimension_combat_emphasis",
        "prompt_sha256" => "1" * 64, "schema_sha256" => "2" * 64
      }]
    }
    File.binwrite(@preflight_path, JSON.pretty_generate(preflight))
    case_data = {
      "contract_version" => "afw-workload/v0.1", "workload_id" => WORKLOAD_ID,
      "case_id" => JOB_ID, "adventure_id" => ADVENTURE_ID, "dimension" => DIMENSION,
      "profile" => "production", "model_alias" => "qwen", "ollama_model" => MODEL,
      "qualified_model_digest" => "a" * 64,
      "catalog_path" => relative_afw(@catalog_path), "catalog_sha256" => digest(@catalog_path),
      "qualification_path" => relative_afw(@qualification_path),
      "qualification_sha256" => digest(@qualification_path),
      "runtime_path" => relative_afw(@runtime_path), "runtime_sha256" => digest(@runtime_path),
      "preflight_path" => relative_afw(@preflight_path), "preflight_sha256" => digest(@preflight_path),
      "scorer_repo" => "../af-cli-scoring-utility", "scorer_commit" => SCORER_HEAD,
      "output_path" => relative_afw(@output), "environment" => { "AF_LLM_PROVIDER" => "ollama" }
    }
    File.binwrite(@case_path, YAML.dump(case_data))
  end

  def build_plan_and_context
    case_data = YAML.safe_load_file(@case_path)
    plan = {
      "contract_version" => "wlo-execution-plan/v0.3", "plan_id" => WORKLOAD_ID,
      "failure_policy" => { "max_consecutive_failures" => 2, "max_total_failures" => 3 },
      "pools" => [{ "pool_id" => "qwen", "requirements" => { "ollama" => { "model" => MODEL } } }],
      "jobs" => [{
        "job_id" => JOB_ID, "pool_id" => "qwen", "group_id" => ADVENTURE_ID,
        "argv" => ["bin/afw-score-job", relative_afw(@case_path)], "env" => case_data.fetch("environment"),
        "depends_on_job_ids" => []
      }]
    }
    plan_bytes = JSON.pretty_generate(plan) + "\n"
    File.binwrite(@plan_path, plan_bytes)
    File.binwrite(@wlo_plan_path, plan_bytes)
    File.binwrite(@snapshot_path, YAML.dump(
      "contract_version" => "afw-workload/v0.1", "workload_id" => WORKLOAD_ID,
      "scorer_commit" => SCORER_HEAD, "execution_plan_sha256" => Digest::SHA256.hexdigest(plan_bytes)
    ))
    write_csv(@case_index_path,
              %w[case_id adventure_id dimension profile model_alias ollama_model qualified_model_digest
                 qualification_sha256 runtime_sha256 preflight_sha256 case_path],
              [[JOB_ID, ADVENTURE_ID, DIMENSION, "production", "qwen", MODEL, "a" * 64,
                digest(@qualification_path), digest(@runtime_path), digest(@preflight_path), relative_afw(@case_path)]])
    @registry_path = File.join(@root, "contexts.yml")
    registry = {
      "schema_version" => "adventurefinder-production-context/v0.1",
      "contexts" => {
        "batch" => {
          "39" => {
            "production_batch_id" => WORKLOAD_ID,
            "afw" => {
              "repository_root" => "af-workloads-production",
              "workload_root" => "af-workloads-production/workloads/batch",
              "plan_path" => "af-workloads-production/workloads/batch/execution-plan.json"
            },
            "wlo" => {
              "repository_root" => "workload-orchestrator-production",
              "output_root" => "workload-orchestrator-production/output/batch"
            },
            "plan" => {
              "plan_id" => WORKLOAD_ID, "sha256" => Digest::SHA256.hexdigest(plan_bytes),
              "authority" => "FO-22D synthetic fixture"
            },
            "associated_fleets" => []
          }
        },
        "fleet" => {}
      }
    }
    File.binwrite(@registry_path, YAML.dump(registry))
    @manifest_path = File.join(@root, "repos.yml")
    File.binwrite(@manifest_path, YAML.dump(
      "schema_version" => "adventurefinder-workspace/v0.1", "workspace_root_default" => @root,
      "repositories" => [{
        "name" => "af-data-pipeline", "github" => "dtnorris/af-data-pipeline",
        "role" => "review", "lifecycle" => "current", "default" => true
      }]
    ))
  end

  def build_attempt
    File.binwrite(@metadata_path, JSON.pretty_generate(
      "job_id" => JOB_ID, "pool_id" => "qwen", "worker" => "worker-1", "status" => "complete",
      "attempt" => 2, "started_at" => STARTED_AT, "completed_at" => COMPLETED_AT,
      "elapsed_seconds" => 120.0, "exit_status" => 0,
      "argv" => ["bin/afw-score-job", relative_afw(@case_path)], "environment_keys" => ["AF_LLM_PROVIDER"],
      "worker_execution_identity" => "worker-exec-1", "worker_registry_binding" => { "revision" => 1 }
    ))
  end

  def build_scoring_artifacts
    @assessment_path = File.join(@output, "assessments", "#{ADVENTURE_ID}_#{@run_id}.csv")
    values = {
      "run_id" => @run_id, "status" => "PROPOSED", "review_disposition" => "REVIEW_REQUIRED",
      "adventure_id" => ADVENTURE_ID, "adventure_title" => "Fixture", "source_book" => "Book",
      "book_publisher" => "Publisher", "start_page" => "1", "end_page" => "2",
      "afao_version" => "1.6.1", "assessment_spec_version" => "0.1", "provider" => "ollama",
      "model" => MODEL, "source_file" => @source_file, "source_scope" => "bounded",
      "group" => "combat", "metric_kind" => "integer", "metric" => DIMENSION,
      "assessment_state" => "scored", "value" => "3", "confidence" => "0.9",
      "rationale" => "Fixture evidence supports the proposed value.", "evidence" => "[]"
    }
    write_csv(@assessment_path, ASSESSMENT_HEADERS, [ASSESSMENT_HEADERS.map { |name| values[name] }])
    raw_dir = File.join(@output, "raw", ADVENTURE_ID, @run_id)
    FileUtils.mkdir_p(raw_dir)
    @request_path = File.join(raw_dir, "dimension_combat_emphasis_request.json")
    @response_path = File.join(raw_dir, "dimension_combat_emphasis.json")
    provider_request = {
      "provider" => "ollama", "transport" => { "kind" => "http_post" },
      "payload" => { "model" => MODEL, "messages" => [] }
    }
    File.binwrite(@request_path, JSON.pretty_generate(
      "record_type" => "provider_request", "recorded_at" => RECORDED_AT,
      "recorded_before_inference" => true, "prompt_sha256" => "1" * 64, "schema_sha256" => "2" * 64,
      "request_sha256" => Digest::SHA256.hexdigest(JSON.generate(provider_request)), "request" => provider_request
    ))
    File.binwrite(@response_path, JSON.pretty_generate(
      "choices" => [{ "message" => { "content" => "{}" } }]
    ))
  end

  def build_canonical_sentinels
    @canonical_paths = [
      File.join(@root, "canonical", "AMC.xlsx"),
      File.join(@root, "canonical", "accepted.json"),
      File.join(@root, "canonical", "PROJECT_STATE.yml")
    ]
    @canonical_paths.each do |path|
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, "canonical sentinel: #{File.basename(path)}\n")
    end
  end

  # Runs the public CLI with an explicit DPS-05 selector (nil unsets it).
  # Returns stdout/stderr/process status; OS subprocess errors propagate.
  def run_front_door(data_root: @data_root, pipeline_root: nil)
    Open3.capture3(
      { "AF_PROJECT_ROOT" => @root, "AF_DATA_PIPELINE_DATA_ROOT" => data_root,
        "AF_DATA_PIPELINE_ROOT" => pipeline_root }, RbConfig.ruby,
      File.join(@adventure_finder_source, "bin", "af-review"),
      "prepare", "39", "0001-combat", "--root", @root,
      "--registry", @registry_path, "--manifest", @manifest_path
    )
  end

  def run_afw
    Open3.capture3(
      RbConfig.ruby, File.join(@afw, "bin", "afw-bind-scoring-evidence"),
      WORKLOAD_ID, @wlo, JOB_ID, chdir: @afw
    )
  end

  def run_pipeline
    Open3.capture3(
      { "AF_DATA_PIPELINE_DATA_ROOT" => @data_root },
      RbConfig.ruby, File.join(@pipeline, "bin", "af-data"), "prepare-review", @receipt_path,
      "--afw-root", @afw, "--review-dir", @review_dir, "--audit-dir", @audit_dir,
      chdir: @pipeline
    )
  end

  def run_afw_ruby(script, mutation_path)
    Open3.capture3(
      RbConfig.ruby, "-I", File.join(@afw, "lib"), "-e", script,
      @afw, @wlo, mutation_path, chdir: @afw
    )
  end

  def assert_front_door_rejected(pattern)
    canonical_before = canonical_bytes
    ledger_before = File.binread(@ledger_path) if File.file?(@ledger_path)
    _stdout, stderr, status = run_front_door
    refute status.success?
    assert_match pattern, stderr
    assert_equal canonical_before, canonical_bytes
    if ledger_before
      assert_equal ledger_before, File.binread(@ledger_path)
    else
      refute_path_exists @ledger_path
    end
  end

  def write_archived_attempt(number, status:)
    path = File.join(@wlo, "attempts", JOB_ID, "attempt-#{number}", "metadata.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, JSON.pretty_generate(
      "job_id" => JOB_ID, "attempt" => number, "status" => status, "exit_status" => 1
    ))
  end

  def mutate_assessment(field, value)
    table = CSV.read(@assessment_path, headers: true)
    table.first[field] = value
    write_csv(@assessment_path, table.headers, table.map(&:fields))
  end

  def mutate_json(path)
    value = JSON.parse(File.binread(path))
    yield value
    File.binwrite(path, JSON.pretty_generate(value))
  end

  def mutate_yaml(path)
    value = YAML.safe_load_file(path)
    yield value
    File.binwrite(path, YAML.dump(value))
  end

  def write_csv(path, headers, rows)
    CSV.open(path, "w") do |csv|
      csv << headers
      rows.each { |row| csv << row }
    end
  end

  def write_ledger(table)
    CSV.open(@ledger_path, "w") do |csv|
      csv << table.headers
      table.each { |row| csv << table.headers.map { |header| row[header] } }
    end
  end

  def canonical_bytes
    @canonical_paths.to_h { |path| [path, File.binread(path)] }
  end

  def package_bytes
    Dir.children(@review_dir).sort.to_h { |name| [name, File.binread(File.join(@review_dir, name))] }
  end

  # Selects only synthetic review/audit paths; nil exercises legacy code storage.
  # Returns the ledger path and raises no owner validation errors itself.
  def select_review_storage(data_root)
    @data_root = data_root
    storage_root = data_root || @pipeline
    @review_dir = File.join(storage_root, "output/adventure-finder-review", WORKLOAD_ID, JOB_ID)
    @audit_dir = File.join(storage_root, "audits/adventure-finder-review", WORKLOAD_ID, JOB_ID)
    @ledger_path = File.join(@audit_dir, "editorial_decisions.csv")
  end

  # Inventories synthetic paths without following symlinks. Returns relative
  # paths mapped to type/mode and file digest/mtime or link target; IO errors
  # propagate. Directory mtimes are omitted because owner scratch work is removed.
  def storage_inventory
    Dir.glob(File.join(@root, "**", "*"), File::FNM_DOTMATCH).sort.to_h do |path|
      stat = File.lstat(path)
      value = [stat.ftype, stat.mode]
      value += [digest(path), stat.mtime.to_r.to_s] if stat.file?
      value << File.readlink(path) if stat.symlink?
      [Pathname.new(path).relative_path_from(Pathname.new(@root)).to_s, value]
    end
  end

  def digest(path)
    Digest::SHA256.file(path).hexdigest
  end

  def relative_afw(path)
    Pathname.new(path).relative_path_from(Pathname.new(@afw)).to_s
  end
end
