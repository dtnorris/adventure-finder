# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"
require "adventure_finder_ingest_operation_store"

class Ig05c3OperationRoutingRestartAcceptanceTest < Minitest::Test
  Store = AdventureFinderWorkspace::IngestOperationStore
  Contract = AdventureFinderWorkspace::IngestOperation
  Failure = AdventureFinderWorkspace::IngestOperationStore::Failure
  ID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
  NOW = "2026-10-07T09:45:00Z"

  def setup
    @pipeline_source = ENV["AF_DATA_PIPELINE_ROOT"]
    skip "set AF_DATA_PIPELINE_ROOT to the exact pipeline checkout" unless @pipeline_source
    @pipeline_source = File.expand_path(@pipeline_source)
    require_source!(File.join(@pipeline_source, "bin", "af-ingest-next"))
    require_source!(File.join(@pipeline_source, "docs", "INGEST_OPERATION_ROUTING_V0.1.md"))

    @temporary = Dir.mktmpdir("ig05c3-routing-restart")
    @front = directory("detached front door")
    @components = directory("component root")
    @pipeline = directory("component root/af-data-pipeline")
    @converter = directory("component root/pdf-to-llm-md-converter")
    @source = directory("component root/md-for-llm-book-content")
    @input_root = directory("owned inputs")
    @catalog_root = directory("catalog data")
    @first_cwd = directory("first process cwd")
    @second_cwd = directory("second process cwd")
    @forbidden_bin = directory("forbidden bin")
    @forbidden_log = File.join(@temporary, "forbidden.log")
    @route_log = File.join(@temporary, "route.jsonl")

    @pdf = write(File.join(@input_root, "book.pdf"), "%PDF deterministic fixture\n")
    @base = write(File.join(@catalog_root, "catalog.xlsx"), "frozen catalog\n")
    @policy = write(File.join(@temporary, "policy.yml"), "policy: fixture\n")
    write_project_state(@base)
    fake_converter
    proxy_pipeline_executable
    install_forbidden_commands
  end

  def teardown
    FileUtils.remove_entry(@temporary) if @temporary && File.exist?(@temporary)
  end

  def test_public_resume_reconstructs_the_same_gate_without_mutating_or_executing
    started_out, started_err, started_status = run_catalog(@first_cwd, *start_arguments)

    assert started_status.success?, started_err
    assert_includes started_out, "Gate: NEEDS_CANONICAL_MARKDOWN_PLACEMENT"
    operation = store.load(ID)
    assert_equal 1, operation.fetch("revision")
    assert_equal "conversion_receipt", operation.dig("artifacts", 0, "kind")
    refute_includes JSON.generate(operation), "downstream_ready"
    refute_includes JSON.generate(operation), File.binread(receipt_path)
    before = operation_snapshot

    resumed_out, resumed_err, resumed_status = run_catalog(@second_cwd, "resume", ID)

    assert resumed_status.success?, resumed_err
    assert_includes resumed_out, "Gate: NEEDS_CANONICAL_MARKDOWN_PLACEMENT"
    assert_equal before, operation_snapshot
    assert_equal ["start", "resume"], route_invocations.map { |entry| entry.fetch("phase") }
    assert route_invocations.all? { |entry| !entry.fetch("argv").include?("--auto") }
    refute File.exist?(@forbidden_log)
  end

  def test_authoritative_bytes_and_immutable_operation_values_override_cached_observations
    start!
    current = store.load(ID)
    observed = advance(current)
    observed["coordination"]["route_observation"] = {
      "artifact_id" => "conversion-receipt",
      "router_state" => "READY_FROM_STALE_CACHE",
      "observed_at" => NOW,
      "basis_sha256" => Contract.observation_basis(observed)
    }
    persist(current, observed)
    before = operation_snapshot

    stdout, stderr, status = run_catalog(@second_cwd, "resume", ID)

    assert status.success?, stderr
    assert_includes stdout, "Gate: NEEDS_CANONICAL_MARKDOWN_PLACEMENT"
    refute_includes stdout, "READY_FROM_STALE_CACHE"
    assert_equal before, operation_snapshot

    immutable = advance(store.load(ID))
    immutable.dig("source_declaration", "source_id")["value"] = "Changed Source"
    error = assert_raises(Failure) { persist(store.load(ID), immutable) }
    assert_equal "CONFLICT", error.code
    assert_equal before, operation_snapshot

    receipt_bytes = File.binread(receipt_path)
    File.binwrite(receipt_path, receipt_bytes + "changed\n")
    stale_out, _stale_err, stale_status = run_catalog(@second_cwd, "resume", ID)
    assert_equal 2, stale_status.exitstatus
    assert_includes stale_out, "Diagnostic: STALE_INPUT"
    File.binwrite(receipt_path, receipt_bytes)

    base_bytes = File.binread(@base)
    File.binwrite(@base, "replacement catalog\n")
    base_out, _base_err, base_status = run_catalog(@second_cwd, "resume", ID)
    assert_equal 2, base_status.exitstatus
    assert_includes base_out, "Diagnostic: STALE_INPUT"
    File.binwrite(@base, base_bytes)
    assert_equal before, operation_snapshot
  end

  def test_pipeline_schema_provenance_and_operation_record_failures_remain_distinct
    start!
    current = store.load(ID)
    intake_path = write(
      File.join(@pipeline, "artifacts", "source_intake.json"),
      JSON.pretty_generate(
        "schema_version" => "af-source-intake/v0.1",
        "source_root" => @source,
        "markdown" => {"filename" => "missing.md", "sha256" => "a" * 64},
        "registry" => {"registration_status" => "registered",
                       "source_ids_referencing_file" => ["Different Source"]},
        "conversion_provenance" => {"receipt_status" => "accepted",
                                    "conversion_acceptance_verified" => true}
      ) + "\n"
    )
    with_intake = advance(current)
    with_intake["artifacts"] << artifact(
      "source-intake", "source_intake", "af-data-pipeline", "af-source-intake/v0.1",
      "pipeline", intake_path, inputs: ["conversion-receipt"]
    )
    persist(current, with_intake)

    conflict_out, _conflict_err, conflict_status = run_catalog(@second_cwd, "resume", ID)
    assert_equal 2, conflict_status.exitstatus
    assert_includes conflict_out, "Diagnostic: COMPONENT_ARTIFACT_CONFLICT"

    incompatible_path = write(
      File.join(@pipeline, "artifacts", "future.json"),
      JSON.generate("schema_version" => "future-ingest-artifact/v9") + "\n"
    )
    prior = store.load(ID)
    incompatible = advance(prior)
    incompatible["artifacts"] << artifact(
      "source-intake-v2", "source_intake", "af-data-pipeline", "af-source-intake/v0.1",
      "pipeline", incompatible_path, inputs: ["conversion-receipt"], supersedes: "source-intake"
    )
    persist(prior, incompatible)

    schema_out, _schema_err, schema_status = run_catalog(@second_cwd, "resume", ID)
    assert_equal 2, schema_status.exitstatus
    assert_includes schema_out, "Diagnostic: PIPELINE_FAILURE"
    assert_match(/Unsupported JSON ingestion schema/, schema_out)

    revision = store.revision_path(ID, 3)
    original_revision = File.binread(revision)
    changed = JSON.parse(original_revision)
    changed.dig("policy", "selected_values")["execution"] = "execute-now"
    File.binwrite(revision, JSON.pretty_generate(changed) + "\n")
    corrupt_out, _corrupt_err, corrupt_status = run_catalog(@second_cwd, "resume", ID)
    assert_equal 2, corrupt_status.exitstatus
    assert_includes corrupt_out, "Diagnostic: CORRUPT_EVIDENCE"
    File.binwrite(revision, original_revision)

    refute File.exist?(@forbidden_log)
  end

  private

  def start!
    _stdout, stderr, status = run_catalog(@first_cwd, *start_arguments)
    assert status.success?, stderr
  end

  def start_arguments
    [
      "start", @pdf,
      "--operation-id", ID,
      "--source-id", "Fixture Source",
      "--edition", "First printing",
      "--pagination-authority", "Printed page labels",
      "--publisher", "Fixture Publisher",
      "--base-catalog", @base,
      "--policy-definition", @policy,
      "--policy-id", "standard-scoring-execution",
      "--policy-version", "v0.1",
      "--policy-values", JSON.generate("profile" => "standard", "execution" => "deferred"),
      "--selected-by", "David"
    ]
  end

  def run_catalog(cwd, *arguments)
    Open3.capture3(
      {
        "AF_PROJECT_ROOT" => @components,
        "AF_ADVENTURE_FINDER_ROOT" => @front,
        "AF_PDF_CONVERTER_ROOT" => @converter,
        "AF_DATA_PIPELINE_ROOT" => @pipeline,
        "AF_SOURCE_ROOT" => @source,
        "IG05C3_PHASE" => arguments.first == "start" ? "start" : "resume",
        "PATH" => [File.dirname(RbConfig.ruby), @forbidden_bin, ENV.fetch("PATH", "")]
          .join(File::PATH_SEPARATOR)
      },
      File.expand_path("../../bin/af-catalog", __dir__),
      *arguments,
      chdir: cwd
    )
  end

  def store
    @store ||= Store.new(
      root: File.join(@front, "output", "ingest-operations", "v0.1"),
      roots: {
        "input" => @input_root,
        "front_door" => @front,
        "pipeline" => @pipeline,
        "converter" => @converter,
        "source" => @source,
        "catalog" => @catalog_root
      }
    )
  end

  def operation_root
    File.join(@front, "output", "ingest-operations", "v0.1", ID)
  end

  def receipt_path
    File.join(@converter, "build", "conversion-receipt.json")
  end

  def advance(document)
    JSON.parse(JSON.generate(document)).tap do |next_revision|
      next_revision["revision"] += 1
      next_revision["previous_revision_sha256"] = Contract.digest(document)
      next_revision["coordination"]["route_observation"] = nil
    end
  end

  def persist(previous, current)
    store.persist!(current, expected_revision: previous.fetch("revision"),
                   expected_sha256: Contract.digest(previous))
  end

  def artifact(id, kind, owner, version, root, path, inputs:, supersedes: nil)
    bytes = File.binread(path)
    root_path = root == "pipeline" ? @pipeline : @converter
    relative = Pathname(path).relative_path_from(Pathname(root_path)).to_s
    {
      "artifact_id" => id,
      "kind" => kind,
      "owner" => owner,
      "contract_version" => version,
      "content" => {
        "sha256" => Digest::SHA256.hexdigest(bytes),
        "bytes" => bytes.bytesize,
        "locator" => {"root" => root, "path" => relative}
      },
      "inputs" => inputs,
      "supersedes" => supersedes
    }
  end

  def fake_converter
    executable(File.join(@converter, "bin", "convert-cached"), <<~RUBY)
      require "digest"
      require "fileutils"
      require "json"
      input = ARGV.fetch(0)
      output = ARGV.fetch(ARGV.index("--output-dir") + 1)
      FileUtils.mkdir_p(output)
      markdown = File.join(output, "accepted.md")
      File.binwrite(markdown, "# deterministic accepted output\\n")
      receipt = File.join(output, "conversion-receipt.json")
      File.binwrite(receipt, JSON.pretty_generate(
        "schema" => "pdf-to-llm-md/conversion-receipt/v0.1",
        "state" => "ready",
        "downstream_ready" => true,
        "source" => {"path" => input},
        "output" => {"path" => markdown, "sha256" => Digest::SHA256.file(markdown).hexdigest}
      ) + "\\n")
      puts "Conversion receipt: \#{receipt}"
    RUBY
  end

  def proxy_pipeline_executable
    executable(File.join(@pipeline, "bin", "af-ingest-next"), <<~RUBY)
      require "json"
      File.open(#{@route_log.inspect}, "ab") do |file|
        file.puts(JSON.generate("phase" => ENV.fetch("IG05C3_PHASE"), "argv" => ARGV))
      end
      load #{File.join(@pipeline_source, "bin", "af-ingest-next").inspect}
    RUBY
  end

  def install_forbidden_commands
    %w[git ollama wlo rpof af-workloads af-cli-scoring-utility].each do |name|
      executable(File.join(@forbidden_bin, name), <<~RUBY)
        File.open(#{@forbidden_log.inspect}, "ab") { |file| file.puts(File.basename($PROGRAM_NAME)) }
        exit 99
      RUBY
    end
  end

  def write_project_state(head)
    role = {
      "version" => "fixture",
      "filename" => File.basename(head),
      "sha256" => Digest::SHA256.file(head).hexdigest,
      "bytes" => File.size(head)
    }
    write(
      File.join(@catalog_root, "PROJECT_STATE.yml"),
      YAML.dump(
        "schema_version" => "adventurefinder-project-state/v0.2",
        "catalog_head" => role,
        "matcher_authorized_baseline" => role,
        "production_dependency_floor" => role
      )
    )
  end

  def route_invocations
    File.readlines(@route_log, chomp: true).map { |line| JSON.parse(line) }
  end

  def operation_snapshot
    Dir.glob(File.join(@front, "output", "**", "*"), File::FNM_DOTMATCH)
       .select { |path| File.file?(path) }
       .sort.to_h { |path| [path.delete_prefix(@front), Digest::SHA256.file(path).hexdigest] }
  end

  def directory(relative)
    File.join(@temporary, relative).tap { |path| FileUtils.mkdir_p(path) }
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
    path
  end

  def executable(path, body)
    write(path, "#!#{RbConfig.ruby}\n#{body}")
    FileUtils.chmod(0o755, path)
  end

  def require_source!(path)
    skip "missing exact pipeline source #{path}" unless File.file?(path)
  end
end
