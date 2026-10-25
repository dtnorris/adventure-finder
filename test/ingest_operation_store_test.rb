# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "adventure_finder_ingest_operation_store"

class IngestOperationStoreTest < Minitest::Test
  Store = AdventureFinderWorkspace::IngestOperationStore
  Contract = AdventureFinderWorkspace::IngestOperation
  Failure = Store::Failure
  ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  NOW = "2026-10-07T00:00:00Z"

  def setup
    @temporary = Dir.mktmpdir("ingest-operation-store")
    @store_root = File.join(@temporary, "front-door", "output", "operations")
    @input_root = File.join(@temporary, "input")
    @catalog_root = File.join(@temporary, "catalog")
    @pipeline_root = File.join(@temporary, "pipeline")
    @converter_root = File.join(@temporary, "converter")
    [@input_root, @catalog_root, @pipeline_root, @converter_root].each { |path| FileUtils.mkdir_p(path) }
    File.binwrite(File.join(@input_root, "book.pdf"), "%PDF synthetic fixture\n")
    File.binwrite(File.join(@catalog_root, "catalog.xlsx"), "synthetic catalog fixture\n")
    @roots = {"input" => @input_root, "catalog" => @catalog_root,
              "pipeline" => @pipeline_root, "converter" => @converter_root}
    @store = Store.new(root: @store_root, roots: @roots)
  end

  def teardown
    FileUtils.remove_entry(@temporary) if File.exist?(@temporary)
  end

  def test_create_reload_validate_and_inspect_unbound_operation
    operation = create
    loaded = Store.new(root: @store_root, roots: @roots).load(ID)
    inspection = @store.inspect(ID)

    assert_equal operation, loaded
    assert_equal operation, @store.validate!(ID)
    assert_equal "VALID", inspection["operation_status"]
    assert_equal "created", inspection["coordination_status"]
    assert_equal "INTENTIONALLY_UNBOUND", inspection["artifact_state"]
    assert_empty inspection["findings"]
    assert_equal %w[base_catalog input], inspection["bindings"].map { |item| item["binding_id"] }.sort
    assert inspection["bindings"].all? { |item| item["status"] == "PRESENT" }
    assert operation["source_declaration"].values.all?(&:nil?)
    assert operation["future_choices"].values.all?(&:nil?)
  end

  def test_identical_creation_replays_without_changing_bytes
    first = create
    path = @store.revision_path(ID, 0)
    bytes = File.binread(path)
    mtime = File.mtime(path)

    replay = create

    assert_equal first, replay
    assert_equal bytes, File.binread(path)
    assert_equal mtime, File.mtime(path)
    assert_equal ["00000000.json"], Dir.children(File.dirname(path)).sort
  end

  def test_conflicting_recreation_and_immutable_revision_are_rejected
    current = create
    File.binwrite(File.join(@input_root, "other.pdf"), "different synthetic input\n")
    collision = assert_raises(Failure) { create(input_path: "other.pdf") }
    assert_equal "CONFLICT", collision.code

    changed = advance(current)
    changed["input"]["content"]["bytes"] += 1
    immutable = assert_raises(Failure) { persist(current, changed) }
    assert_equal "CONFLICT", immutable.code
    assert_equal current, @store.load(ID)
  end

  def test_new_process_reconstructs_the_same_context_without_shell_history
    operation = create
    script = <<~'RUBY'
      require "json"
      require "adventure_finder_ingest_operation_store"
      store = AdventureFinderWorkspace::IngestOperationStore.new(
        root: ARGV.fetch(0), roots: JSON.parse(ARGV.fetch(1))
      )
      operation = store.validate!(ARGV.fetch(2))
      puts AdventureFinderWorkspace::IngestOperation.digest(operation)
    RUBY
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I#{File.expand_path('../lib', __dir__)}", "-e", script,
      @store_root, JSON.generate(@roots), ID
    )

    assert status.success?, stderr
    assert_equal Contract.digest(operation), stdout.strip
  end

  def test_inspection_distinguishes_absent_unbound_and_missing_bound_artifact
    absent = @store.inspect("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
    assert_equal "ABSENT", absent["operation_status"]
    assert_equal "ABSENT", absent["artifact_state"]
    refute File.exist?(@store_root), "read-only absent inspection must not create the store"

    current = create
    assert_equal "INTENTIONALLY_UNBOUND", @store.inspect(ID)["artifact_state"]
    artifact_path = File.join(@converter_root, "receipt.json")
    File.binwrite(artifact_path, "{\"synthetic\":true}\n")
    bound = advance(current)
    bound["artifacts"] << artifact("conversion-receipt", "conversion_receipt", "pdf-to-llm-md-converter",
                                   "pdf-to-llm-md/conversion-receipt/v0.1", "converter", "receipt.json")
    bound["coordination"]["status"] = "open"
    persist(current, bound)
    File.unlink(artifact_path)

    inspection = @store.inspect(ID)
    assert_equal "INVALID", inspection["operation_status"]
    assert_equal "INVALID", inspection["artifact_state"]
    assert_equal ["MISSING_BOUND_ARTIFACT"], inspection["findings"].map { |item| item["code"] }
    assert_equal "conversion-receipt", inspection["findings"].first["binding_id"]
  end

  # Rebinds a private pipeline locator in a fresh process without rewriting the
  # operation. Missing/tampered copies must fail; restored bytes replay exactly.
  def test_private_pipeline_root_rebinding_preserves_identity_on_cold_restart
    current = create
    original = "independently invented private intake artifact\n"
    File.binwrite(File.join(@pipeline_root, "intake.json"), original)
    bound = advance(current)
    bound["artifacts"] << artifact("intake", "source_intake", "af-data-pipeline",
                                  "af-source-intake/v0.1", "pipeline", "intake.json")
    bound["coordination"]["status"] = "open"
    persisted = persist(current, bound)
    revision_bytes = File.binread(@store.revision_path(ID, 1))
    rebound = File.join(@temporary, "af-pipeline-data")
    FileUtils.mv(@pipeline_root, rebound)
    roots = @roots.merge("pipeline" => rebound)
    script = <<~'RUBY'
      require "json"
      require "adventure_finder_ingest_operation_store"
      store = AdventureFinderWorkspace::IngestOperationStore.new(root: ARGV[0], roots: JSON.parse(ARGV[1]))
      puts JSON.generate(store.inspect(ARGV[2]))
    RUBY
    [original, nil, "tampered private intake", original].each do |content|
      path = File.join(rebound, "intake.json")
      content ? File.binwrite(path, content) : File.unlink(path)
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, "-I#{File.expand_path('../lib', __dir__)}", "-e", script,
        @store_root, JSON.generate(roots), ID
      )
      assert status.success?, stderr
      inspection = JSON.parse(stdout)
      if content == original
        assert_equal "VALID", inspection.fetch("operation_status")
        assert_equal persisted, Store.new(root: @store_root, roots:).validate!(ID)
      else
        assert_equal [content ? "STALE_INPUT" : "MISSING_BOUND_ARTIFACT"],
                     inspection.fetch("findings").map { |finding| finding.fetch("code") }
      end
      assert_equal revision_bytes, File.binread(@store.revision_path(ID, 1))
    end
    assert_equal "INVALID", @store.inspect(ID).fetch("operation_status")
  end

  def test_changed_bound_bytes_fail_closed_as_stale_input
    create
    File.binwrite(File.join(@catalog_root, "catalog.xlsx"), "changed catalog fixture\n")

    inspection = @store.inspect(ID)
    assert_equal "INVALID", inspection["operation_status"]
    assert_equal "STALE_INPUT", inspection["findings"].first["code"]
    assert_equal "base_catalog", inspection["findings"].first["binding_id"]
    error = assert_raises(Failure) { @store.validate!(ID) }
    assert_equal "STALE_INPUT", error.code
  end

  def test_invalid_store_and_operation_versions_fail_closed
    create
    metadata = File.join(@store_root, ID, "store.json")
    write_json(metadata, JSON.parse(File.read(metadata)).merge("contract_version" => "unsupported/v9"))
    assert_equal "INCOMPATIBLE_VERSION", @store.inspect(ID)["findings"].first["code"]

    FileUtils.remove_entry(@store_root)
    create
    revision = @store.revision_path(ID, 0)
    write_json(revision, JSON.parse(File.read(revision)).merge("contract_version" => "unsupported/v9"))
    assert_equal "INCOMPATIBLE_VERSION", @store.inspect(ID)["findings"].first["code"]
  end

  def test_corrupt_missing_or_nonconsecutive_operation_data_fail_closed
    create
    revision = @store.revision_path(ID, 0)
    File.binwrite(revision, "{not json")
    assert_equal "CORRUPT_EVIDENCE", @store.inspect(ID)["findings"].first["code"]

    FileUtils.remove_entry(@store_root)
    create
    File.unlink(File.join(@store_root, ID, "store.json"))
    assert_equal "CORRUPT_EVIDENCE", @store.inspect(ID)["findings"].first["code"]

    FileUtils.remove_entry(@store_root)
    current = create
    next_revision = advance(current)
    write_json(@store.revision_path(ID, 2), next_revision.merge("revision" => 2))
    assert_equal "CORRUPT_EVIDENCE", @store.inspect(ID)["findings"].first["code"]
  end

  def test_stale_writer_and_invalid_artifact_reference_cannot_advance
    current = create
    artifact_path = File.join(@pipeline_root, "intake.json")
    File.binwrite(artifact_path, "{\"synthetic\":true}\n")
    next_revision = advance(current)
    next_revision["artifacts"] << artifact("intake", "source_intake", "af-data-pipeline",
                                           "af-source-intake/v0.1", "pipeline", "intake.json")
    next_revision["coordination"]["status"] = "open"

    stale = assert_raises(Failure) do
      @store.persist!(next_revision, expected_revision: 7, expected_sha256: "f" * 64)
    end
    assert_equal "CONFLICT", stale.code

    next_revision["artifacts"].first["owner"] = "adventure-finder"
    invalid = assert_raises(Failure) { persist(current, next_revision) }
    assert_equal "CONFLICT", invalid.code
    assert_equal current, @store.load(ID)
  end

  def test_exact_revision_replay_preserves_bytes
    current = create
    next_revision = advance(current)
    next_revision["source_declaration"]["publisher"] = choice("operator-declared publisher")
    persisted = persist(current, next_revision)
    path = @store.revision_path(ID, 1)
    bytes = File.binread(path)
    mtime = File.mtime(path)

    replay = @store.persist!(persisted, expected_revision: 0, expected_sha256: Contract.digest(current))

    assert_equal persisted, replay
    assert_equal bytes, File.binread(path)
    assert_equal mtime, File.mtime(path)
  end

  def test_exact_revision_replay_still_revalidates_bound_bytes
    current = create
    File.binwrite(File.join(@input_root, "book.pdf"), "changed after binding\n")

    error = assert_raises(Failure) do
      @store.persist!(current, expected_revision: 0, expected_sha256: Contract.digest(current))
    end
    assert_equal "STALE_INPUT", error.code
    assert_equal ["00000000.json"], Dir.children(File.join(@store_root, ID, "revisions")).sort
  end

  def test_failed_revision_write_leaves_no_partial_state_or_loses_prior_record
    current = create
    failing_class = Class.new(Store) do
      private

      def atomic_write(path, bytes)
        raise IOError, "injected write failure" if path.basename.to_s == "00000001.json"

        super
      end
    end
    failing = failing_class.new(root: @store_root, roots: @roots)
    next_revision = advance(current)
    next_revision["source_declaration"]["source_id"] = choice("fixture-source")

    assert_raises(IOError) do
      failing.persist!(next_revision, expected_revision: 0, expected_sha256: Contract.digest(current))
    end
    assert_equal current, @store.load(ID)
    assert_equal ["00000000.json"], Dir.children(File.join(@store_root, ID, "revisions")).sort
  end

  def test_failed_initial_write_does_not_publish_partial_operation
    failing_class = Class.new(Store) do
      private

      def atomic_write(path, bytes)
        raise IOError, "injected initial failure" if path.basename.to_s == "00000000.json"

        super
      end
    end
    failing = failing_class.new(root: @store_root, roots: @roots)

    assert_raises(IOError) { create(store: failing) }
    assert_equal "ABSENT", @store.inspect(ID)["operation_status"]
    refute File.exist?(File.join(@store_root, ID))
    assert_empty Dir.glob(File.join(@store_root, ".#{ID}.tmp-*"))
  end

  def test_component_artifact_is_a_reference_not_a_copied_fact
    current = create
    artifact_path = File.join(@pipeline_root, "source-intake.json")
    File.binwrite(artifact_path, "{\"contract_version\":\"af-source-intake/v0.1\",\"fixture\":true}\n")
    next_revision = advance(current)
    next_revision["artifacts"] << artifact("source-intake", "source_intake", "af-data-pipeline",
                                           "af-source-intake/v0.1", "pipeline", "source-intake.json")
    next_revision["coordination"]["status"] = "open"
    persisted = persist(current, next_revision)

    reference = persisted["artifacts"].first
    assert_equal %w[artifact_id content contract_version inputs kind owner supersedes], reference.keys.sort
    refute_includes JSON.generate(persisted), "fixture"
    assert_equal Digest::SHA256.file(artifact_path).hexdigest, reference.dig("content", "sha256")
    assert_equal "af-data-pipeline", @store.inspect(ID)["bindings"].last["owner"]
  end

  def test_catalog_head_binds_and_revalidates_project_state_reference
    project_state = File.join(@catalog_root, "PROJECT_STATE.yml")
    File.binwrite(project_state, "synthetic: state\n")
    operation = create(catalog_selection_method: "catalog_head",
                       project_state_locator: {"root" => "catalog", "path" => "PROJECT_STATE.yml"})

    assert_equal "adventurefinder-project-state/v0.2",
                 operation.dig("base_catalog", "selection", "project_state", "contract_version")
    assert_equal %w[base_catalog input project_state],
                 @store.inspect(ID)["bindings"].map { |entry| entry["binding_id"] }.sort
  end

  def test_inspection_is_read_only_and_locator_escape_is_rejected
    create
    before = tree_snapshot(@store_root)
    assert_equal "VALID", @store.inspect(ID)["operation_status"]
    assert_equal before, tree_snapshot(@store_root)

    outside = File.join(@temporary, "outside.json")
    File.binwrite(outside, "outside\n")
    File.symlink(outside, File.join(@pipeline_root, "escape.json"))
    current = @store.load(ID)
    next_revision = advance(current)
    next_revision["artifacts"] << artifact("escape", "source_intake", "af-data-pipeline",
                                           "af-source-intake/v0.1", "pipeline", "escape.json")
    next_revision["coordination"]["status"] = "open"
    error = assert_raises(Failure) { persist(current, next_revision) }
    assert_equal "CORRUPT_EVIDENCE", error.code
  end

  def test_missing_path_beneath_escaping_symlink_is_not_misclassified_as_missing
    create
    outside = File.join(@temporary, "outside")
    FileUtils.mkdir_p(outside)
    File.symlink(outside, File.join(@pipeline_root, "escaped-directory"))
    current = @store.load(ID)
    next_revision = advance(current)
    content = {"sha256" => "f" * 64, "bytes" => 1,
               "locator" => {"root" => "pipeline", "path" => "escaped-directory/missing.json"}}
    next_revision["artifacts"] << {
      "artifact_id" => "escape", "kind" => "source_intake", "owner" => "af-data-pipeline",
      "contract_version" => "af-source-intake/v0.1", "content" => content,
      "inputs" => ["input"], "supersedes" => nil
    }
    next_revision["coordination"]["status"] = "open"

    error = assert_raises(Failure) { persist(current, next_revision) }
    assert_equal "CORRUPT_EVIDENCE", error.code
  end

  private

  def create(store: @store, input_path: "book.pdf", catalog_selection_method: "explicit",
             project_state_locator: nil)
    store.create(
      operation_id: ID, created_at: NOW,
      input_locator: {"root" => "input", "path" => input_path},
      base_catalog_locator: {"root" => "catalog", "path" => "catalog.xlsx"},
      catalog_selected_by: "David", catalog_selected_at: NOW,
      catalog_selection_method: catalog_selection_method,
      project_state_locator: project_state_locator
    )
  end

  def advance(document)
    copy(document).tap do |next_revision|
      next_revision["revision"] += 1
      next_revision["previous_revision_sha256"] = Contract.digest(document)
      next_revision["coordination"]["route_observation"] = nil
    end
  end

  def persist(previous, current)
    @store.persist!(current, expected_revision: previous.fetch("revision"),
                    expected_sha256: Contract.digest(previous))
  end

  def artifact(id, kind, owner, version, root, path)
    bytes = File.binread(File.join(@roots.fetch(root), path))
    {
      "artifact_id" => id, "kind" => kind, "owner" => owner, "contract_version" => version,
      "content" => {"sha256" => Digest::SHA256.hexdigest(bytes), "bytes" => bytes.bytesize,
                    "locator" => {"root" => root, "path" => path}},
      "inputs" => ["input"], "supersedes" => nil
    }
  end

  def choice(value)
    {"value" => value, "selected_by" => "David", "selected_at" => NOW}
  end

  def copy(value)
    JSON.parse(JSON.generate(value))
  end

  def write_json(path, document)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(document) + "\n")
  end

  def tree_snapshot(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)
       .reject { |path| [".", ".."].include?(File.basename(path)) }
       .sort.to_h { |path| [path.delete_prefix(root), [File.stat(path).mode, File.stat(path).size, File.mtime(path)]] }
  end
end
