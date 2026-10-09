# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"
require "yaml"
require "adventure_finder_staged_workload_preparation"

class StagedWorkloadPreparationTest < Minitest::Test
  ID = "11111111-1111-4111-8111-111111111111"
  NOW = Time.iso8601("2026-10-08T20:00:00Z")

  Status = Data.define(:success?, :exitstatus)
  Response = Data.define(:stdout, :stderr, :status)

  class Runner
    attr_reader :calls

    def initialize(authority:, afw_root:, ids:, write_outputs: true, capability_context: 131_072,
                   build_success: true)
      @authority = authority
      @afw_root = afw_root
      @ids = ids
      @write_outputs = write_outputs
      @capability_context = capability_context
      @build_success = build_success
      @calls = []
    end

    def capture(environment, *argv, chdir:)
      @calls << {environment:, argv:, chdir:}
      case File.basename(argv.first)
      when "af-staged-scoring-authority"
        Response.new(JSON.generate(@authority), "", Status.new(true, 0))
      when "afw-build-workload"
        write_workload(argv) if @write_outputs && @build_success
        Response.new("", @build_success ? "" : "Page Count is outside the production envelope\n",
                     Status.new(@build_success, @build_success ? 0 : 2))
      when "afw-verify-staged-workload"
        Response.new("VERIFIED\n", "", Status.new(true, 0))
      else
        raise "unexpected command: #{argv.inspect}"
      end
    end

    private

    def write_workload(argv)
      workload = argv.fetch(argv.index("--workload") + 1)
      manifest = File.join(@afw_root, "workloads", workload)
      FileUtils.mkdir_p(manifest)
      jobs = @ids.flat_map do |id|
        %w[combat social].map do |metric|
          {"job_id" => "#{workload}-#{id.downcase}-#{metric}", "pool_id" => "qwen", "group_id" => id,
           "argv" => ["bin/afw-score-job", "fixture"], "env" => {}, "depends_on_job_ids" => []}
        end
      end
      plan = {
        "contract_version" => "wlo-execution-plan/v0.3", "plan_id" => workload,
        "failure_policy" => {"max_consecutive_failures" => 2, "max_total_failures" => 3},
        "pools" => [{"pool_id" => "qwen", "requirements" => {"ollama" => {
          "model" => "fixture", "expected_digest" => "a" * 64,
          "required_context_length" => @capability_context, "require_fully_gpu_resident" => true
        }}}],
        "jobs" => jobs
      }
      plan_path = File.join(manifest, "execution-plan.json")
      File.write(plan_path, JSON.pretty_generate(plan) + "\n")
      CSV.open(File.join(manifest, "case_index.csv"), "w") do |csv|
        csv << %w[case_id adventure_id dimension]
        jobs.each do |job|
          id = job.fetch("group_id")
          csv << [job.fetch("job_id"), id, job.fetch("job_id").end_with?("combat") ? "Combat Emphasis" : "Social Interaction Emphasis"]
        end
      end
      snapshot = {
        "contract_version" => "afw-workload/v0.1", "workload_id" => workload,
        "execution_plan_sha256" => Digest::SHA256.file(plan_path).hexdigest,
        "adventure_order" => @ids, "case_count" => jobs.length,
        "selected_dimensions" => ["Combat Emphasis", "Social Interaction Emphasis"]
      }
      File.write(File.join(manifest, "snapshot.yml"), YAML.dump(snapshot))
      authority = @authority.fetch("authority")
      binding = {
        "authority_id" => authority.fetch("authority_id"), "operation_id" => ID,
        "workload_id" => workload, "intended_ids" => @ids,
        "schema_version" => "af-staged-scoring-workload-binding/v0.1",
        "staged_amc" => authority.fetch("staged_amc"), "artifacts" => {}
      }
      File.write(File.join(manifest, "staged-scoring.json"), JSON.generate(
        "schema_version" => "afw-staged-scoring-input/v0.1", "validator" => {}, "binding" => binding
      ))
    end
  end

  def setup
    @dir = Dir.mktmpdir("ig14a-preparation")
    @front = directory("front")
    @components = directory("components")
    @pipeline = directory("components/af-data-pipeline")
    @afw = directory("components/af-workloads")
    @scorer = directory("components/af-cli-scoring-utility")
    @source = directory("components/source")
    @catalog_root = directory("catalog")
    @input_root = directory("input")
    executable(File.join(@pipeline, "bin/af-staged-scoring-authority"))
    executable(File.join(@afw, "bin/afw-build-workload"))
    executable(File.join(@afw, "bin/afw-verify-staged-workload"))
    @pdf = write(File.join(@input_root, "book.pdf"), "%PDF synthetic\n")
    @base = write(File.join(@catalog_root, "5e_Adventure_Master_Catalog_1.0.xlsx"), "base\n")
    @staged = write(File.join(@catalog_root, "5e_Adventure_Master_Catalog_1.1.xlsx"), "staged\n")
    @policy = write(File.join(@pipeline, "config/staged_scoring_input_policy_v0.1.json"), JSON.generate(policy_document))
    @operations = AdventureFinderWorkspace::IngestOperationStore.new(
      root: File.join(@front, "operations"),
      roots: {"input" => @input_root, "catalog" => @catalog_root, "pipeline" => @pipeline,
              "source" => @source, "front_door" => @front, "converter" => @components}
    )
    create_operation
    append_editorial_lineage
    @intents = AdventureFinderWorkspace::StagedScoringIntentStore.new(
      root: File.join(@front, "intents"), operation_store: @operations,
      policy_path: @policy, clock: -> { NOW }
    )
    @intents.capture!(operation_id: ID, choice: "prepare", selected_by: "David", interaction: "ingest_start")
    @authorizations = AdventureFinderWorkspace::SuccessorVersionAuthorizationStore.new(
      root: File.join(@front, "successors"), operation_store: @operations, clock: -> { NOW }
    )
    @authorizations.bind!(operation_id: ID, successor_version: "1.1", selected_by: "David")
    @routing = AdventureFinderWorkspace::IngestOperationRouting.new(
      store: @operations, project_root: @components, front_door_root: @front,
      pipeline_root: @pipeline, source_root: @source, catalog_root: @catalog_root
    )
    @freeze = write(File.join(@pipeline, "freeze.yml"), "---\nschema_version: af-boundary-freeze/v0.1\n")
    @approval = write(File.join(@pipeline, "approval.json"), "{}\n")
    @bundle = directory("components/af-data-pipeline/editorial")
    @historical_state = write(File.join(@catalog_root, "HISTORICAL_PROJECT_STATE.yml"), "--- {}\n")
    @current_state = write(File.join(@catalog_root, "PROJECT_STATE.yml"), "--- {}\n")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_multiple_new_ids_prepare_once_and_restart_uses_public_verifier
    ids = %w[ADV-0003 ADV-0004]
    projection = authority_projection(ids)
    runner = Runner.new(authority: projection, afw_root: @afw, ids:)
    service = service(runner)

    first = prepare(service)
    second = prepare(service)

    assert_equal "PREPARED", first.fetch("status")
    assert_equal first, second
    assert_equal ids, first.fetch("selected").map { |row| row.fetch("adventure_id") }
    assert_equal [2, 2], first.fetch("selected").map { |row| row.fetch("case_count") }
    assert_equal 4, first.fetch("qualified_cases")
    assert_equal 4, first.fetch("metric_denominator")
    assert_empty first.fetch("deferred")
    assert_equal 1, runner.calls.count { |call| File.basename(call[:argv].first) == "afw-build-workload" }
    assert_equal 1, runner.calls.count { |call| File.basename(call[:argv].first) == "afw-verify-staged-workload" }

    build = runner.calls.find { |call| File.basename(call[:argv].first) == "afw-build-workload" }.fetch(:argv)
    assert_includes build, "--required-context-length"
    assert_includes build, "131072"
    assert_includes build, "--require-fully-gpu-resident"
    refute_includes build, "--dimension"
    refute_includes build, "--worker"
    refute_includes build, "--required-gpu-id"
  end

  def test_no_new_records_returns_explicit_no_work_without_afw
    zero = {
      "schema_version" => "af-staged-scoring-authority-projection/v0.1",
      "status" => "NO_SUCCESSOR_NEEDED", "authority" => nil,
      "observation" => {"decision" => "SAFE_REUSE"}, "preparation_allowed" => false,
      "execution_authorized" => false, "catalog_adoption_authorized" => false
    }
    runner = Runner.new(authority: zero, afw_root: @afw, ids: [])
    result = prepare(service(runner))

    assert_equal "NO_RUNNABLE_WORK", result.fetch("status")
    assert_empty result.fetch("selected")
    assert_equal 1, result.fetch("deferred").length
    refute runner.calls.any? { |call| File.basename(call[:argv].first).start_with?("afw-") }
  end

  def test_zero_exit_missing_output_and_capability_drift_fail_closed
    ids = ["ADV-0003"]
    projection = authority_projection(ids)
    missing = Runner.new(authority: projection, afw_root: @afw, ids:, write_outputs: false)
    error = assert_raises(AdventureFinderWorkspace::StagedWorkloadPreparation::Failure) do
      prepare(service(missing))
    end
    assert_equal "MISSING_PREPARATION_INPUT", error.code

    FileUtils.remove_entry(File.join(@front, "output", "staged-workload-preparations"))
    drift = Runner.new(authority: projection, afw_root: @afw, ids:, capability_context: 262_144)
    error = assert_raises(AdventureFinderWorkspace::StagedWorkloadPreparation::Failure) do
      prepare(service(drift))
    end
    assert_equal "CAPABILITY_POLICY_MISMATCH", error.code
  end

  def test_afw_refusal_reports_every_authorized_id_as_deferred
    ids = %w[ADV-0003 ADV-0004]
    runner = Runner.new(
      authority: authority_projection(ids), afw_root: @afw, ids:, build_success: false
    )

    error = assert_raises(AdventureFinderWorkspace::StagedWorkloadPreparation::Failure) do
      prepare(service(runner))
    end

    assert_equal "AFW_PREPARATION_REFUSED", error.code
    ids.each { |id| assert_includes error.message, "#{id}=deferred" }
    assert_includes error.message, "Page Count is outside the production envelope"
    refute File.exist?(File.join(@front, "output", "staged-workload-preparations", "v0.1", ID, "result.json"))
  end

  def test_incompatible_pipeline_authority_stops_before_afw
    projection = authority_projection(["ADV-0003"])
    projection.fetch("authority")["permissions"] << "inference"
    projection.fetch("authority")["authority_id"] =
      AdventureFinderWorkspace::StagedScoringIntentStore.digest(projection.fetch("authority").except("authority_id"))
    runner = Runner.new(authority: projection, afw_root: @afw, ids: ["ADV-0003"])

    error = assert_raises(AdventureFinderWorkspace::StagedWorkloadPreparation::Failure) do
      prepare(service(runner))
    end

    assert_equal "INVALID_AUTHORITY", error.code
    refute runner.calls.any? { |call| File.basename(call[:argv].first).start_with?("afw-") }
  end

  private

  def service(runner)
    AdventureFinderWorkspace::StagedWorkloadPreparation.new(
      front_door_root: @front, project_root: @components, pipeline_root: @pipeline,
      afw_root: @afw, scorer_root: @scorer, source_root: @source,
      catalog_root: @catalog_root, operation_store: @operations, intent_store: @intents,
      authorization_store: @authorizations, routing: @routing, runner:
    )
  end

  def prepare(service)
    service.prepare(
      operation_id: ID, freeze_path: @freeze, approval_path: @approval,
      bundle_dir: @bundle, historical_project_state_path: @historical_state,
      current_project_state_path: @current_state
    )
  end

  def authority_projection(ids)
    intent = @intents.intent!(ID)
    authority = {
      "schema_version" => "af-staged-scoring-authority/v0.1", "issuer" => "af-data-pipeline",
      "mode" => "production", "operation" => intent.fetch("operation"), "intent" => intent,
      "permissions" => %w[scoring_input workload_preparation],
      "base_amc" => intent.fetch("base_amc"),
      "staged_amc" => {"filename" => File.basename(@staged),
                        "sha256" => Digest::SHA256.file(@staged).hexdigest, "bytes" => File.size(@staged)},
      "approval_id" => "sha256:" + "b" * 64,
      "allocation" => ids.map { |id| {"adventure_id" => id} },
      "protected_ids" => ids, "evidence" => {}
    }
    authority["authority_id"] = AdventureFinderWorkspace::StagedScoringIntentStore.digest(authority)
    {
      "schema_version" => "af-staged-scoring-authority-projection/v0.1", "authority" => authority,
      "concurrency" => {"decision" => "SAFE_REUSE"}, "workload_frozen" => false,
      "preparation_allowed" => true, "execution_authorized" => false,
      "catalog_adoption_authorized" => false
    }
  end

  def create_operation
    at = NOW.strftime("%Y-%m-%dT%H:%M:%SZ")
    choice = ->(value) { {"value" => value, "selected_by" => "David", "selected_at" => at} }
    @operations.create(
      operation_id: ID, created_at: at,
      input_locator: {"root" => "input", "path" => "book.pdf"},
      base_catalog_locator: {"root" => "catalog", "path" => File.basename(@base)},
      catalog_selected_by: "David", catalog_selected_at: at,
      source_declaration: {
        "source_id" => choice.call("Fixture Source"), "edition" => choice.call("First printing"),
        "pagination_authority" => choice.call("Printed labels"),
        "publisher" => choice.call("Fixture Publisher")
      },
      policy: {
        "policy_id" => "approved-new-records", "policy_version" => "1",
        "definition_sha256" => Digest::SHA256.file(@policy).hexdigest,
        "selected_values" => {"selection" => "afw-qualified-default"},
        "selected_by" => "David", "selected_at" => at
      }
    )
  end

  def append_editorial_lineage
    dossier = write(File.join(@pipeline, "dossier.json"), "{}\n")
    context = write(File.join(@pipeline, "editorial_context.json"), "{}\n")
    decisions = write(File.join(@pipeline, "editorial_decisions.yml"), "--- {}\n")
    previous = @operations.validate!(ID)
    current = JSON.parse(JSON.generate(previous))
    current["revision"] += 1
    current["previous_revision_sha256"] = AdventureFinderWorkspace::IngestOperation.digest(previous)
    current["coordination"]["status"] = "open"
    current["artifacts"] = [
      artifact("dossier", "boundary_dossier", "af-boundary-dossier/v0.2", dossier, %w[input base_catalog]),
      artifact("context", "editorial_context", "af-boundary-editorial-context/v0.1", context, %w[dossier]),
      artifact("decisions", "editorial_decisions", "af-boundary-editorial-decisions/v0.2", decisions, %w[context])
    ]
    @operations.persist!(
      current, expected_revision: previous.fetch("revision"),
      expected_sha256: AdventureFinderWorkspace::IngestOperation.digest(previous)
    )
  end

  def artifact(id, kind, version, path, inputs)
    {
      "artifact_id" => id, "kind" => kind, "owner" => "af-data-pipeline",
      "contract_version" => version,
      "content" => {"sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => File.size(path),
                    "locator" => {"root" => "pipeline", "path" => Pathname(path).relative_path_from(Pathname(@pipeline)).to_s}},
      "inputs" => inputs, "supersedes" => nil
    }
  end

  def policy_document
    {"schema_version" => "af-staged-scoring-input-policy/v0.1", "policy_id" => "approved-new-records",
     "policy_version" => "1", "scope" => "operation-approved-new-records",
     "selection" => "afw-qualified-default", "permissions" => %w[scoring_input workload_preparation]}
  end

  def directory(relative)
    path = File.join(@dir, relative)
    FileUtils.mkdir_p(path)
    path
  end

  def write(path, bytes)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, bytes)
    path
  end

  def executable(path)
    write(path, "#!/bin/sh\nexit 0\n")
    FileUtils.chmod(0o755, path)
  end
end
