# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"
require "adventure_finder_ingest_routing"

class IngestOperationRoutingCompositionTest < Minitest::Test
  Routing = AdventureFinderWorkspace::IngestOperationRouting
  Store = AdventureFinderWorkspace::IngestOperationStore
  Contract = AdventureFinderWorkspace::IngestOperation
  ID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  NOW = "2026-10-07T00:20:00Z"

  def setup
    @pipeline_source = ENV["AF_DATA_PIPELINE_ROOT"]
    skip "set AF_DATA_PIPELINE_ROOT to the exact pipeline checkout" unless @pipeline_source
    @pipeline_source = File.expand_path(@pipeline_source)
    require_source!(File.join(@pipeline_source, "bin", "af-ingest-next"))
    require_source!(File.join(@pipeline_source, "docs", "INGEST_OPERATION_ROUTING_V0.1.md"))

    @temporary = Dir.mktmpdir("ingest-routing-composition")
    @front_door_root = directory("adventure-finder")
    @input_root = directory("input")
    @catalog_root = directory("catalog")
    @converter_root = directory("converter")
    @pipeline_artifacts = directory("pipeline-artifacts")
    @source_root = directory("source")
    @pipeline_proxy = directory("pipeline-proxy")
    proxy_pipeline_executable

    File.binwrite(File.join(@input_root, "book.pdf"), "%PDF synthetic fixture\n")
    @base = File.join(@catalog_root, "catalog.xlsx")
    File.binwrite(@base, "frozen catalog\n")
    write_project_state(@base)
    @roots = {
      "input" => @input_root, "catalog" => @catalog_root, "converter" => @converter_root,
      "pipeline" => @pipeline_artifacts, "source" => @source_root
    }
    @store_root = File.join(@front_door_root, "output", "ingest-operations", "v0.1")
    @store = Store.new(root: @store_root, roots: @roots)
  end

  def teardown
    FileUtils.remove_entry(@temporary) if @temporary && File.exist?(@temporary)
  end

  def test_real_public_seam_replays_the_same_unset_choice_gate_after_restart_and_head_movement
    operation = create
    receipt = File.join(@converter_root, "receipt.json")
    markdown = File.join(@converter_root, "accepted.md")
    File.binwrite(markdown, "# synthetic accepted output\n")
    write_json(
      receipt,
      "schema" => "pdf-to-llm-md/conversion-receipt/v0.1",
      "state" => "ready",
      "downstream_ready" => true,
      "source" => {"path" => File.join(@input_root, "book.pdf")},
      "output" => {"path" => markdown, "sha256" => Digest::SHA256.file(markdown).hexdigest}
    )
    bind(operation, artifact(
      "receipt", "conversion_receipt", "pdf-to-llm-md-converter",
      "pdf-to-llm-md/conversion-receipt/v0.1", "converter", "receipt.json"
    ))
    before_components = component_snapshot
    first = composer.compose(ID)

    newer = File.join(@catalog_root, "newer.xlsx")
    File.binwrite(newer, "newer catalog\n")
    write_project_state(newer)
    after_head_move = component_snapshot
    second = compose_in_fresh_process

    assert_equal "ROUTED", first["status"]
    assert_equal "NEEDS_CANONICAL_MARKDOWN_PLACEMENT", first.dig("gate", "state")
    assert_equal first, second
    assert_nil @store.load(ID).dig("source_declaration", "source_id")
    assert_nil @store.load(ID).dig("source_declaration", "edition")
    assert_equal Digest::SHA256.file(@base).hexdigest, @store.load(ID).dig("base_catalog", "content", "sha256")
    assert_equal before_components.fetch(@converter_root), after_head_move.fetch(@converter_root)
    assert_equal before_components.fetch(@pipeline_artifacts), after_head_move.fetch(@pipeline_artifacts)
    assert_equal before_components.fetch(@source_root), after_head_move.fetch(@source_root)
    assert_equal before_components.dig(@catalog_root, "/catalog.xlsx"),
                 after_head_move.dig(@catalog_root, "/catalog.xlsx")
    assert_equal after_head_move, component_snapshot
    refute_includes JSON.generate(first), "--auto"
  end

  def test_real_pipeline_rejects_conflicting_source_identity_and_unknown_artifact_schema
    declaration = Contract::SOURCE_CHOICES.to_h { |key| [key, nil] }
    declaration["source_id"] = choice("Operation Source")
    operation = create(source_declaration: declaration)
    markdown = File.join(@source_root, "Fixture.md")
    File.binwrite(markdown, "# synthetic fixture\n")
    intake = File.join(@pipeline_artifacts, "source_intake.json")
    write_json(
      intake,
      "schema_version" => "af-source-intake/v0.1",
      "source_root" => @source_root,
      "markdown" => {"filename" => "Fixture.md", "sha256" => Digest::SHA256.file(markdown).hexdigest},
      "registry" => {"registration_status" => "registered",
                     "source_ids_referencing_file" => ["Different Source"]},
      "conversion_provenance" => {"receipt_status" => "accepted",
                                  "conversion_acceptance_verified" => true}
    )
    current = bind(operation, artifact(
      "intake", "source_intake", "af-data-pipeline", "af-source-intake/v0.1",
      "pipeline", "source_intake.json"
    ))

    conflict = composer.compose(ID)
    assert_equal "af-data-pipeline", conflict.dig("diagnostic", "owner")
    assert_equal "COMPONENT_ARTIFACT_CONFLICT", conflict.dig("diagnostic", "code")
    assert_match(/source identity/, conflict.dig("diagnostic", "message"))

    unknown = File.join(@pipeline_artifacts, "unknown.json")
    write_json(unknown, "schema_version" => "unknown/v9")
    changed = advance(current)
    changed["artifacts"] << artifact(
      "unknown", "source_intake", "af-data-pipeline", "af-source-intake/v0.1",
      "pipeline", "unknown.json", supersedes: "intake"
    )
    changed["coordination"]["status"] = "open"
    @store.persist!(changed, expected_revision: current.fetch("revision"),
                    expected_sha256: Contract.digest(current))

    incompatible = composer.compose(ID)
    assert_equal "PIPELINE_FAILURE", incompatible.dig("diagnostic", "code")
    assert_match(/Unsupported JSON ingestion schema/, incompatible.dig("diagnostic", "message"))
  end

  def test_real_pipeline_rejects_conflicting_frozen_base_and_missing_bound_bytes_without_writes
    declaration = Contract::SOURCE_CHOICES.to_h { |key| [key, nil] }
    declaration["source_id"] = choice("Fixture Source")
    operation = create(source_declaration: declaration)
    dossier = File.join(@pipeline_artifacts, "boundary_dossier.json")
    write_json(
      dossier,
      "schema_version" => "af-boundary-dossier/v0.2",
      "source" => {"canonical_source_id" => "Fixture Source"},
      "base_amc" => {"filename" => "different.xlsx", "sha256" => "f" * 64}
    )
    bind(operation, artifact(
      "dossier", "boundary_dossier", "af-data-pipeline", "af-boundary-dossier/v0.2",
      "pipeline", "boundary_dossier.json"
    ))
    before = component_snapshot

    conflict = composer.compose(ID)
    assert_equal "COMPONENT_ARTIFACT_CONFLICT", conflict.dig("diagnostic", "code")
    assert_equal before, component_snapshot

    File.unlink(dossier)
    missing = composer.compose(ID)
    assert_equal "MISSING_BOUND_ARTIFACT", missing.dig("diagnostic", "code")
    assert_equal "adventure-finder", missing.dig("diagnostic", "owner")
  end

  private

  def composer
    Routing.new(
      store: @store,
      project_root: @temporary,
      front_door_root: @front_door_root,
      pipeline_root: @pipeline_proxy,
      source_root: @source_root,
      catalog_root: @catalog_root
    )
  end

  def compose_in_fresh_process
    script = <<~'RUBY'
      require "json"
      require "adventure_finder_ingest_operation_store"
      require "adventure_finder_ingest_routing"
      config = JSON.parse(ARGV.fetch(0))
      store = AdventureFinderWorkspace::IngestOperationStore.new(
        root: config.fetch("store_root"), roots: config.fetch("roots")
      )
      composer = AdventureFinderWorkspace::IngestOperationRouting.new(
        store: store,
        project_root: config.fetch("project_root"),
        front_door_root: config.fetch("front_door_root"),
        pipeline_root: config.fetch("pipeline_root"),
        source_root: config.fetch("source_root"),
        catalog_root: config.fetch("catalog_root")
      )
      puts JSON.generate(composer.compose(config.fetch("operation_id")))
    RUBY
    config = {
      "store_root" => @store_root, "roots" => @roots, "project_root" => @temporary,
      "front_door_root" => @front_door_root, "pipeline_root" => @pipeline_proxy,
      "source_root" => @source_root, "catalog_root" => @catalog_root, "operation_id" => ID
    }
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I#{File.expand_path('../../lib', __dir__)}", "-e", script, JSON.generate(config)
    )
    assert status.success?, stderr
    JSON.parse(stdout)
  end

  def create(source_declaration: nil)
    @store.create(
      operation_id: ID, created_at: NOW,
      input_locator: {"root" => "input", "path" => "book.pdf"},
      base_catalog_locator: {"root" => "catalog", "path" => "catalog.xlsx"},
      catalog_selected_by: "David", catalog_selected_at: NOW,
      source_declaration:
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
    JSON.parse(JSON.generate(document)).tap do |next_revision|
      next_revision["revision"] += 1
      next_revision["previous_revision_sha256"] = Contract.digest(document)
      next_revision["coordination"]["route_observation"] = nil
    end
  end

  def artifact(id, kind, owner, version, root, path, supersedes: nil)
    absolute = File.join(@roots.fetch(root), path)
    {
      "artifact_id" => id, "kind" => kind, "owner" => owner, "contract_version" => version,
      "content" => {"sha256" => Digest::SHA256.file(absolute).hexdigest,
                    "bytes" => File.size(absolute), "locator" => {"root" => root, "path" => path}},
      "inputs" => ["input"], "supersedes" => supersedes
    }
  end

  def choice(value)
    {"value" => value, "selected_by" => "David", "selected_at" => NOW}
  end

  def proxy_pipeline_executable
    path = File.join(@pipeline_proxy, "bin", "af-ingest-next")
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, <<~RUBY)
      #!#{RbConfig.ruby}
      load #{File.join(@pipeline_source, "bin", "af-ingest-next").inspect}
    RUBY
    FileUtils.chmod(0o755, path)
  end

  def write_project_state(head)
    role = {"version" => "fixture", "filename" => File.basename(head),
            "sha256" => Digest::SHA256.file(head).hexdigest, "bytes" => File.size(head)}
    File.binwrite(
      File.join(@catalog_root, "PROJECT_STATE.yml"),
      YAML.dump("schema_version" => "adventurefinder-project-state/v0.2",
                "catalog_head" => role, "matcher_authorized_baseline" => role,
                "production_dependency_floor" => role)
    )
  end

  def write_json(path, document)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, JSON.pretty_generate(document) + "\n")
  end

  def component_snapshot
    [@catalog_root, @converter_root, @pipeline_artifacts, @source_root].to_h do |root|
      files = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
      [root, files.sort.to_h { |path| [path.delete_prefix(root), Digest::SHA256.file(path).hexdigest] }]
    end
  end

  def directory(relative)
    File.join(@temporary, relative).tap { |path| FileUtils.mkdir_p(path) }
  end

  def require_source!(path)
    skip "missing exact pipeline source #{path}" unless File.file?(path)
  end
end
