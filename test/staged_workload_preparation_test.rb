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
    attr_reader :calls, :authority, :afw_root, :ids, :write_outputs, :build_success

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
      ids = argv.include?("--ids") ? argv.fetch(argv.index("--ids") + 1).split(",") : @ids
      manifest = File.join(@afw_root, "workloads", workload)
      FileUtils.mkdir_p(manifest)
      jobs = ids.flat_map do |id|
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
        "adventure_order" => ids, "case_count" => jobs.length,
        "selected_dimensions" => ["Combat Emphasis", "Social Interaction Emphasis"]
      }
      File.write(File.join(manifest, "snapshot.yml"), YAML.dump(snapshot))
      authority = @authority.fetch("authority")
      binding = {
        "authority_id" => authority.fetch("authority_id"), "operation_id" => ID,
        "workload_id" => workload, "intended_ids" => ids,
        "schema_version" => "af-staged-scoring-workload-binding/v0.1",
        "staged_amc" => authority.fetch("staged_amc"), "artifacts" => {}
      }
      File.write(File.join(manifest, "staged-scoring.json"), JSON.generate(
        "schema_version" => "afw-staged-scoring-input/v0.1", "validator" => {}, "binding" => binding
      ))
    end
  end

  class Owner
    attr_reader :calls

    def initialize(runner:, status: "PREPARED", dispositions: nil, inspection_action: "reuse",
                   inspection_reason: "VERIFIED_REUSE")
      @runner = runner
      @status = status
      @dispositions = dispositions
      @inspection_action = inspection_action
      @inspection_reason = inspection_reason
      @calls = []
    end

    def prepare(operation_id:, workload_id:, catalog_path:)
      @calls << {operation_id:, workload_id:, catalog_path: catalog_path.to_s}
      authority = @runner.authority.fetch("authority")
      dispositions = @dispositions || @runner.ids.map do |id|
        {"adventure_id" => id, "disposition" => "selected-qualified",
         "reason" => {"code" => "AFW_QUALIFIED_DEFAULT"},
         "evidence" => {"page_count" => 10, "needs_levels" => false}}
      end
      selected = dispositions.select { |row| row["disposition"] == "selected-qualified" }
                             .map { |row| row.fetch("adventure_id") }
      selection = {
        "schema_version" => "afw-staged-selection/v0.1", "producer" => "af-workloads",
        "status" => @status == "ALL_DEFERRED" ? "ALL_DEFERRED" : (@status == "REFUSED" ? "REFUSED" : "SELECTED"),
        "authority_id" => authority.fetch("authority_id"), "operation" => authority.fetch("operation"),
        "workload_id" => workload_id, "allocation" => authority.fetch("allocation"),
        "selected_ids" => selected, "dispositions" => dispositions, "selection_id" => "c" * 64
      }
      inspection = {
        "contract_version" => "afw-workload-inspection/v0.1", "workload_id" => workload_id,
        "action" => @inspection_action, "reason_code" => @inspection_reason, "observed" => {}
      }
      manifest = nil
      if @status == "PREPARED"
        unless File.directory?(File.join(@runner.afw_root, "workloads", workload_id))
          @runner.capture({}, File.join(@runner.afw_root, "bin/afw-build-workload"),
                          "--workload", workload_id, "--ids", selected.join(","), chdir: @runner.afw_root)
        end
        manifest = File.join(@runner.afw_root, "workloads", workload_id)
      end
      {"status" => @status, "selection" => selection, "inspection" => inspection,
       "manifest" => manifest, "refusal" => nil}
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

  # AF preparation state is external; owner authority and frozen AFW artifacts
  # retain their original locators and the declared fake owner seams on replay.
  def test_external_preparation_retains_frozen_owner_bindings
    state = directory("external-state")
    selected = {"AF_STATE_ROOT" => state}
    runner = Runner.new(authority: authority_projection(["ADV-0003"]), afw_root: @afw, ids: ["ADV-0003"])
    first = prepare(service(runner, env: selected))
    assert_equal "PREPARED", first.fetch("status")
    assert_equal first, prepare(service(runner, env: selected))
    retained = File.join(state, "output/staged-workload-preparations/v0.1", ID)
    binding = JSON.parse(File.binread(File.join(retained, "authority-store.json")))
    assert_equal File.join(@pipeline, "output/staged-scoring-authority/v0.1"), binding.fetch("store_root")
    assert first.dig("plan", "path").start_with?(@afw + File::SEPARATOR)
    refute File.exist?(File.join(@front, "output/staged-workload-preparations"))
    assert_equal 1, runner.calls.count { |call| File.basename(call[:argv].first) == "afw-build-workload" }
  end

  def test_multiple_new_ids_prepare_once_and_restart_retains_owner_inspection
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
    assert_empty first.fetch("refused")
    assert_equal "afw-staged-selection/v0.1", first.fetch("selection_contract_version")
    assert_equal "reuse", first.dig("inspection", "action")
    assert_equal 1, runner.calls.count { |call| File.basename(call[:argv].first) == "afw-build-workload" }
    assert_includes first.fetch("next_action"), "afw-inspect-workload"
    assert_includes first.fetch("next_action"), "--staged-selection"
    assert_equal %w[issue validate], runner.calls.select { |call|
      File.basename(call[:argv].first) == "af-staged-scoring-authority"
    }.map { |call| call[:argv][1] }
  end

  # Binds a private store before issuance and refuses a different selector on
  # restart, before either the authority owner or AFW can receive another call.
  def test_private_store_is_immutable_across_preparation_restart
    runner = Runner.new(authority: authority_projection(["ADV-0003"]), afw_root: @afw, ids: ["ADV-0003"])
    selected = {"AF_DATA_PIPELINE_DATA_ROOT" => directory("private-data")}
    prepare(service(runner, env: selected))
    call = runner.calls.first
    store = File.join(selected.fetch("AF_DATA_PIPELINE_DATA_ROOT"), "output/staged-scoring-authority/v0.1")
    assert_equal store, call[:argv][call[:argv].index("--store") + 1]
    assert_equal selected.fetch("AF_DATA_PIPELINE_DATA_ROOT"), call[:environment]["AF_DATA_PIPELINE_DATA_ROOT"]
    binding = File.join(@front, "output/staged-workload-preparations/v0.1", ID, "authority-store.json")
    assert_equal({"operation_id" => ID, "store_root" => store}, JSON.parse(File.binread(binding)))
    calls = runner.calls.length
    error = assert_raises(AdventureFinderWorkspace::StagedWorkloadPreparation::Failure) do
      prepare(service(runner, env: {"AF_DATA_PIPELINE_DATA_ROOT" => directory("other-private-data")}))
    end
    assert_equal "PREPARATION_CONFLICT", error.code
    assert_equal calls, runner.calls.length
  end

  def test_successful_scoring_output_does_not_change_frozen_preparation_on_resume
    ids = ["ADV-0003"]
    runner = Runner.new(authority: authority_projection(ids), afw_root: @afw, ids:)
    owner = Owner.new(runner:)
    owner.define_singleton_method(:prepare) do |**options|
      result = super(**options)
      observed = result.fetch("inspection").fetch("observed")
      observed["output"] = @calls.length == 1 ? {"state" => "absent"} : {"state" => "directory"}
      observed["results"] = @calls.length == 1 ? {"state" => "absent"} : {"state" => "directory", "files" => 3}
      result
    end
    coordinator = service(runner, owner:)
    first = prepare(coordinator)
    retained = File.binread(File.join(@front, "output", "staged-workload-preparations", "v0.1", ID, "result.json"))
    second = prepare(coordinator)

    assert_equal first.except("inspection"), second.except("inspection")
    assert_equal retained, File.binread(File.join(@front, "output", "staged-workload-preparations", "v0.1", ID, "result.json"))
    assert_equal 2, owner.calls.length
    assert_equal "absent", first.dig("inspection", "observed", "results", "state")
    assert_equal "directory", second.dig("inspection", "observed", "results", "state")
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

    assert_equal "NO_SUCCESSOR_NEEDED", result.fetch("status")
    assert_empty result.fetch("selected")
    assert_empty result.fetch("deferred")
    assert_empty result.fetch("refused")
    assert_equal "NO_SUCCESSOR_NEEDED", result.dig("decision", "code")
    refute runner.calls.any? { |call| File.basename(call[:argv].first).start_with?("afw-") }
  end

  def test_mixed_selection_retains_exact_owner_reasons_and_only_selected_cases
    ids = %w[ADV-0003 ADV-0004]
    projection = authority_projection(ids)
    runner = Runner.new(authority: projection, afw_root: @afw, ids:)
    dispositions = [
      {"adventure_id" => "ADV-0003", "disposition" => "selected-qualified",
       "reason" => {"code" => "AFW_QUALIFIED_DEFAULT"},
       "evidence" => {"page_count" => 99, "needs_levels" => true}},
      {"adventure_id" => "ADV-0004", "disposition" => "legitimately-deferred",
       "reason" => {"code" => "OUTSIDE_QUALIFIED_PAGE_ENVELOPE", "limit_exclusive" => 100},
       "evidence" => {"page_count" => 100, "needs_levels" => false}}
    ]

    result = prepare(service(runner, owner: Owner.new(runner:, dispositions:)))

    assert_equal "PREPARED", result.fetch("status")
    assert_equal ["ADV-0003"], result.fetch("selected").map { |row| row.fetch("adventure_id") }
    assert_equal ["ADV-0004"], result.fetch("deferred").map { |row| row.fetch("adventure_id") }
    assert_equal 100, result.dig("deferred", 0, "evidence", "page_count")
    assert_equal "OUTSIDE_QUALIFIED_PAGE_ENVELOPE", result.dig("deferred", 0, "reason", "code")
    assert_equal 2, result.fetch("qualified_cases")
  end

  def test_nonempty_all_deferred_is_not_zero_allocation_or_prepared
    ids = ["ADV-0003"]
    projection = authority_projection(ids)
    runner = Runner.new(authority: projection, afw_root: @afw, ids:)
    dispositions = [{
      "adventure_id" => "ADV-0003", "disposition" => "legitimately-deferred",
      "reason" => {"code" => "OUTSIDE_QUALIFIED_PAGE_ENVELOPE", "limit_exclusive" => 100},
      "evidence" => {"page_count" => 100, "needs_levels" => false}
    }]

    result = prepare(service(runner, owner: Owner.new(runner:, status: "ALL_DEFERRED", dispositions:)))

    assert_equal "ALL_DEFERRED", result.fetch("status")
    assert_equal "AFW_ALL_DEFERRED", result.dig("decision", "code")
    assert_equal ["ADV-0003"], result.fetch("deferred").map { |row| row.fetch("adventure_id") }
    assert_nil result.fetch("plan")
    assert_nil result.fetch("next_action")
    refute File.directory?(File.join(@afw, "workloads", "ingest-11111111-1111-4111-8111-111111111111"))
  end

  def test_missing_output_and_owner_capability_refusal_fail_closed
    ids = ["ADV-0003"]
    projection = authority_projection(ids)
    missing = Runner.new(authority: projection, afw_root: @afw, ids:, write_outputs: false)
    error = assert_raises(AdventureFinderWorkspace::StagedWorkloadPreparation::Failure) do
      prepare(service(missing))
    end
    assert_equal "MISSING_PREPARATION_INPUT", error.code

    FileUtils.remove_entry(File.join(@front, "output", "staged-workload-preparations"))
    drift = Runner.new(authority: projection, afw_root: @afw, ids:, capability_context: 262_144)
    owner = Owner.new(runner: drift, status: "REFUSED", inspection_action: "refuse",
                      inspection_reason: "VERIFICATION_FAILED")
    result = prepare(service(drift, owner:))
    assert_equal "REFUSED", result.fetch("status")
    assert_equal "refuse", result.dig("inspection", "action")
    assert_nil result.fetch("plan")
  end

  def test_afw_refusal_retains_complete_refused_ledger
    ids = %w[ADV-0003 ADV-0004]
    runner = Runner.new(
      authority: authority_projection(ids), afw_root: @afw, ids:, build_success: false
    )

    dispositions = ids.map do |id|
      {"adventure_id" => id, "disposition" => "refused",
       "reason" => {"code" => "INVALID_OR_UNSUPPORTED_RECORD", "detail" => "invalid fixture"},
       "evidence" => {"allocation_sha256" => "d" * 64}}
    end
    result = prepare(service(runner, owner: Owner.new(runner:, status: "REFUSED", dispositions:)))

    assert_equal "REFUSED", result.fetch("status")
    assert_equal ids, result.fetch("refused").map { |entry| entry.fetch("adventure_id") }
    assert_empty result.fetch("deferred")
    assert_nil result.fetch("plan")
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

  def service(runner, owner: Owner.new(runner:), env: {})
    AdventureFinderWorkspace::StagedWorkloadPreparation.new(
      front_door_root: @front, project_root: @components, pipeline_root: @pipeline,
      afw_root: @afw, scorer_root: @scorer, source_root: @source,
      catalog_root: @catalog_root, operation_store: @operations, intent_store: @intents,
      authorization_store: @authorizations, routing: @routing, runner:, afw_coordinator: owner, env:
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

class AFWStagedWorkloadCoordinatorTest < Minitest::Test
  ID = "11111111-1111-4111-8111-111111111111"
  WORKLOAD = "synthetic-operation-1"

  class OwnerError < StandardError; end

  class StagedInput
    class << self
      attr_accessor :authority
    end

    def initialize(root:, config:)
      @root = root
      @config = config
    end

    def authority!(catalog_path:)
      self.class.authority
    end

    def use_selection!(path:, scorer_repo:)
      @selection = [path, scorer_repo]
      self
    end
  end

  class Selection
    VERSION = "afw-staged-selection/v0.1"
    class << self
      attr_accessor :document, :prepared
    end

    def initialize(root:, scorer_repo:)
      @root = root
      @scorer_repo = scorer_repo
    end

    def select!(authority:, catalog_path:)
      [self.class.document, File.join(@root, "selection.json")]
    end

    def prepare!(**_options)
      self.class.prepared || {"status" => "PREPARED"}
    end
  end

  class Validator
    def initialize(**_options); end
  end

  class Inspector
    CONTRACT_VERSION = "afw-workload-inspection/v0.1"
    class << self
      attr_accessor :actions
    end

    def initialize(**_options); end

    def inspect
      action = self.class.actions.shift
      {"contract_version" => CONTRACT_VERSION, "workload_id" => WORKLOAD,
       "action" => action, "reason_code" => "FIXTURE_#{action.upcase.tr('-', '_')}",
       "observed" => {}}
    end
  end

  class Compiler
    class << self
      attr_accessor :builds, :failure
    end

    def initialize(**_options); end

    def build
      raise self.class.failure if self.class.failure
      self.class.builds += 1
    end
  end

  def setup
    @root = Dir.mktmpdir("ig14e-owner-composition")
    @afw = File.join(@root, "afw")
    @scorer = File.join(@root, "scorer")
    @pipeline = File.join(@root, "pipeline")
    [@afw, @scorer, @pipeline].each { |path| FileUtils.mkdir_p(path) }
    StagedInput.authority = authority
    Selection.document = selection
    Selection.prepared = nil
    Inspector.actions = []
    Compiler.builds = 0
    Compiler.failure = nil
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_fresh_build_and_regeneration_require_final_reuse
    Inspector.actions = %w[fresh-build reuse]
    fresh = coordinator.prepare(operation_id: ID, workload_id: WORKLOAD, catalog_path: "catalog.xlsx")
    assert_equal "PREPARED", fresh.fetch("status")
    assert_equal "reuse", fresh.dig("inspection", "action")
    assert_equal 0, Compiler.builds

    Inspector.actions = %w[regenerate reuse]
    regenerated = coordinator.prepare(operation_id: ID, workload_id: WORKLOAD, catalog_path: "catalog.xlsx")
    assert_equal "PREPARED", regenerated.fetch("status")
    assert_equal 1, Compiler.builds

    Inspector.actions = %w[reuse reuse]
    reused = coordinator.prepare(operation_id: ID, workload_id: WORKLOAD, catalog_path: "catalog.xlsx")
    assert_equal "PREPARED", reused.fetch("status")
    assert_equal "reuse", reused.dig("inspection", "action")
    assert_equal 1, Compiler.builds
  end

  def test_refusal_and_all_deferred_never_claim_a_manifest
    Inspector.actions = ["refuse"]
    refused = coordinator.prepare(operation_id: ID, workload_id: WORKLOAD, catalog_path: "catalog.xlsx")
    assert_equal "REFUSED", refused.fetch("status")
    assert_nil refused.fetch("manifest")

    Selection.document = selection(
      status: "ALL_DEFERRED", disposition: "legitimately-deferred", selected_ids: []
    )
    all_deferred = coordinator.prepare(operation_id: ID, workload_id: WORKLOAD, catalog_path: "catalog.xlsx")
    assert_equal "ALL_DEFERRED", all_deferred.fetch("status")
    assert_nil all_deferred.fetch("inspection")
    assert_empty Inspector.actions
  end

  def test_compiler_refusal_unsupported_action_and_failed_final_inspection_fail_closed
    Inspector.actions = ["fresh-build"]
    Selection.prepared = {
      "status" => "REFUSED", "reason" => {"code" => "PREPARATION_REFUSED"},
      "dispositions" => Selection.document.fetch("dispositions")
    }
    refused = coordinator.prepare(operation_id: ID, workload_id: WORKLOAD, catalog_path: "catalog.xlsx")
    assert_equal "REFUSED", refused.fetch("status")
    assert_equal "PREPARATION_REFUSED", refused.dig("refusal", "reason", "code")

    Selection.prepared = nil
    Inspector.actions = %w[fresh-build refuse]
    final_refusal = coordinator.prepare(operation_id: ID, workload_id: WORKLOAD, catalog_path: "catalog.xlsx")
    assert_equal "REFUSED", final_refusal.fetch("status")
    assert_equal "refuse", final_refusal.dig("inspection", "action")

    Inspector.actions = ["unknown"]
    assert_raises(AdventureFinderWorkspace::AFWStagedWorkloadCoordinator::Failure) do
      coordinator.prepare(operation_id: ID, workload_id: WORKLOAD, catalog_path: "catalog.xlsx")
    end

    Inspector.actions = ["regenerate"]
    Compiler.failure = OwnerError.new("compiler refused")
    error = assert_raises(AdventureFinderWorkspace::AFWStagedWorkloadCoordinator::Failure) do
      coordinator.prepare(operation_id: ID, workload_id: WORKLOAD, catalog_path: "catalog.xlsx")
    end
    assert_includes error.message, "compiler refused"
  end

  def test_malformed_selection_and_zero_authority_are_rejected
    Selection.document = selection.merge("allocation" => [])
    assert_raises(AdventureFinderWorkspace::AFWStagedWorkloadCoordinator::Failure) do
      coordinator.prepare(operation_id: ID, workload_id: WORKLOAD, catalog_path: "catalog.xlsx")
    end

    StagedInput.authority = nil
    assert_raises(AdventureFinderWorkspace::AFWStagedWorkloadCoordinator::Failure) do
      coordinator.prepare(operation_id: ID, workload_id: WORKLOAD, catalog_path: "catalog.xlsx")
    end
  end

  private

  def coordinator
    AdventureFinderWorkspace::AFWStagedWorkloadCoordinator.new(
      afw_root: @afw, scorer_root: @scorer, pipeline_root: @pipeline,
      authority_inputs_path: File.join(@root, "inputs.json"),
      authority_store: File.join(@root, "authority"),
      current_project_state_path: File.join(@root, "PROJECT_STATE.yml"),
      mode: "synthetic",
      contracts: {
        error: OwnerError, staged_input: StagedInput, selection: Selection,
        validator: Validator, inspector: Inspector, compiler: Compiler
      }
    )
  end

  def authority
    {
      "authority_id" => "a" * 64,
      "operation" => {"operation_id" => ID},
      "allocation" => [{"adventure_id" => "ADV-0003"}]
    }
  end

  def selection(status: "SELECTED", disposition: "selected-qualified", selected_ids: ["ADV-0003"])
    {
      "schema_version" => "afw-staged-selection/v0.1", "producer" => "af-workloads",
      "status" => status, "authority_id" => "a" * 64,
      "operation" => {"operation_id" => ID}, "workload_id" => WORKLOAD,
      "allocation" => [{"adventure_id" => "ADV-0003"}],
      "selected_ids" => selected_ids,
      "dispositions" => [{
        "adventure_id" => "ADV-0003", "disposition" => disposition,
        "reason" => {"code" => "FIXTURE"}, "evidence" => {}
      }],
      "selection_id" => "b" * 64
    }
  end
end
