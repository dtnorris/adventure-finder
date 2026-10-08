# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "adventure_finder_successor_version_authorization"

class SuccessorVersionAuthorizationTest < Minitest::Test
  AuthorityStore = AdventureFinderWorkspace::SuccessorVersionAuthorizationStore
  OperationStore = AdventureFinderWorkspace::IngestOperationStore
  Operation = AdventureFinderWorkspace::IngestOperation
  Failure = AuthorityStore::Failure
  ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  OTHER_ID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  NOW = "2026-10-07T10:00:00Z"

  def setup
    @temporary = Dir.mktmpdir("successor-version-authorization")
    @operation_root = File.join(@temporary, "front", "output", "ingest-operations", "v0.1")
    @authority_root = File.join(@temporary, "front", "output", "ingest-authorities", "successor-version", "v0.1")
    @input_root = directory("input")
    @catalog_root = directory("catalog")
    @pipeline_root = directory("pipeline")
    File.binwrite(File.join(@input_root, "book.pdf"), "%PDF fixture\n")
    File.binwrite(File.join(@catalog_root, "catalog.xlsx"), "base catalog fixture\n")
    @roots = {"input" => @input_root, "catalog" => @catalog_root, "pipeline" => @pipeline_root}
    @operations = OperationStore.new(root: @operation_root, roots: @roots)
    @authorities = authority_store
  end

  def teardown
    FileUtils.remove_entry(@temporary) if File.exist?(@temporary)
  end

  def test_binds_versioned_authority_to_exact_operation_and_base_without_rewriting_history
    operation = create
    before = revision_snapshot(ID)

    authorization = @authorities.bind!(
      operation_id: ID, successor_version: "7.5.2", selected_by: "David"
    )
    projection = @authorities.projection(ID)

    assert_equal AuthorityStore::VERSION, authorization["contract_version"]
    assert_equal ID, authorization.dig("operation", "operation_id")
    assert_equal Operation::VERSION, authorization.dig("operation", "contract_version")
    assert_equal operation["created_at"], authorization.dig("operation", "created_at")
    assert_equal operation.dig("base_catalog", "content").slice("sha256", "bytes"),
                 authorization["base_catalog"]
    assert_equal "7.5.2", authorization["successor_version"]
    assert_equal "David", authorization["selected_by"]
    assert_equal NOW, authorization["selected_at"]
    assert_equal Operation.digest(authorization.except("authorization_id")), authorization["authorization_id"]
    assert_equal AuthorityStore::PROJECTION_VERSION, projection["contract_version"]
    assert_equal authorization, projection["authorization"]
    assert_equal before, revision_snapshot(ID)
  end

  def test_unbound_legacy_operation_remains_valid_and_policy_values_are_not_authority
    policy = {
      "policy_id" => "fixture-policy", "policy_version" => "v0.1",
      "definition_sha256" => "e" * 64,
      "selected_values" => {"successor_version" => "99.99", "execution" => "deferred"},
      "selected_by" => "David", "selected_at" => NOW
    }
    operation = create(policy:)

    assert_equal operation, @operations.validate!(ID)
    assert_equal "UNBOUND", @authorities.inspect(ID)["authority_status"]
    error = assert_raises(Failure) { @authorities.fetch!(ID) }
    assert_equal "SUCCESSOR_VERSION_AUTHORITY_NOT_BOUND", error.code
    refute File.exist?(@authority_root)
  end

  def test_identical_replay_is_byte_stable_and_conflicting_rebinding_fails_closed
    create
    first = @authorities.bind!(operation_id: ID, successor_version: "7.5.2", selected_by: "David")
    path = @authorities.authorization_path(ID)
    bytes = File.binread(path)
    mtime = File.mtime(path)

    replay = @authorities.bind!(operation_id: ID, successor_version: "7.5.2", selected_by: "David")

    assert_equal first, replay
    assert_equal bytes, File.binread(path)
    assert_equal mtime, File.mtime(path)
    version_conflict = assert_raises(Failure) do
      @authorities.bind!(operation_id: ID, successor_version: "7.5.3", selected_by: "David")
    end
    assert_equal "SUCCESSOR_VERSION_AUTHORITY_CONFLICT", version_conflict.code
    selector_conflict = assert_raises(Failure) do
      @authorities.bind!(operation_id: ID, successor_version: "7.5.2", selected_by: "Other")
    end
    assert_equal "SUCCESSOR_VERSION_AUTHORITY_CONFLICT", selector_conflict.code
    assert_equal bytes, File.binread(path)
  end

  def test_malformed_or_placeholder_versions_fail_before_authority_mutation
    create

    ["", "VERSION", "7", "7.1.beta", "../7.1.2", " 7.5.2"].each do |version|
      error = assert_raises(Failure) do
        @authorities.bind!(operation_id: ID, successor_version: version, selected_by: "David")
      end
      assert_equal "INVALID_SUCCESSOR_VERSION", error.code
    end
    selector = assert_raises(Failure) do
      @authorities.bind!(operation_id: ID, successor_version: "7.5.2", selected_by: "")
    end
    assert_equal "MISSING_CHOICE", selector.code
    refute File.exist?(@authority_root)
  end

  def test_explicit_syntactic_value_is_recorded_without_increment_policy
    operation = create

    authorization = @authorities.bind!(
      operation_id: ID, successor_version: "42.0.0.7", selected_by: "David"
    )

    assert_equal "42.0.0.7", authorization["successor_version"]
    assert_equal operation.dig("base_catalog", "content").slice("sha256", "bytes"),
                 authorization["base_catalog"]
  end

  def test_authority_cannot_float_to_another_base_or_survive_changed_base_bytes
    create
    original = @authorities.bind!(operation_id: ID, successor_version: "7.5.2", selected_by: "David")
    File.binwrite(File.join(@catalog_root, "other.xlsx"), "different base catalog\n")
    create(operation_id: OTHER_ID, catalog_path: "other.xlsx")
    target = File.join(@authority_root, OTHER_ID)
    FileUtils.cp_r(File.join(@authority_root, ID), target)
    metadata = JSON.parse(File.binread(File.join(target, "store.json")))
    metadata["operation_id"] = OTHER_ID
    File.binwrite(File.join(target, "store.json"), JSON.pretty_generate(metadata) + "\n")

    conflict = assert_raises(Failure) { @authorities.fetch!(OTHER_ID) }
    assert_equal "SUCCESSOR_VERSION_AUTHORITY_PROVENANCE_CONFLICT", conflict.code

    File.binwrite(File.join(@catalog_root, "catalog.xlsx"), "changed base catalog\n")
    inspection = @authorities.inspect(ID)
    assert_equal "INVALID", inspection["authority_status"]
    assert_equal "STALE_INPUT", inspection.dig("findings", 0, "code")
    assert_equal original["authorization_id"], JSON.parse(File.binread(@authorities.authorization_path(ID)))["authorization_id"]
  end

  def test_missing_corrupt_and_incompatible_authority_bytes_fail_closed
    create
    bind
    File.unlink(@authorities.authorization_path(ID))
    assert_invalid("CORRUPT_SUCCESSOR_VERSION_AUTHORITY")

    FileUtils.remove_entry(@authority_root)
    bind
    File.binwrite(@authorities.authorization_path(ID), "{not json")
    assert_invalid("CORRUPT_SUCCESSOR_VERSION_AUTHORITY")

    FileUtils.remove_entry(@authority_root)
    bind
    path = @authorities.authorization_path(ID)
    document = JSON.parse(File.binread(path))
    document["contract_version"] = "adventurefinder-successor-version-authorization/v9"
    File.binwrite(path, JSON.pretty_generate(document) + "\n")
    assert_invalid("INCOMPATIBLE_SUCCESSOR_VERSION_AUTHORITY")
  end

  def test_removed_authority_directory_does_not_revert_to_unbound
    create
    bind
    FileUtils.remove_entry(File.dirname(@authorities.authorization_path(ID)))

    assert_invalid("CORRUPT_SUCCESSOR_VERSION_AUTHORITY")
    error = assert_raises(Failure) { bind }
    assert_equal "CORRUPT_SUCCESSOR_VERSION_AUTHORITY", error.code
  end

  def test_later_operation_advancement_does_not_stale_authority
    operation = create
    authorization = bind
    File.binwrite(File.join(@pipeline_root, "intake.json"), "pipeline fixture\n")
    advanced = copy(operation)
    advanced["revision"] = 1
    advanced["previous_revision_sha256"] = Operation.digest(operation)
    advanced["artifacts"] << artifact("intake", "intake.json")
    advanced["coordination"]["status"] = "open"
    @operations.persist!(advanced, expected_revision: 0, expected_sha256: Operation.digest(operation))

    assert_equal authorization, @authorities.fetch!(ID)
    assert_equal "BOUND", @authorities.inspect(ID)["authority_status"]
    stale = copy(advanced)
    stale["revision"] = 2
    stale["previous_revision_sha256"] = Operation.digest(advanced)
    error = assert_raises(OperationStore::Failure) do
      @operations.persist!(stale, expected_revision: 0, expected_sha256: Operation.digest(operation))
    end
    assert_equal "CONFLICT", error.code
    assert_equal authorization, @authorities.fetch!(ID)
  end

  def test_fresh_process_reconstructs_the_same_public_projection_without_shell_history
    create
    expected = bind
    script = <<~'RUBY'
      require "json"
      require "adventure_finder_successor_version_authorization"
      operations = AdventureFinderWorkspace::IngestOperationStore.new(
        root: ARGV.fetch(0), roots: JSON.parse(ARGV.fetch(1))
      )
      authorities = AdventureFinderWorkspace::SuccessorVersionAuthorizationStore.new(
        root: ARGV.fetch(2), operation_store: operations
      )
      puts JSON.generate(authorities.projection(ARGV.fetch(3)))
    RUBY

    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I#{File.expand_path('../lib', __dir__)}", "-e", script,
      @operation_root, JSON.generate(@roots), @authority_root, ID,
      chdir: directory("distinct-working-directory")
    )

    assert status.success?, stderr
    projection = JSON.parse(stdout)
    assert_equal AuthorityStore::PROJECTION_VERSION, projection["contract_version"]
    assert_equal expected, projection["authorization"]
  end

  def test_concurrent_conflicting_bind_selects_exactly_one_authority
    create
    ready = Queue.new
    results = Queue.new
    threads = %w[7.5.2 7.5.3].map do |version|
      Thread.new do
        ready << true
        begin
          results << authority_store.bind!(operation_id: ID, successor_version: version, selected_by: "David")
        rescue Failure => e
          results << e
        end
      end
    end
    2.times { ready.pop }
    threads.each(&:join)
    outcomes = 2.times.map { results.pop }

    assert_equal 1, outcomes.count { |result| result.is_a?(Hash) }
    assert_equal ["SUCCESSOR_VERSION_AUTHORITY_CONFLICT"],
                 outcomes.grep(Failure).map(&:code)
    assert_includes %w[7.5.2 7.5.3], @authorities.fetch!(ID)["successor_version"]
  end

  private

  def authority_store
    AuthorityStore.new(
      root: @authority_root,
      operation_store: @operations,
      clock: -> { Time.iso8601(NOW) }
    )
  end

  def create(operation_id: ID, catalog_path: "catalog.xlsx", policy: nil)
    @operations.create(
      operation_id:, created_at: NOW,
      input_locator: {"root" => "input", "path" => "book.pdf"},
      base_catalog_locator: {"root" => "catalog", "path" => catalog_path},
      catalog_selected_by: "David", catalog_selected_at: NOW, policy:
    )
  end

  def bind
    @authorities.bind!(operation_id: ID, successor_version: "7.5.2", selected_by: "David")
  end

  def assert_invalid(code)
    inspection = @authorities.inspect(ID)
    assert_equal "INVALID", inspection["authority_status"]
    assert_equal code, inspection.dig("findings", 0, "code")
    error = assert_raises(Failure) { @authorities.fetch!(ID) }
    assert_equal code, error.code
  end

  def revision_snapshot(operation_id)
    directory = File.join(@operation_root, operation_id, "revisions")
    Dir.glob(File.join(directory, "*.json")).sort.to_h do |path|
      [File.basename(path), Digest::SHA256.file(path).hexdigest]
    end
  end

  def artifact(id, path)
    absolute = File.join(@pipeline_root, path)
    {
      "artifact_id" => id, "kind" => "source_intake", "owner" => "af-data-pipeline",
      "contract_version" => "af-source-intake/v0.1",
      "content" => {"sha256" => Digest::SHA256.file(absolute).hexdigest,
                    "bytes" => File.size(absolute), "locator" => {"root" => "pipeline", "path" => path}},
      "inputs" => ["input"], "supersedes" => nil
    }
  end

  def directory(name)
    File.join(@temporary, name).tap { |path| FileUtils.mkdir_p(path) }
  end

  def copy(value)
    JSON.parse(JSON.generate(value))
  end
end
