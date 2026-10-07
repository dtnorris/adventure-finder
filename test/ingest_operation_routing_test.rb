# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "stringio"
require "tmpdir"
require "adventure_finder_ingest_routing"

class IngestOperationRoutingTest < Minitest::Test
  Routing = AdventureFinderWorkspace::IngestOperationRouting
  Store = AdventureFinderWorkspace::IngestOperationStore
  Contract = AdventureFinderWorkspace::IngestOperation
  ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  NOW = "2026-10-07T00:00:00Z"

  Status = Struct.new(:exitstatus) do
    def success? = exitstatus.zero?
  end

  class FakeRunner
    attr_reader :calls, :projections
    attr_accessor :handler

    def initialize
      @calls = []
      @projections = []
    end

    def capture(environment, *argv)
      @calls << {environment:, argv:}
      input_path = argv.fetch(argv.index("--operation-input") + 1)
      projection = JSON.parse(File.binread(input_path))
      @projections << projection
      return handler.call(projection, input_path) if handler

      route = {
        "state" => "NEEDS_SOURCE_IDENTITY",
        "artifact_type" => "source_intake",
        "evidence" => ["authoritative fixture evidence"],
        "human_review" => ["Review #{input_path} without executing it."],
        "commands" => [{"cwd" => "/fixture/pipeline", "command" => "resume --operation-input #{input_path}"}],
        "warnings" => ["fixture warning"]
      }
      response(projection, route)
    end

    def response(projection, route, exitstatus: 0)
      operation = projection.fetch("operation").except("contract_version").merge(
        "routing_input_sha256" => Digest::SHA256.hexdigest(JSON.generate(canonical(projection)))
      )
      Routing::CommandRunner::Result.new(
        stdout: JSON.generate(
          "schema_version" => Routing::PIPELINE_RESULT_VERSION,
          "operation" => operation,
          "route" => route
        ),
        stderr: "",
        status: Status.new(exitstatus)
      )
    end

    def error(code, message)
      Routing::CommandRunner::Result.new(
        stdout: "",
        stderr: JSON.generate(
          "schema_version" => Routing::PIPELINE_ERROR_VERSION,
          "error" => {"code" => code, "message" => message}
        ),
        status: Status.new(2)
      )
    end

    private

    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end
  end

  def setup
    @temporary = Dir.mktmpdir("ingest-operation-routing")
    @store_root = File.join(@temporary, "front-door", "output", "operations")
    @input_root = directory("input")
    @catalog_root = directory("catalog")
    @converter_root = directory("converter")
    @pipeline_artifacts = directory("pipeline-artifacts")
    @source_root = directory("source")
    @pipeline_root = directory("pipeline")
    executable(File.join(@pipeline_root, "bin", "af-ingest-next"))
    File.binwrite(File.join(@input_root, "book.pdf"), "%PDF synthetic fixture\n")
    File.binwrite(File.join(@catalog_root, "catalog.xlsx"), "synthetic catalog\n")
    @roots = {
      "input" => @input_root, "catalog" => @catalog_root, "converter" => @converter_root,
      "pipeline" => @pipeline_artifacts, "source" => @source_root
    }
    @store = Store.new(root: @store_root, roots: @roots)
    @runner = FakeRunner.new
    @composer = composer
  end

  def teardown
    FileUtils.remove_entry(@temporary) if File.exist?(@temporary)
  end

  def test_unbound_operation_is_a_distinct_gate_and_does_not_call_pipeline
    create

    result = @composer.compose(ID)

    assert_equal "WAITING", result["status"]
    assert_equal "NEEDS_FIRST_COMPONENT_ARTIFACT", result.dig("gate", "state")
    assert_equal "WAITING_FOR_ARTIFACT", result.dig("gate", "kind")
    assert_empty @runner.calls
  end

  def test_absent_operation_is_rejected_without_creating_store_state
    result = @composer.compose(ID)

    assert_equal "REJECTED", result["status"]
    assert_equal "OPERATION_ABSENT", result.dig("diagnostic", "code")
    assert_empty @runner.calls
    refute File.exist?(@store_root)
  end

  def test_composes_only_bound_values_and_does_not_persist_pipeline_state
    operation = create
    artifact_path = write_artifact(@pipeline_artifacts, "intake.json", "{\"synthetic\":true}\n")
    operation = bind(operation, artifact(
      "intake", "source_intake", "af-data-pipeline", "af-source-intake/v0.1",
      "pipeline", "intake.json"
    ))
    before_store = snapshot(@store_root)
    before_components = snapshot(@pipeline_artifacts)

    result = @composer.compose(ID)
    projection = @runner.projections.fetch(0)

    assert_equal "ROUTED", result["status"]
    assert_equal "NEEDS_SOURCE_IDENTITY", result.dig("gate", "state")
    assert_equal "HUMAN_REVIEW", result.dig("gate", "kind")
    assert_equal Contract.digest(operation), result.dig("operation", "document_sha256")
    assert_equal ["intake"], result.dig("artifact", "artifact_ids")
    assert_equal operation.dig("artifacts", 0, "content", "sha256"), projection.dig("artifact", "sha256")
    assert_nil projection.dig("source", "source_id")
    assert_nil projection.dig("source", "canonical_markdown")
    assert_nil projection["policy"]
    assert_equal "catalog.xlsx", projection.dig("base_catalog", "filename")
    assert_equal "explicit", projection.dig("base_catalog", "selection_method")
    assert_equal before_store, snapshot(@store_root)
    assert_equal before_components, snapshot(@pipeline_artifacts)
    refute_includes JSON.generate(result), artifact_path
    assert_includes JSON.generate(result), "<operation-input>"
    refute_includes @runner.calls.first.fetch(:argv), "--auto"
  end

  def test_explicit_source_and_inert_policy_values_are_projected_without_selection_metadata
    declaration = Contract::SOURCE_CHOICES.to_h { |key| [key, choice("bound #{key}")] }
    policy = {
      "policy_id" => "fixture-policy", "policy_version" => "v1",
      "definition_sha256" => "e" * 64, "selected_values" => {"execution" => "local"},
      "selected_by" => "David", "selected_at" => NOW
    }
    operation = create(source_declaration: declaration, policy:)
    write_artifact(@converter_root, "receipt.json", "{\"synthetic\":true}\n")
    bind(operation, artifact(
      "receipt", "conversion_receipt", "pdf-to-llm-md-converter",
      "pdf-to-llm-md/conversion-receipt/v0.1", "converter", "receipt.json"
    ))

    @composer.compose(ID)
    projection = @runner.projections.fetch(0)

    assert_equal "bound source_id", projection.dig("source", "source_id")
    assert_equal "bound edition", projection.dig("source", "edition")
    assert_equal "bound pagination_authority", projection.dig("source", "pagination_authority")
    assert_equal "bound publisher", projection.dig("source", "publisher")
    assert_equal %w[definition_sha256 policy_id policy_version selected_values], projection.fetch("policy").keys.sort
    refute_includes JSON.generate(projection), "selected_by"
  end

  def test_compatible_superseding_artifact_is_selected_without_deleting_history
    operation = create
    write_artifact(@pipeline_artifacts, "intake-1.json", "first\n")
    first = bind(operation, artifact(
      "intake-1", "source_intake", "af-data-pipeline", "af-source-intake/v0.1",
      "pipeline", "intake-1.json"
    ))
    write_artifact(@pipeline_artifacts, "intake-2.json", "second\n")
    second_ref = artifact(
      "intake-2", "source_intake", "af-data-pipeline", "af-source-intake/v0.1",
      "pipeline", "intake-2.json"
    )
    second_ref["supersedes"] = "intake-1"
    current = bind(first, second_ref)

    result = @composer.compose(ID)

    assert_equal ["intake-2"], result.dig("artifact", "artifact_ids")
    assert_equal second_ref.dig("content", "sha256"), @runner.projections.first.dig("artifact", "sha256")
    assert_equal %w[intake-1 intake-2], current.fetch("artifacts").map { |item| item.fetch("artifact_id") }
    assert_equal %w[intake-1 intake-2], @store.load(ID).fetch("artifacts").map { |item| item.fetch("artifact_id") }
  end

  def test_missing_changed_and_corrupt_bound_state_never_produce_a_route
    operation = create
    artifact_path = write_artifact(@pipeline_artifacts, "intake.json", "fixture\n")
    bind(operation, artifact(
      "intake", "source_intake", "af-data-pipeline", "af-source-intake/v0.1",
      "pipeline", "intake.json"
    ))

    File.unlink(artifact_path)
    missing = @composer.compose(ID)
    assert_equal "MISSING_BOUND_ARTIFACT", missing.dig("diagnostic", "code")
    assert_empty @runner.calls

    File.binwrite(artifact_path, "changed\n")
    changed = @composer.compose(ID)
    assert_equal "STALE_INPUT", changed.dig("diagnostic", "code")
    assert_empty @runner.calls

    File.binwrite(@store.revision_path(ID, 1), "{not json")
    corrupt = @composer.compose(ID)
    assert_equal "CORRUPT_EVIDENCE", corrupt.dig("diagnostic", "code")
    assert_empty @runner.calls
  end

  def test_incompatible_artifact_version_in_operation_fails_before_pipeline
    operation = create
    write_artifact(@pipeline_artifacts, "intake.json", "fixture\n")
    bind(operation, artifact(
      "intake", "source_intake", "af-data-pipeline", "af-source-intake/v0.1",
      "pipeline", "intake.json"
    ))
    path = @store.revision_path(ID, 1)
    document = JSON.parse(File.binread(path))
    document.fetch("artifacts").first["contract_version"] = "af-source-intake/v9"
    File.binwrite(path, JSON.pretty_generate(document))

    result = @composer.compose(ID)

    assert_equal "CORRUPT_EVIDENCE", result.dig("diagnostic", "code")
    assert_match(/unsupported artifact/, result.dig("diagnostic", "message"))
    assert_empty @runner.calls
  end

  def test_pipeline_contract_error_is_propagated_with_pipeline_ownership
    operation = create
    write_artifact(@pipeline_artifacts, "intake.json", "fixture\n")
    bind(operation, artifact(
      "intake", "source_intake", "af-data-pipeline", "af-source-intake/v0.1",
      "pipeline", "intake.json"
    ))
    @runner.handler = ->(_projection, _path) { @runner.error("COMPONENT_ARTIFACT_CONFLICT", "source mismatch") }

    result = @composer.compose(ID)

    assert_equal "REJECTED", result["status"]
    assert_equal "af-data-pipeline", result.dig("diagnostic", "owner")
    assert_equal "COMPONENT_ARTIFACT_CONFLICT", result.dig("diagnostic", "code")
    assert_equal "source mismatch", result.dig("diagnostic", "message")
    assert_nil result["route"]
  end

  def test_malformed_pipeline_output_and_unexpected_exit_fail_closed
    operation = create
    write_artifact(@pipeline_artifacts, "intake.json", "fixture\n")
    bind(operation, artifact(
      "intake", "source_intake", "af-data-pipeline", "af-source-intake/v0.1",
      "pipeline", "intake.json"
    ))
    @runner.handler = lambda do |_projection, _path|
      Routing::CommandRunner::Result.new(stdout: "{}", stderr: "", status: Status.new(0))
    end
    assert_equal "PIPELINE_PROTOCOL_ERROR", @composer.compose(ID).dig("diagnostic", "code")

    @runner.handler = lambda do |projection, _path|
      route = {
        "state" => "NEEDS_SOURCE_IDENTITY", "artifact_type" => "source_intake",
        "evidence" => [], "human_review" => [], "commands" => [], "warnings" => []
      }
      @runner.response(projection, route, exitstatus: 3)
    end
    assert_equal "PIPELINE_FAILURE", @composer.compose(ID).dig("diagnostic", "code")
  end

  def test_operation_advancing_during_pipeline_inspection_discards_the_route
    operation = create
    write_artifact(@pipeline_artifacts, "intake.json", "fixture\n")
    current = bind(operation, artifact(
      "intake", "source_intake", "af-data-pipeline", "af-source-intake/v0.1",
      "pipeline", "intake.json"
    ))
    @runner.handler = lambda do |projection, _path|
      next_revision = advance(current)
      next_revision["source_declaration"]["edition"] = choice("operator edition")
      @store.persist!(next_revision, expected_revision: current.fetch("revision"),
                      expected_sha256: Contract.digest(current))
      route = {
        "state" => "NEEDS_SOURCE_IDENTITY", "artifact_type" => "source_intake",
        "evidence" => [], "human_review" => [], "commands" => [], "warnings" => []
      }
      @runner.response(projection, route)
    end

    result = @composer.compose(ID)

    assert_equal "OPERATION_CHANGED", result.dig("diagnostic", "code")
    assert_nil result["route"]
  end

  def test_editorial_context_waits_and_linked_canonical_pair_routes_as_one_bundle
    operation = create
    bundle = directory("pipeline-artifacts/editorial")
    write_artifact(bundle, "editorial_context.json", "context\n")
    context = artifact(
      "context", "editorial_context", "af-data-pipeline", "af-boundary-editorial-context/v0.1",
      "pipeline", "editorial/editorial_context.json"
    )
    current = bind(operation, context)

    waiting = @composer.compose(ID)
    assert_equal "NEEDS_EDITORIAL_DECISIONS_ARTIFACT", waiting.dig("gate", "state")
    assert_empty @runner.calls

    write_artifact(bundle, "editorial_decisions.yml", "decisions\n")
    decisions = artifact(
      "decisions", "editorial_decisions", "af-data-pipeline", "af-boundary-editorial-decisions/v0.1",
      "pipeline", "editorial/editorial_decisions.yml", inputs: ["context"]
    )
    bind(current, decisions)
    result = @composer.compose(ID)
    projection = @runner.projections.fetch(0)

    assert_equal "ROUTED", result["status"]
    assert_equal %w[context decisions], result.dig("artifact", "artifact_ids")
    assert_equal "editorial_bundle", projection.dig("artifact", "kind")
    assert_equal %w[editorial_context.json editorial_decisions.yml],
                 projection.dig("artifact", "members").map { |member| member["filename"] }
  end

  def test_render_preserves_evidence_warnings_and_blocking_information
    operation = create
    write_artifact(@pipeline_artifacts, "intake.json", "fixture\n")
    bind(operation, artifact(
      "intake", "source_intake", "af-data-pipeline", "af-source-intake/v0.1",
      "pipeline", "intake.json"
    ))
    result = @composer.compose(ID)
    output = StringIO.new

    @composer.render(result, out: output)

    assert_includes output.string, "Gate: NEEDS_SOURCE_IDENTITY"
    assert_includes output.string, "authoritative fixture evidence"
    assert_includes output.string, "fixture warning"
    assert_includes output.string, "nothing was executed"
  end

  private

  def composer
    Routing.new(
      store: @store, project_root: @temporary, front_door_root: File.join(@temporary, "front-door"),
      pipeline_root: @pipeline_root, source_root: @source_root, catalog_root: @catalog_root,
      runner: @runner
    )
  end

  def create(source_declaration: nil, policy: nil)
    @store.create(
      operation_id: ID, created_at: NOW,
      input_locator: {"root" => "input", "path" => "book.pdf"},
      base_catalog_locator: {"root" => "catalog", "path" => "catalog.xlsx"},
      catalog_selected_by: "David", catalog_selected_at: NOW,
      source_declaration:, policy:
    )
  end

  def bind(previous, artifact)
    document = advance(previous)
    document["artifacts"] << artifact
    document["coordination"]["status"] = "open"
    @store.persist!(document, expected_revision: previous.fetch("revision"),
                    expected_sha256: Contract.digest(previous))
  end

  def advance(document)
    copy(document).tap do |next_revision|
      next_revision["revision"] += 1
      next_revision["previous_revision_sha256"] = Contract.digest(document)
      next_revision["coordination"]["route_observation"] = nil
    end
  end

  def artifact(id, kind, owner, version, root, path, inputs: ["input"])
    absolute = File.join(@roots.fetch(root), path)
    {
      "artifact_id" => id, "kind" => kind, "owner" => owner, "contract_version" => version,
      "content" => {"sha256" => Digest::SHA256.file(absolute).hexdigest,
                    "bytes" => File.size(absolute), "locator" => {"root" => root, "path" => path}},
      "inputs" => inputs, "supersedes" => nil
    }
  end

  def choice(value)
    {"value" => value, "selected_by" => "David", "selected_at" => NOW}
  end

  def directory(relative)
    File.join(@temporary, relative).tap { |path| FileUtils.mkdir_p(path) }
  end

  def executable(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, "#!/bin/sh\nexit 99\n")
    FileUtils.chmod(0o755, path)
  end

  def write_artifact(root, path, bytes)
    File.join(root, path).tap do |absolute|
      FileUtils.mkdir_p(File.dirname(absolute))
      File.binwrite(absolute, bytes)
    end
  end

  def snapshot(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)
       .reject { |path| [".", ".."].include?(File.basename(path)) }
       .sort.to_h do |path|
         bytes = File.file?(path) ? Digest::SHA256.file(path).hexdigest : nil
         [path.delete_prefix(root), [File.stat(path).mode, File.stat(path).size, bytes]]
       end
  end

  def copy(value)
    JSON.parse(JSON.generate(value))
  end
end
