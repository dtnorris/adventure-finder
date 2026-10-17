# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "securerandom"
require "tmpdir"
require "yaml"
require_relative "../lib/adventure_finder_ingest_operation_store"
require_relative "../lib/adventure_finder_ingest_routing"
require_relative "../test/support/ig07c_source_acceptance_fixture"
require_relative "../test/support/ig19d_disposable_git"
require_relative "../test/support/ig19_git_fixture"

class Ig19dRestartPromotionTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PIPELINE = File.expand_path(ENV.fetch("AF_DATA_PIPELINE_ROOT"))
  ID = "11111111-1111-4111-8111-111111111111"
  Store = AdventureFinderWorkspace::IngestOperationStore
  Contract = AdventureFinderWorkspace::IngestOperation

  def setup
    $LOAD_PATH.unshift(File.join(PIPELINE, "lib"))
    require "af_data_pipeline"
    require File.join(PIPELINE, "test/support/standing_bulk_score_release_fixture")
    @temporary = Dir.mktmpdir("ig19d-proof-")
    @elsewhere = File.join(@temporary, "restart cwd")
    FileUtils.mkdir_p(@elsewhere)
    @commands = []
    @rows = []
    @trace_directory = Dir.mktmpdir("ig19 git observations ")
    @git_trace = File.join(@trace_directory, "native-git.jsonl")
    @previous_git_environment = ENV.to_h.slice("GIT_OPTIONAL_LOCKS", "GIT_TRACE2_EVENT")
    ENV["GIT_OPTIONAL_LOCKS"] = "0"
    ENV["GIT_TRACE2_EVENT"] = @git_trace
  end

  def teardown
    native_commands = File.file?(@git_trace) ? File.readlines(@git_trace).map { |line| JSON.parse(line) }
      .select { |event| event["event"] == "start" }.map { |event| event.fetch("argv") } : []
    puts "IG-19 native Git observations: #{JSON.generate(native_commands)}"
    %w[GIT_OPTIONAL_LOCKS GIT_TRACE2_EVENT].each { |key| ENV[key] = @previous_git_environment[key] }
    FileUtils.remove_entry(@trace_directory)
    puts "IG-19D evidence: #{JSON.generate(rows: @rows, commands: @commands,
      totals: %w[PASS FAIL BLOCKED].to_h { |state| [state, @rows.count { |row| row[:status] == state }] })}"
    @source_fixture&.close
    @catalog_fixture&.close
    if @rows.any? { |entry| entry[:status] == "FAIL" }
      puts "IG-19D retained failure fixture: #{@temporary}"
    elsif @temporary && File.directory?(@temporary)
      FileUtils.remove_entry(@temporary)
    end
  end

  def test_disposable_git_guard_refuses_real_and_symlinked_targets
    row("fixture-git-boundary", "synthetic Git mutation", "verified disposable root required",
        "refusal outside marked fixtures", "no Git mutation", "choose a verified temporary repository") do
      token = SecureRandom.hex(32)
      File.binwrite(File.join(@temporary, ".ig19d-disposable"), token)
      previous = ENV.to_h.slice("IG19D_FIXTURE_ROOT", "IG19D_FIXTURE_TOKEN")
      begin
        ENV["IG19D_FIXTURE_ROOT"] = @temporary
        ENV["IG19D_FIXTURE_TOKEN"] = token
        error = assert_raises(RuntimeError) { Ig19dDisposableGit.check!(["git", "-C", ROOT, "commit", "-m", "forbidden"]) }
        assert_includes error.message, "outside disposable fixtures"
        link = File.join(@temporary, "real-checkout")
        File.symlink(ROOT, link)
        error = assert_raises(RuntimeError) { Ig19dDisposableGit.check!(["/usr/bin/git", "-C", link, "add", "."]) }
        assert_includes error.message, "outside disposable fixtures"
        error = assert_raises(RuntimeError) { Ig19dDisposableGit.check!(["git", "push", "origin", "main"]) }
        assert_includes error.message, "unsupported Git command"
        error = assert_raises(RuntimeError) { Ig19dDisposableGit.check!(["git", "--git-dir", File.join(ROOT, ".git"), "commit"]) }
        assert_includes error.message, "unsupported Git command"
        error = assert_raises(RuntimeError) { Ig19dDisposableGit.check!(["git", "clone", "https://github.com/example/repo", File.join(@temporary, "clone")]) }
        assert_includes error.message, "explicit local source and destination"
      ensure
        %w[IG19D_FIXTURE_ROOT IG19D_FIXTURE_TOKEN].each { |name| ENV[name] = previous[name] }
      end
    end
  end

  def test_operation_creation_and_immutable_intent_use_public_store_in_a_fresh_process
    roots = Contract::ROOTS.to_h do |name|
      directory = File.join(@temporary, name)
      FileUtils.mkdir_p(directory)
      [name, directory]
    end
    File.write(File.join(roots.fetch("input"), "synthetic.pdf"), "%PDF synthetic non-narrative\n")
    File.write(File.join(roots.fetch("catalog"), "synthetic.xlsx"), "creation binding only\n")
    store_path = Store.default_root(front_door_root: roots.fetch("front_door")).to_s
    store = Store.new(root: store_path, roots:)
    operation = store.create(operation_id: ID, input_locator: {"root" => "input", "path" => "synthetic.pdf"},
      base_catalog_locator: {"root" => "catalog", "path" => "synthetic.xlsx"}, catalog_selected_by: "Synthetic operator")
    control = AdventureFinderWorkspace::IngestOperationRouting.new(store:, project_root: @temporary,
      front_door_root: roots.fetch("front_door"), pipeline_root: PIPELINE,
      source_root: roots.fetch("source"), catalog_root: roots.fetch("catalog")).compose(ID)
    row("operation-created", "public Store.create", "revision zero; no component artifact",
        "NEEDS_FIRST_COMPONENT_ARTIFACT", "read-only inspection", "produce the first component artifact") do
      script = <<~'RUBY'
        require "json"
        require "adventure_finder_ingest_operation_store"
        require "adventure_finder_ingest_routing"
        path, serialized, pipeline, id = ARGV
        roots = JSON.parse(serialized)
        store = AdventureFinderWorkspace::IngestOperationStore.new(root: path, roots: roots)
        result = AdventureFinderWorkspace::IngestOperationRouting.new(store: store,
          project_root: File.dirname(roots.fetch("front_door")), front_door_root: roots.fetch("front_door"),
          pipeline_root: pipeline, source_root: roots.fetch("source"), catalog_root: roots.fetch("catalog")).compose(id)
        puts JSON.generate(result)
      RUBY
      stdout, stderr, status = capture({}, RbConfig.ruby, "-I#{ROOT}/lib", "-e", script,
        store_path, JSON.generate(roots), PIPELINE, ID)
      assert status.success?, stderr
      assert_equal control, JSON.parse(stdout)
      assert_equal "NEEDS_FIRST_COMPONENT_ARTIFACT", control.dig("gate", "state")
      assert_equal operation, store.inspect(ID).fetch("operation")
      @rows.last[:identities] = operation.slice("operation_id", "revision", "input", "base_catalog")
    end
    row("immutable-operation-intent", "changed operation input", "created durable operation",
        "CONFLICT", "refusal only", "create separately authorized intent") do
      changed = Marshal.load(Marshal.dump(operation))
      changed["revision"] = 1
      changed["previous_revision_sha256"] = Contract.digest(operation)
      changed.dig("input", "content")["sha256"] = "a" * 64
      error = assert_raises(Store::Failure) do
        store.persist!(changed, expected_revision: 0, expected_sha256: Contract.digest(operation))
      end
      assert_equal "CONFLICT", error.code
      assert_equal operation, store.inspect(ID).fetch("operation")
    end
  end

  def test_source_registration_dossier_and_editorial_restart_preserve_completed_work
    @source_fixture = Ig07cSourceAcceptance::Fixture.new(repository_root: ROOT, pipeline_source_root: PIPELINE)
    fixture = @source_fixture
    stdout, stderr, status = fixture.start
    assert status.success?, "#{stderr}\n#{stdout}"
    assert_includes stdout, "Gate: BOUNDARY_EDITORIAL_REVIEW"
    roots = {"input" => File.dirname(fixture.pdf), "front_door" => fixture.front,
      "pipeline" => fixture.pipeline, "converter" => fixture.converter,
      "source" => fixture.source, "catalog" => fixture.catalog}
    store = Store.new(root: Store.default_root(front_door_root: fixture.front), roots:)
    operation = store.inspect(Ig07cSourceAcceptance::Fixture::OPERATION_ID).fetch("operation")
    before = public_source_snapshot(fixture)
    calls = fixture.progress_calls
    row("source-dossier-editorial-restart", "real public source progression", "registered source and dossier",
        "BOUNDARY_EDITORIAL_REVIEW", "read-only replay", "complete boundary editorial review") do
      2.times do
        resumed, error, result = fixture.resume("IG07C_PROGRESS_MODE" => nil, "IG07C_RECEIPT_MODE" => nil,
          "IG07C_MARKDOWN_MODE" => nil, "AF_TEST_CONTENDED" => nil)
        assert result.success?, error
        assert_includes resumed, "Gate: BOUNDARY_EDITORIAL_REVIEW"
        assert_equal operation, store.inspect(operation.fetch("operation_id")).fetch("operation")
        assert_equal before, public_source_snapshot(fixture)
        assert_equal calls, fixture.progress_calls
      end
      assert_empty fixture.forbidden_calls
      @rows.last[:identities] = operation.slice("operation_id", "revision", "source_declaration", "base_catalog", "artifacts")
      @rows.last[:preserved_hashes] = before
      @rows.last[:completed_work_invocations] = calls.map { |entry| entry.fetch("artifact") }.tally
    end
    row("pipeline-artifact-staleness", "changed bound source intake bytes", "completed source progression",
        "STALE_INPUT", "diagnostic only", "resolve changed producer evidence without rebind") do
      original = File.binread(fixture.source_intake_path)
      File.binwrite(fixture.source_intake_path, original + "changed\n")
      resumed, _error, result = fixture.resume
      assert_equal 2, result.exitstatus
      assert_includes resumed, "Diagnostic: STALE_INPUT"
      assert_equal calls, fixture.progress_calls
      File.binwrite(fixture.source_intake_path, original)
      assert_equal before, public_source_snapshot(fixture)
      assert_equal operation, store.inspect(operation.fetch("operation_id")).fetch("operation")
    end
  end

  def test_standing_finalization_final_review_promotion_and_fresh_replay
    fixture = build_standing_fixture
    # Supported owner fixture establishes boundary/staging and synthetic AFW
    # evidence. This is producer setup, not an automatic execution journey.
    release = fixture.release
    release_before = snapshot(fixture.output_dir)
    row("standing-application-finalization-restart", "exact completed standing release", "owner fixture plus real release writer",
        "verified existing release", "read-only replay", "prepare final release package") do
      stdout, stderr, status = capture({}, RbConfig.ruby, File.join(PIPELINE, "bin/af-standing-bulk-score-release"),
        "--inputs", fixture.inputs_path, "--output", fixture.output_dir)
      assert status.success?, stderr
      assert_includes stdout, "Replay: verified existing release"
      assert_equal release_before, snapshot(fixture.output_dir)
      counts = release.manifest.fetch("counts")
      assert_equal 4, counts.fetch("standing_directive_accepted")
      assert_equal 0, counts.fetch("individual_human_accepted")
      assert_equal 0, counts.fetch("ig16b_machine_accepted")
      @rows.last[:identities] = release.manifest.slice("manifest_id", "operation", "standing_policy", "artifacts", "counts")
      @rows.last[:preserved_hashes] = release_before
    end
    catalog = File.join(@temporary, "disposable catalog")
    @catalog_fixture = Ig19GitFixture.load("standing", catalog)
    roles = YAML.safe_load_file(File.join(catalog, "PROJECT_STATE.yml"))
    # Qualify the exact owner release inputs before the public proof interval.
    (["PROJECT_STATE.yml"] + roles.values.grep(Hash).map { |role| role.fetch("filename") }).uniq.each do |name|
      assert_equal File.binread(File.join(@temporary, name)), File.binread(File.join(catalog, name)), name
    end
    File.write(File.join(catalog, "unrelated.txt"), "preserved unrelated operator file\n")
    preserved = snapshot(catalog).reject { |name, _| name.start_with?(".git/") }
    identity = git_identity(catalog)
    literal_index = File.binread(File.join(catalog, ".git/index"))
    inputs = File.join(@temporary, "package-inputs.json")
    package_path = File.join(@temporary, "package.json")
    File.write(inputs, JSON.pretty_generate(
      "schema_version" => AfDataPipeline::FinalReleasePackage::INPUT_SCHEMA,
      "release_inputs_path" => fixture.inputs_path,
      "release_manifest_path" => File.join(fixture.output_dir, "release-accounting.json"),
      "catalog_repository_root" => catalog,
      "current_project_state_path" => File.join(catalog, "PROJECT_STATE.yml"), "frontier_result_path" => nil) + "\n")
    package = AfDataPipeline::FinalReleasePackage.prepare!(inputs_path: inputs, output_path: package_path).package
    assert_equal identity, git_identity(catalog)
    assert package.dig("readiness", "ready")
    assert_equal "original_ig17", package.dig("candidate", "selection")
    assert_equal package, AfDataPipeline::FinalReleasePackage.validate!(inputs_path: inputs, package_path: package_path).package
    assert_equal identity, git_identity(catalog)
    operation_dir = File.join(@temporary, "promotion")
    front_env = {"AF_ADVENTURE_FINDER_ROOT" => File.join(@temporary, "front door"), "AF_DATA_PIPELINE_ROOT" => PIPELINE}
    command = [RbConfig.ruby, File.join(ROOT, "bin/af-catalog"), "final-promotion",
      "--inputs", inputs, "--package", package_path, "--approver", "Synthetic operator", "--operation-dir", operation_dir]
    row("final-review-before-approval-restart", "unchanged reviewed release package", "READY package; no approval",
        "AWAITING_APPROVAL", "retained request only", "explicit final-promotion approval") do
      2.times do
        stdout, stderr, status = capture(front_env, *command)
        @rows.last[:actual] = {exitstatus: status.exitstatus, stdout:, stderr:}
        if status.exitstatus == 2 && stderr.include?("AMC cross-consumer compatibility failed")
          @rows.last.merge!(classification: "D", owner: "af-data-pipeline",
            violated_contract: "READY final package must carry scored-new-ID authorization to adoption preparation",
            earlier_task_review: "IG-18A3 and IG-18C", follow_up: "pipeline-owned adoption compatibility provenance handoff")
        end
        assert_equal 3, status.exitstatus, "#{stderr}\n#{stdout}"
        assert_includes stdout, "No approval recorded."
        assert_equal identity, git_identity(catalog)
        assert_equal preserved, snapshot(catalog).reject { |name, _| name.start_with?(".git/") }
        refute File.exist?(File.join(operation_dir, "adoption-decision.json"))
      end
      @rows.last[:identities] = {package_id: package.fetch("package_id"),
        request: JSON.parse(File.read(File.join(operation_dir, "adoption-request.json")))}
    end
    # Corrupt only qualified disposable inputs between public proof intervals.
    # Each refusal must leave the reviewed package/request and application intact.
    manifest_path = File.join(catalog, "PROJECT_STATE.yml")
    base_path = File.join(catalog, roles.dig("catalog_head", "filename"))
    %w[dirty-reviewed-manifest dirty-reviewed-workbook mismatched-committed-binding].each do |scenario|
      original_manifest = File.binread(manifest_path)
      original_base = File.binread(base_path)
      if scenario == "dirty-reviewed-manifest"
        File.binwrite(manifest_path, original_manifest + "\n")
      else
        File.binwrite(base_path, original_base + "changed")
        if scenario == "mismatched-committed-binding"
          changed = YAML.safe_load(original_manifest)
          changed.values.grep(Hash).each { |binding| binding.merge!(AfDataPipeline::StandingBulkScorePolicy.file_binding(base_path)) }
          File.binwrite(manifest_path, YAML.dump(changed))
        end
      end
      before = snapshot(@temporary)
      row(scenario, scenario, "exact retained review; altered disposable input",
          "hard refusal", "no partial application", "restore exact reviewed inputs") do
        stdout, stderr, status = capture(front_env, *command, stdin_data: "APPROVE\n")
        assert_equal 2, status.exitstatus, "#{stderr}\n#{stdout}"
        assert_equal before, snapshot(@temporary)
        refute File.exist?(File.join(operation_dir, "adoption-decision.json"))
        refute File.exist?(File.join(operation_dir, "adoption-result.json"))
        assert_equal identity, git_identity(catalog)
      end
    ensure
      File.binwrite(manifest_path, original_manifest)
      File.binwrite(base_path, original_base)
    end
    row("same-label-candidate-drift", "changed candidate bytes after review", "retained request; no approval",
        "hard stale refusal", "diagnostic only", "restore evidence or prepare fresh review") do
      candidate = package.dig("candidate", "selected", "path")
      original = File.binread(candidate)
      File.binwrite(candidate, original + "changed")
      stdout, stderr, status = capture(front_env, *command, stdin_data: "APPROVE\n")
      assert_equal 2, status.exitstatus, stdout
      assert_match(/changed|binding|hash|evidence|provenance/i, stderr)
      assert_equal identity, git_identity(catalog)
      refute File.exist?(File.join(operation_dir, "adoption-decision.json"))
      File.binwrite(candidate, original)
    end
    row("exact-local-promotion", "explicit APPROVE", "unchanged package and retained review request",
        "PROMOTED", "exact candidate import and catalog_head only", "Git persistence remains separate") do
      stdout, stderr, status = capture(front_env, *command, stdin_data: "APPROVE\n")
      assert status.success?, "#{stderr}\n#{stdout}"
      assert_includes stdout, "Final promotion: PROMOTED."
      assert_equal identity, git_identity(catalog)
      assert_equal literal_index, File.binread(File.join(catalog, ".git/index"))
      current_roles = YAML.safe_load_file(File.join(catalog, "PROJECT_STATE.yml"))
      assert_equal roles.except("catalog_head"), current_roles.except("catalog_head")
      assert_equal package.dig("candidate", "selected", "sha256"), current_roles.dig("catalog_head", "sha256")
      preserved.except("PROJECT_STATE.yml").each do |name, binding|
        assert_equal binding, file_binding(File.join(catalog, name))
      end
      @rows.last[:identities] = JSON.parse(File.read(File.join(operation_dir, "adoption-result.json")))
    end
    row("promoted-front-door-fresh-replay", "unchanged successful local promotion", "exact retained approval and promoted result",
        "ALREADY_PROMOTED", "read-only replay; no renewed approval", "separate explicit Git persistence") do
      before = snapshot(catalog)
      durable_result = File.binread(File.join(operation_dir, "adoption-result.json"))
      operation_before = snapshot(operation_dir)
      package_before = file_binding(package_path)
      staged_before = file_binding(fixture.staged_path)
      stdout, stderr, status = capture(front_env, *command)
      @rows.last[:actual] = {exitstatus: status.exitstatus, stdout:, stderr:}
      assert status.success?, "#{stderr}\n#{stdout}"
      assert_includes stdout, "Final promotion: ALREADY_PROMOTED."
      assert_equal before, snapshot(catalog)
      assert_equal durable_result, File.binread(File.join(operation_dir, "adoption-result.json"))
      assert_equal release_before, snapshot(fixture.output_dir)
      assert_equal operation_before, snapshot(operation_dir)
      assert_equal package_before, file_binding(package_path)
      assert_equal staged_before, file_binding(fixture.staged_path)
      assert_equal identity, git_identity(catalog)
      assert_equal literal_index, File.binread(File.join(catalog, ".git/index"))
      refute_includes stdout, "Type APPROVE"
      verify_cold_replay_refusals(command, front_env, operation_dir, package_path, package, fixture, catalog)
    end
  rescue Minitest::Assertion => error
    %w[same-label-candidate-drift exact-local-promotion promoted-front-door-fresh-replay].each do |id|
      next if @rows.any? { |entry| entry[:id] == id }

      @rows << {id:, status: "BLOCKED", classification: "not reached", owner: "see preceding failure",
        input: "final-promotion lifecycle", precondition: "preceding gates must pass",
        expected: "exact review or replay", actual: error.message,
        allowed_mutation: "none", forbidden_mutation: "catalog or Git mutation; invented authority",
        preserved: "candidate, package, release, catalog roles, HEAD/refs/index",
        next_action: "resolve the recorded preceding failure before continuation"}
    end
    raise
  end

  def test_boundary_approval_freeze_and_staged_successor_in_a_fresh_process
    extend StagedScoringFixture
    options = build_authority_fixture(@temporary, cache_namespace: @temporary)
    base = File.join(@temporary, "5e_Adventure_Master_Catalog_0.1.xlsx")
    common = options.slice(:approval_path, :bundle_dir, :dossier_path, :source_root).merge(amc_path: base)
    approval = AfDataPipeline::BoundaryEditorial.validate_approval!(**common).approval
    freeze = AfDataPipeline::BoundaryEditorial.validate_approved_freeze!(**common, freeze_path: options.fetch(:freeze_path)).artifact
    stage = AfDataPipeline::BoundaryFreezeStage.stage!(**options.slice(:freeze_path, :operation_input_path,
      :successor_authorization_path, :source_root, :catalog_root, :project_state_path))
    before = snapshot(@temporary)
    script = <<~'RUBY'
      require "json"
      require "af_data_pipeline"
      options = JSON.parse(ARGV.fetch(0), symbolize_names: true)
      common = options.slice(:approval_path, :bundle_dir, :dossier_path, :source_root, :amc_path)
      approval = AfDataPipeline::BoundaryEditorial.validate_approval!(**common).approval
      freeze = AfDataPipeline::BoundaryEditorial.validate_approved_freeze!(**common, freeze_path: options.fetch(:freeze_path)).artifact
      stage = AfDataPipeline::BoundaryFreezeStage.stage!(**options.slice(:freeze_path, :operation_input_path,
        :successor_authorization_path, :source_root, :catalog_root, :project_state_path))
      puts JSON.generate(approval: approval, freeze: freeze, stage: stage.receipt, reused: stage.reused)
    RUBY
    stdout, stderr, status = capture({}, RbConfig.ruby, "-I#{PIPELINE}/lib", "-e", script,
      JSON.generate(options.merge(amc_path: base)))
    assert status.success?, stderr
    observed = JSON.parse(stdout)
    {"approved-boundary-fresh-validate" => ["approval", approval],
     "freeze-fresh-validate" => ["freeze", freeze],
     "staged-successor-fresh-replay" => ["stage", stage.receipt]}.each do |id, (key, expected)|
      row(id, "supported owner fixture through public producers", "approved exact boundary lineage",
          "unchanged validated #{key}", "read-only replay", "continue through explicit owner preparation") do
        assert_equal expected, observed.fetch(key)
        assert observed.fetch("reused")
        assert_equal before, snapshot(@temporary)
        @rows.last[:identities] = observed.fetch(key)
        @rows.last[:preserved_hashes] = before
      end
    end
  end

  private


  # Build the unchanged owner recipe with cold caches and a fixed ZIP time.
  # Restore earlier scenarios' caches so test order cannot alter fixture bytes.
  def build_standing_fixture
    caches = [CompatibilityAmcFixture::WORKBOOK_BYTES_CACHE, StagedScoringFixture::TEMPLATE_CACHE,
      StandingBulkScoreReleaseFixture::FIXTURE_CACHE, StandingBulkScoreReleaseFixture::ISSUED_AUTHORITY_CACHE]
    previous = caches.map(&:dup)
    caches.each(&:clear)
    Ig19GitFixture.with_fixed_zip_time { StandingBulkScoreReleaseFixture.new(root: @temporary) }
  ensure
    caches.zip(previous).each { |cache, saved| cache.replace(saved) }
  end

  # Exercise retained approvals through fresh public CLI processes. Each mutation
  # is applied only to this disposable fixture and restored in ensure; refusals
  # must preserve the entire altered fixture, including literal Git index bytes.
  def verify_cold_replay_refusals(command, environment, operation_dir, package_path, package, fixture, catalog)
    manifest = File.join(catalog, "PROJECT_STATE.yml")
    request_path = File.join(operation_dir, "adoption-request.json")
    decision_path = File.join(operation_dir, "adoption-decision.json")
    result_path = File.join(operation_dir, "adoption-result.json")
    canonical = File.join(catalog, package.dig("transition", "proposed_catalog_head", "filename"))
    scenarios = {
      "approval-bytes" => [decision_path, ->(bytes) { bytes + " " }],
      "approval-missing" => [decision_path, ->(_bytes) { nil }],
      "approval-other-request" => [decision_path, lambda do |bytes|
        decision = JSON.parse(bytes)
        decision.fetch("request")["request_id"] = "f" * 64
        decision["decision_id"] = AfDataPipeline::StandingBulkScorePolicy.digest(decision.except("decision_id"))
        AfDataPipeline::StagedScoringAuthority.document_bytes(decision)
      end],
      "request-replaced" => [request_path, ->(bytes) { bytes + " " }],
      "package-replaced" => [package_path, ->(bytes) { bytes + " " }],
      "candidate-changed" => [package.dig("candidate", "selected", "path"), ->(bytes) { bytes + "changed" }],
      "release-manifest-changed" => [File.join(fixture.output_dir, "release-accounting.json"), ->(bytes) { bytes + " " }],
      "staged-evidence-changed" => [fixture.staged_path, ->(bytes) { bytes + "changed" }],
      "repository-remote-changed" => [File.join(catalog, ".git/config"), ->(bytes) { bytes.sub("fixture://ig19d-catalog", "fixture://different-catalog") }],
      "repository-head-changed" => [File.join(catalog, ".git/HEAD"), ->(_bytes) { "#{'f' * 40}\n" }],
      "independent-role-changed" => [manifest, lambda do |bytes|
        state = YAML.safe_load(bytes)
        state["matcher_authorized_baseline"] = state.fetch("catalog_head")
        YAML.dump(state)
      end],
      "canonical-replaced" => [canonical, ->(bytes) { bytes + "changed" }],
      "live-manifest-changed" => [manifest, ->(bytes) { bytes + "\n" }],
      "result-without-publication" => [manifest, ->(_bytes) { git(catalog, "show", "HEAD:PROJECT_STATE.yml") }],
      "result-missing" => [result_path, ->(_bytes) { nil }]
    }
    scenarios.each do |name, (path, mutation)|
      original = File.binread(path)
      changed = mutation.call(original)
      changed.nil? ? File.unlink(path) : File.binwrite(path, changed)
      before = snapshot(@temporary)
      index = File.binread(File.join(catalog, ".git/index"))
      row("cold-replay-#{name}", name, "retained exact approval and successful result",
          "fail-closed refusal", "no mutation", "restore authoritative evidence or explicit recovery") do
        stdout, stderr, status = capture(environment, *command)
        @rows.last[:actual] = {exitstatus: status.exitstatus, stdout:, stderr:}
        assert_equal 2, status.exitstatus, "#{stderr}\n#{stdout}"
        refute_includes stdout, "Final promotion: ALREADY_PROMOTED."
        refute_includes stdout, "Type APPROVE"
        assert_equal before, snapshot(@temporary)
        assert_equal index, File.binread(File.join(catalog, ".git/index"))
      end
    ensure
      File.binwrite(path, original) if original
    end
  end

  def row(id, input, precondition, gate, allowed, next_action)
    evidence = {id:, input:, precondition:, expected: gate, allowed_mutation: allowed,
      forbidden_mutation: "implicit rebind, repeated completed work, stale approval, Git persistence or external IO",
      preserved: "bound public artifacts and stable identities", next_action:, status: "BLOCKED"}
    @rows << evidence
    yield
    evidence[:status] = "PASS"
  rescue Minitest::Assertion, StandardError => error
    evidence[:status] = "FAIL"
    evidence[:actual] ||= error.message
    evidence[:classification] ||= "unclassified pending reproduction"
    raise
  end

  def capture(environment, *command, stdin_data: "")
    transient = %w[IG07C_PROGRESS_MODE IG07C_MARKDOWN_MODE IG07C_RECEIPT_MODE].to_h { |name| [name, nil] }
    metadata_before = Ig19GitFixture.inventory(File.join(@catalog_fixture.root, ".git"), directories: true) if @catalog_fixture
    result = Open3.capture3(transient.merge(environment), *command, chdir: @elsewhere, stdin_data:)
    if @catalog_fixture
      assert_equal metadata_before, Ig19GitFixture.inventory(File.join(@catalog_fixture.root, ".git"), directories: true),
        "public workflow changed protected Git metadata"
    end
    @commands << {argv: command, cwd: @elsewhere, exitstatus: result.last.exitstatus,
      stdout: result.first, stderr: result[1]}
    result
  end

  def git(root, *arguments)
    environment = Ig19GitFixture::GIT_ENV
    stdout, stderr, status = Open3.capture3(environment, "git", "-C", root, *arguments)
    assert status.success?, stderr
    stdout
  end

  def git_identity(root)
    {metadata: Ig19GitFixture.inventory(File.join(root, ".git"), directories: true),
      head: git(root, "rev-parse", "HEAD"), refs: git(root, "show-ref"),
      index: file_binding(File.join(root, ".git/index"))}
  end

  def file_binding(path)
    {sha256: Digest::SHA256.file(path).hexdigest, bytes: File.size(path)}
  end

  def snapshot(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
      .sort.to_h { |path| [path.delete_prefix(root + "/"), file_binding(path)] }
  end

  def public_source_snapshot(fixture)
    [fixture.canonical, fixture.registry, fixture.source_intake_path, fixture.source_intake_companion,
      fixture.dossier_path, fixture.dossier_companion, File.join(fixture.editorial_dir, "editorial_context.json"),
      File.join(fixture.editorial_dir, "editorial_decisions.yml"), fixture.base].to_h do |path|
      [path, file_binding(path)]
    end
  end
end
