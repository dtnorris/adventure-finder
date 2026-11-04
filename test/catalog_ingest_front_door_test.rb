# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "stringio"
require "tmpdir"
require "adventure_finder_catalog_ingest"

class CatalogIngestFrontDoorTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  COMMAND = File.join(ROOT, "bin", "af-catalog")
  ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

  def setup
    @temporary = Dir.mktmpdir("catalog ingest front door")
    real = File.join(@temporary, "real workspace with spaces")
    FileUtils.mkdir_p(real)
    @workspace = File.join(@temporary, "workspace alias")
    File.symlink(real, @workspace)
    @front = directory("adventure-finder")
    @components = directory("adventure-finder-components")
    @converter = directory("adventure-finder-components/pdf-to-llm-md-converter")
    @pipeline = directory("adventure-finder-components/af-data-pipeline")
    @source = directory("adventure-finder-components/md-for-llm-book-content")
    @input = directory("owned inputs")
    @catalog = directory("catalog data")
    @pdf = write(File.join(@input, "owned book.pdf"), "%PDF synthetic fixture\n")
    @base = write(File.join(@catalog, "AMC exact.xlsx"), "synthetic catalog\n")
    @policy = write(File.join(@temporary, "standard-policy.yml"), "policy fixture\n")
    @router_log = File.join(@temporary, "router.json")
    @converter_log = File.join(@temporary, "converter.log")
    @forbidden_log = File.join(@temporary, "forbidden.log")
    @sentinel_bin = directory("sentinel bin")
    %w[git ollama wlo rpof af-workloads af-cli-scoring-utility af-boundary-freeze-apply].each do |name|
      executable(File.join(@sentinel_bin, name), <<~RUBY)
        File.open(#{@forbidden_log.inspect}, "ab") { |file| file.puts(File.basename($PROGRAM_NAME)) }
        exit 99
      RUBY
    end
    fake_converter
    fake_router
  end

  def teardown
    FileUtils.remove_entry(@temporary) if @temporary && File.exist?(@temporary)
  end

  def test_start_returns_stable_handle_and_fresh_resume_reconstructs_the_gate
    stdout, stderr, status = run_catalog(*start_arguments)

    assert status.success?, stderr
    assert_includes stdout, "Operation handle: #{ID}"
    assert_includes stdout, "Gate: NEEDS_CANONICAL_MARKDOWN_PLACEMENT"
    revision = revision_document(1)
    assert_equal ID, revision.fetch("operation_id")
    assert_equal "Fixture Source", revision.dig("source_declaration", "source_id", "value")
    assert_equal "First printing", revision.dig("source_declaration", "edition", "value")
    assert_equal "Printed page labels", revision.dig("source_declaration", "pagination_authority", "value")
    assert_equal "Fixture Publisher", revision.dig("source_declaration", "publisher", "value")
    assert_equal({"profile" => "standard", "execution" => "deferred"},
                 revision.dig("policy", "selected_values"))
    assert_equal Digest::SHA256.file(@policy).hexdigest, revision.dig("policy", "definition_sha256")
    assert revision.fetch("future_choices").values.all?(&:nil?)
    assert_equal "conversion_receipt", revision.dig("artifacts", 0, "kind")
    refute_includes JSON.generate(revision), @workspace

    routed = JSON.parse(File.binread(@router_log))
    refute_includes routed.fetch("argv"), "--auto"
    assert_equal File.realpath(@components), File.realpath(routed.dig("env", "AF_PROJECT_ROOT"))
    assert_equal File.realpath(@front), File.realpath(routed.dig("env", "AF_ADVENTURE_FINDER_ROOT"))
    refute File.exist?(@forbidden_log)
    before = operation_snapshot

    resumed_out, resumed_err, resumed_status = run_catalog("resume", ID)

    assert resumed_status.success?, resumed_err
    assert_includes resumed_out, "Ingest operation: #{ID}"
    assert_includes resumed_out, "Gate: NEEDS_CANONICAL_MARKDOWN_PLACEMENT"
    assert_equal before, operation_snapshot
  end

  # Private storage remains bound across cold resume. Changed/unset selectors
  # refuse before routing; restoring the original returns the same gate/bytes.
  def test_private_data_selection_must_match_retained_operation_context
    data = File.join(File.realpath(@temporary), "private-data")
    alternate = File.join(File.realpath(@temporary), "other-data")
    FileUtils.mkdir_p([data, alternate])
    code = File.realpath(@pipeline)
    executable(File.join(code, "bin/af-data"), "abort 'root validation only'\n")
    selected = {"AF_DATA_PIPELINE_ROOT" => code, "AF_DATA_PIPELINE_DATA_ROOT" => data}
    _output, error, started = run_catalog(selected, *start_arguments)
    assert started.success?, error
    before = operation_snapshot
    context = File.binread(File.join(context_root, "#{ID}.json"))
    router = File.binread(@router_log)

    [alternate, nil].each do |replacement|
      _output, error, refused = run_catalog(selected.merge("AF_DATA_PIPELINE_DATA_ROOT" => replacement), "resume", ID)
      refute refused.success?
      assert_includes error, "PIPELINE_DATA_ROOT_MISMATCH"
      assert_equal before, operation_snapshot
      assert_equal context, File.binread(File.join(context_root, "#{ID}.json"))
      assert_equal router, File.binread(@router_log)
      assert_empty Dir.children(alternate)
    end
    output, error, resumed = run_catalog(selected, "resume", ID)
    assert resumed.success?, error
    assert_includes output, "Gate: NEEDS_CANONICAL_MARKDOWN_PLACEMENT"
    assert_equal before, operation_snapshot
    assert_equal context, File.binread(File.join(context_root, "#{ID}.json"))
  end

  def test_missing_choices_and_unsupported_input_fail_before_creating_an_operation
    _stdout, stderr, status = dispatch_catalog("start", @pdf)

    assert_equal 1, status
    assert_includes stderr, "MISSING_CHOICE"
    refute File.exist?(operation_root)

    text = write(File.join(@input, "not-a-pdf.txt"), "not a pdf\n")
    _stdout, stderr, status = dispatch_catalog(*start_arguments(pdf: text))
    assert_equal 1, status
    assert_includes stderr, "UNSUPPORTED_INPUT"
    refute File.exist?(operation_root)
  end

  def test_public_prepare_resolves_exact_policy_without_internal_options
    policy_path = staged_policy
    args = start_arguments_without_policy + ["--prepare-staged-scoring"]
    stdout, stderr, status = run_catalog(*args)

    assert status.success?, stderr
    assert_includes stdout, "Operation handle: #{ID}"
    assert_equal 1, revision_document(1).fetch("revision")
    assert_equal({
      "policy_id" => "approved-new-records",
      "policy_version" => "1",
      "definition_sha256" => Digest::SHA256.file(policy_path).hexdigest,
      "selected_values" => {"selection" => "afw-qualified-default"},
      "selected_by" => "David"
    }, revision_document(0).fetch("policy").except("selected_at"))
    assert_equal "prepare", JSON.parse(File.binread(scoring_decision_path)).fetch("choice")
    before = operation_snapshot

    _stdout, resume_err, resumed = run_catalog("resume", ID)
    assert resumed.success?, resume_err
    assert_equal before, operation_snapshot
    refute File.exist?(@forbidden_log)
  end

  def test_source_facts_without_policy_or_scoring_choice_need_one_explicit_decision
    _stdout, stderr, status = run_catalog(*start_arguments_without_policy)
    refute status.success?
    assert_includes stderr, "MISSING_CHOICE"
    assert_includes stderr, "--prepare-staged-scoring"
    refute File.exist?(operation_root)
    refute File.exist?(@converter_log)
  end

  def test_missing_or_incompatible_policy_authority_refuses_before_operation
    args = start_arguments_without_policy + ["--prepare-staged-scoring"]
    _stdout, missing_err, missing = run_catalog(*args)
    refute missing.success?
    assert_includes missing_err, "SCORING_POLICY_MISSING"
    refute File.exist?(operation_root)

    path = staged_policy
    File.binwrite(path, JSON.generate(JSON.parse(File.binread(path)).merge("status" => "REVOKED")))
    _stdout, changed_err, changed = run_catalog(*args)
    refute changed.success?
    assert_includes changed_err, "SCORING_POLICY_MISMATCH"
    refute File.exist?(operation_root)
    refute File.exist?(@converter_log)

    staged_policy
    File.binwrite(path, File.binread(path).sub(
      '"policy_id":"approved-new-records"',
      '"policy_id":"approved-new-records","policy_id":"approved-new-records"'
    ))
    _stdout, duplicate_err, duplicate = run_catalog(*args)
    refute duplicate.success?
    assert_includes duplicate_err, "SCORING_POLICY_MISMATCH"
    refute File.exist?(operation_root)
  end

  def test_partial_and_conflicting_explicit_policy_inputs_fail_before_operation
    staged_policy
    args = start_arguments_without_policy + ["--prepare-staged-scoring"]
    _stdout, partial_err, partial = run_catalog(*(args + ["--policy-id", "approved-new-records"]))
    refute partial.success?
    assert_includes partial_err, "MISSING_CHOICE"
    refute File.exist?(operation_root)

    _stdout, conflict_err, conflict = run_catalog(*(start_arguments + ["--prepare-staged-scoring"]))
    refute conflict.success?
    assert_includes conflict_err, "SCORING_POLICY_MISMATCH"
    refute File.exist?(operation_root)
  end

  def test_policy_change_after_public_prepare_blocks_resume_without_rebinding
    path = staged_policy
    _stdout, start_err, started = run_catalog(*(start_arguments_without_policy + ["--prepare-staged-scoring"]))
    assert started.success?, start_err
    policy_before = revision_document(0).fetch("policy")
    File.binwrite(path, JSON.generate(JSON.parse(File.binread(path)).merge("selection" => "different")))
    _stdout, resume_err, resumed = run_catalog("resume", ID)
    refute resumed.success?
    assert_includes resume_err, "SCORING_POLICY_MISMATCH"
    assert_equal policy_before, revision_document(0).fetch("policy")
    assert_equal 1, File.readlines(@converter_log).length
  end

  def test_explicit_decline_needs_no_inert_policy
    _stdout, stderr, status = run_catalog(*(start_arguments_without_policy + ["--decline-staged-scoring"]))
    assert status.success?, stderr
    assert_nil revision_document(0).fetch("policy")
    assert_equal "decline", JSON.parse(File.binread(scoring_decision_path)).fetch("choice")
  end

  def test_decline_with_explicit_policy_fields_is_rejected_before_binding
    _stdout, stderr, status = run_catalog(*(start_arguments + ["--decline-staged-scoring"]))

    assert_equal 1, status.exitstatus
    assert_includes stderr, "INVALID_SCORING_CHOICE"
    refute File.exist?(operation_root)
    refute File.exist?(@converter_log)
    refute File.exist?(@forbidden_log)
  end

  def test_deferred_prepare_refuses_conflicting_immutable_selection
    policy_path = staged_policy
    args = start_arguments
    args[args.index(@policy)] = policy_path
    args[args.index("standard-scoring-execution")] = "approved-new-records"
    args[args.index("v0.1")] = "1"
    args[args.index(JSON.generate("profile" => "standard", "execution" => "deferred"))] =
      JSON.generate("selection" => "different-selection")
    _stdout, start_err, started = run_catalog(*args)
    assert started.success?, start_err
    assert_equal "approved-new-records", revision_document(0).dig("policy", "policy_id")
    assert_equal "1", revision_document(0).dig("policy", "policy_version")
    assert_equal Digest::SHA256.file(policy_path).hexdigest,
                 revision_document(0).dig("policy", "definition_sha256")
    assert_equal({"selection" => "different-selection"}, revision_document(0).dig("policy", "selected_values"))
    assert_equal "David", revision_document(0).dig("policy", "selected_by")
    before = operation_snapshot

    _stdout, error, status = run_catalog("resume", ID, "--prepare-staged-scoring", "--selected-by", "David")

    assert_equal 1, status.exitstatus
    assert_includes error, "SCORING_POLICY_MISMATCH"
    assert_equal before, operation_snapshot
    refute File.exist?(scoring_decision_path)
    refute File.exist?(@forbidden_log)
  end

  def test_deferred_prepare_rechecks_authority_and_replays_without_rebinding
    policy_path = staged_policy
    args = start_arguments
    args[args.index(@policy)] = policy_path
    args[args.index("standard-scoring-execution")] = "approved-new-records"
    args[args.index("v0.1")] = "1"
    args[args.index(JSON.generate("profile" => "standard", "execution" => "deferred"))] =
      JSON.generate("selection" => "afw-qualified-default")
    _stdout, start_err, started = run_catalog(*args)
    assert started.success?, start_err
    before = operation_snapshot
    policy_bytes = File.binread(policy_path)
    File.unlink(policy_path)
    _stdout, missing_err, missing = run_catalog("resume", ID, "--prepare-staged-scoring", "--selected-by", "David")
    assert_equal 1, missing.exitstatus
    assert_includes missing_err, "SCORING_POLICY_MISSING"
    File.binwrite(policy_path, JSON.generate(JSON.parse(policy_bytes).merge("selection" => "revoked")))
    _stdout, changed_err, changed = run_catalog("resume", ID, "--prepare-staged-scoring", "--selected-by", "David")
    assert_equal 1, changed.exitstatus
    assert_includes changed_err, "SCORING_POLICY_MISMATCH"
    assert_equal before, operation_snapshot
    refute File.exist?(scoring_decision_path)

    File.binwrite(policy_path, policy_bytes)
    _stdout, prepare_err, prepared = run_catalog("resume", ID, "--prepare-staged-scoring", "--selected-by", "David")
    assert prepared.success?, prepare_err
    assert_equal before, operation_snapshot.reject { |path, _| path.include?("staged-scoring-intents") }
    decision_bytes = File.binread(scoring_decision_path)
    intent_path = File.join(File.dirname(scoring_decision_path), "intent.json")
    intent_bytes = File.binread(intent_path)
    assert_equal "post_boundary_resume", JSON.parse(intent_bytes).fetch("interaction")
    assert_equal "David", JSON.parse(intent_bytes).fetch("selected_by")
    _stdout, replay_err, replay = run_catalog("resume", ID, "--prepare-staged-scoring", "--selected-by", "David")
    assert replay.success?, replay_err
    assert_equal decision_bytes, File.binread(scoring_decision_path)
    assert_equal intent_bytes, File.binread(intent_path)
    assert_equal ID, revision_document(0).fetch("operation_id")
    refute File.exist?(@forbidden_log)
  end

  def test_local_execution_commands_require_explicit_authority_and_exact_handles
    _stdout, stderr, status = dispatch_catalog("local-start", ID)
    assert_equal 1, status
    assert_includes stderr, "MISSING_CHOICE"

    _stdout, stderr, status = dispatch_catalog("local-resume")
    assert_equal 1, status
    assert_includes stderr, "INVALID_OPERATION_HANDLE"

    _stdout, stderr, status = dispatch_catalog("local-status", ID, "unexpected")
    assert_equal 1, status
    assert_includes stderr, "INVALID_OPERATION_HANDLE"
    refute File.exist?(operation_root)
  end

  def test_reusing_a_handle_with_different_input_fails_closed
    _stdout, stderr, status = dispatch_catalog(*start_arguments)
    assert_equal 0, status, stderr
    other = write(File.join(@input, "other.pdf"), "%PDF different fixture\n")

    _stdout, conflict_err, conflict_status = dispatch_catalog(*start_arguments(pdf: other))

    assert_equal 1, conflict_status
    assert_includes conflict_err, "CONFLICT"
    assert_equal Digest::SHA256.file(@pdf).hexdigest, revision_document(0).dig("input", "content", "sha256")
  end

  def test_unknown_corrupt_context_and_corrupt_operation_are_distinct_failures
    _stdout, stderr, status = dispatch_catalog("resume")
    assert_equal 1, status
    assert_includes stderr, "INVALID_OPERATION_HANDLE"

    _stdout, stderr, status = dispatch_catalog("resume", "not-a-handle")
    assert_equal 1, status
    assert_includes stderr, "INVALID_OPERATION_HANDLE"

    _stdout, stderr, status = dispatch_catalog("resume", "--unknown", ID)
    assert_equal 1, status
    assert_includes stderr, "USAGE"

    _stdout, stderr, status = dispatch_catalog("not-a-command")
    assert_equal 1, status
    assert_includes stderr, "USAGE"

    _stdout, stderr, status = dispatch_catalog("resume", ID)
    assert_equal 1, status
    assert_includes stderr, "UNKNOWN_OPERATION"

    FileUtils.mkdir_p(context_root)
    File.binwrite(File.join(context_root, "#{ID}.json"), "{not json")
    _stdout, stderr, status = dispatch_catalog("resume", ID)
    assert_equal 1, status
    assert_includes stderr, "CORRUPT_RESUME_CONTEXT"

    FileUtils.remove_entry(@front)
    FileUtils.mkdir_p(@front)
    _stdout, stderr, status = run_catalog(*start_arguments)
    assert status.success?, stderr
    File.binwrite(revision_path(1), "{not json")
    stdout, _stderr, status = run_catalog("resume", ID)
    assert_equal 2, status.exitstatus
    assert_includes stdout, "Diagnostic: CORRUPT_EVIDENCE"
  end

  def test_reviewable_converter_failure_and_pipeline_rejection_remain_failures
    stdout, stderr, status = run_catalog({"CONVERTER_EXIT" => "2"}, *start_arguments)
    assert_equal 2, status.exitstatus
    assert_empty stderr
    assert_includes stdout, "Gate: NEEDS_CANONICAL_MARKDOWN_PLACEMENT"

    FileUtils.remove_entry(@front)
    FileUtils.mkdir_p(@front)
    stdout, _stderr, status = run_catalog({"ROUTER_FAIL" => "1"}, *start_arguments)
    assert_equal 2, status.exitstatus
    assert_includes stdout, "Diagnostic: COMPONENT_ARTIFACT_CONFLICT: fixture rejection"
  end

  def test_missing_receipt_leaves_a_resumable_nonexecuting_gate
    stdout, stderr, status = run_catalog({"NO_RECEIPT" => "1"}, *start_arguments)

    refute status.success?
    assert_includes stdout, "Operation handle: #{ID}"
    assert_includes stderr, "CONVERSION_RECEIPT_MISSING"
    assert_equal 0, revision_document(0).fetch("revision")
    assert_empty revision_document(0).fetch("artifacts")

    resumed_out, resumed_err, resumed_status = run_catalog("resume", ID)
    assert resumed_status.success?, resumed_err
    assert_includes resumed_out, "Gate: NEEDS_FIRST_COMPONENT_ARTIFACT"
    refute File.exist?(@router_log)
    assert_equal 1, File.readlines(@converter_log).length
    refute File.exist?(@forbidden_log)
  end

  def test_bind_successor_version_is_durable_replay_safe_and_nonexecuting
    _stdout, stderr, status = dispatch_catalog(*start_arguments)
    assert_equal 0, status, stderr
    revisions_before = revision_snapshot
    converter_calls = File.readlines(@converter_log).length
    router_before = Digest::SHA256.file(@router_log).hexdigest

    stdout, stderr, status = dispatch_catalog(
      "bind-successor-version", ID,
      "--successor-version", "7.5.2",
      "--selected-by", "David"
    )

    assert_equal 0, status, stderr
    assert_includes stdout, "Bound successor-version authority"
    assert_includes stdout, "Successor version: 7.5.2"
    authorization_path = successor_authorization_path
    bytes = File.binread(authorization_path)
    mtime = File.mtime(authorization_path)
    document = JSON.parse(bytes)
    assert_equal "adventurefinder-successor-version-authorization/v0.1", document["contract_version"]
    assert_equal ID, document.dig("operation", "operation_id")
    assert_equal revision_document(0).dig("base_catalog", "content").slice("sha256", "bytes"),
                 document["base_catalog"]
    assert_equal revisions_before, revision_snapshot
    assert_equal converter_calls, File.readlines(@converter_log).length
    assert_equal router_before, Digest::SHA256.file(@router_log).hexdigest
    refute File.exist?(@forbidden_log)

    projected, projected_err, projected_status = dispatch_catalog(
      "successor-version-authority", ID, "--json"
    )
    assert_equal 0, projected_status, projected_err
    projection = JSON.parse(projected)
    assert_equal "adventurefinder-successor-version-authorization-projection/v0.1",
                 projection["contract_version"]
    assert_equal document, projection["authorization"]

    _stdout, replay_err, replay_status = dispatch_catalog(
      "bind-successor-version", ID,
      "--successor-version", "7.5.2",
      "--selected-by", "David"
    )
    assert_equal 0, replay_status, replay_err
    assert_equal bytes, File.binread(authorization_path)
    assert_equal mtime, File.mtime(authorization_path)

    _stdout, conflict_err, conflict_status = dispatch_catalog(
      "bind-successor-version", ID,
      "--successor-version", "7.5.3",
      "--selected-by", "David"
    )
    assert_equal 1, conflict_status
    assert_includes conflict_err, "SUCCESSOR_VERSION_AUTHORITY_CONFLICT"
    assert_equal bytes, File.binread(authorization_path)
  end

  def test_bind_successor_version_rejects_malformed_value_before_authority_mutation
    _stdout, stderr, status = dispatch_catalog(*start_arguments)
    assert_equal 0, status, stderr

    _stdout, bind_err, bind_status = dispatch_catalog(
      "bind-successor-version", ID,
      "--successor-version", "VERSION",
      "--selected-by", "David"
    )

    assert_equal 1, bind_status
    assert_includes bind_err, "INVALID_SUCCESSOR_VERSION"
    refute File.exist?(File.dirname(successor_authorization_path))
    assert_equal 1, File.readlines(@converter_log).length
    refute File.exist?(@forbidden_log)
  end

  def test_explicit_scoring_choice_is_recorded_once_and_plain_resume_reuses_it
    policy = write(
      File.join(@pipeline, "config", "staged_scoring_input_policy_v0.1.json"),
      JSON.generate(
        "schema_version" => "af-staged-scoring-input-policy/v0.1",
        "policy_id" => "approved-new-records", "policy_version" => "1",
        "scope" => "operation-approved-new-records", "selection" => "afw-qualified-default",
        "permissions" => %w[scoring_input workload_preparation]
      )
    )
    arguments = start_arguments
    arguments[arguments.index(@policy)] = policy
    arguments[arguments.index("standard-scoring-execution")] = "approved-new-records"
    arguments[arguments.index("v0.1")] = "1"
    arguments[arguments.index(JSON.generate("profile" => "standard", "execution" => "deferred"))] =
      JSON.generate("selection" => "afw-qualified-default")
    arguments << "--prepare-staged-scoring"

    _stdout, stderr, status = run_catalog(*arguments)

    assert status.success?, stderr
    intent_path = File.join(
      @front, "output", "staged-scoring-intents", "v0.1", ID, "intent.json"
    )
    intent_bytes = File.binread(intent_path)
    intent = JSON.parse(intent_bytes)
    assert_equal "ingest-#{ID}", intent.fetch("workload_id")
    assert_equal "ingest_start", intent.fetch("interaction")

    _stdout, resume_err, resume_status = dispatch_catalog("resume", ID)
    assert_equal 0, resume_status, resume_err
    assert_equal intent_bytes, File.binread(intent_path)

    _stdout, conflict_err, conflict_status = run_catalog(
      "resume", ID, "--decline-staged-scoring", "--selected-by", "David"
    )
    refute conflict_status.success?
    assert_includes conflict_err, "SCORING_INTENT_CONFLICT"
    assert_equal intent_bytes, File.binread(intent_path)
  end

  # Public commands retain independent operation and authority histories per
  # namespace. This fixture uses its declared mechanical router, not real AFDP.
  def test_external_namespaces_keep_separate_public_operations_and_authorities
    states = [directory("state one"), directory("state two")].map { |path| File.realpath(path) }
    ids = [ID, "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"]
    states.zip(ids).each_with_index do |(state, operation_id), index|
      selected = {"AF_STATE_ROOT" => state}
      arguments = start_arguments.map { |argument| argument == ID ? operation_id : argument }
      stdout, stderr, status = run_catalog(selected, *arguments)
      assert status.success?, stderr
      assert_includes stdout, "Gate: NEEDS_CANONICAL_MARKDOWN_PLACEMENT"
      _stdout, stderr, status = run_catalog(selected, "bind-successor-version", operation_id,
        "--successor-version", "7.5.#{index + 1}", "--selected-by", "David")
      assert status.success?, stderr
      context = JSON.parse(File.binread(File.join(state, "output/ingest-contexts/v0.1", "#{operation_id}.json")))
      assert_equal AdventureFinderWorkspace::CatalogIngest::STATE_CONTEXT_VERSION, context.fetch("contract_version")
      assert_equal @front, context.dig("roots", "front_door")
      assert_equal @pipeline, context.fetch("pipeline_root")
      assert_equal state, context.dig("state_binding", "root")
    end
    before = states.map { |state| external_snapshot(state) }
    states.zip(ids).each do |state, operation_id|
      stdout, stderr, status = run_catalog({"AF_STATE_ROOT" => state}, "resume", operation_id)
      assert status.success?, stderr
      assert_includes stdout, "Gate: NEEDS_CANONICAL_MARKDOWN_PLACEMENT"
    end
    _stdout, stderr, status = run_catalog({"AF_STATE_ROOT" => states.last}, "resume", ID)
    refute status.success?
    assert_includes stderr, "UNKNOWN_OPERATION"
    assert_equal before, states.map { |state| external_snapshot(state) }
    refute File.exist?(File.join(@front, "output"))
  end

  # Invalid selectors and owner/code overlaps fail before converter or AF writes.
  def test_invalid_external_selectors_refuse_before_start_writes
    state = directory("state")
    alias_path = File.join(@temporary, "state alias")
    File.symlink(state, alias_path)
    ["", "relative", state + "/../state", state + "/absent", alias_path,
      File.realpath(@front), File.realpath(@source), File.realpath(@catalog)].each do |value|
      _stdout, stderr, status = run_catalog({"AF_STATE_ROOT" => value}, *start_arguments)
      refute status.success?, value
      refute_empty stderr
      refute File.exist?(@converter_log)
      refute File.exist?(File.join(@front, "output"))
      assert_empty Dir.children(state)
    end
  end

  # Copied contexts, unsupported versions, missing contexts and stale owner bytes
  # refuse with no cross-root search or regeneration of separately retained state.
  def test_external_context_refusals_preserve_original_history
    state = File.realpath(directory("state"))
    alternate = File.realpath(directory("other state"))
    selected = {"AF_STATE_ROOT" => state}
    _stdout, stderr, status = run_catalog(selected, *start_arguments)
    assert status.success?, stderr
    before = external_snapshot(state)
    path = File.join(state, "output/ingest-contexts/v0.1", "#{ID}.json")
    original = File.binread(path)
    FileUtils.cp_r(File.join(state, "output"), alternate)
    _stdout, stderr, status = run_catalog({"AF_STATE_ROOT" => alternate}, "resume", ID)
    refute status.success?
    assert_includes stderr, "STATE_ROOT_MISMATCH"
    assert_equal before, external_snapshot(state)
    context = JSON.parse(original)
    context.fetch("state_binding")["inode"] += 1
    File.binwrite(path, JSON.generate(context))
    wrong_identity = external_snapshot(state)
    _stdout, stderr, status = run_catalog(selected, "resume", ID)
    refute status.success?
    assert_includes stderr, "STATE_ROOT_MISMATCH"
    assert_equal wrong_identity, external_snapshot(state)
    context = JSON.parse(original)
    context["contract_version"] = "future/v99"
    File.binwrite(path, JSON.generate(context))
    corrupt_before = external_snapshot(state)
    _stdout, stderr, status = run_catalog(selected, "resume", ID)
    refute status.success?
    assert_includes stderr, "CORRUPT_RESUME_CONTEXT"
    assert_equal corrupt_before, external_snapshot(state)
    File.unlink(path)
    missing_before = external_snapshot(state)
    _stdout, stderr, status = run_catalog(selected, "resume", ID)
    refute status.success?
    assert_includes stderr, "UNKNOWN_OPERATION"
    assert_equal missing_before, external_snapshot(state)
    _stdout, stderr, status = run_catalog(selected, *start_arguments)
    refute status.success?
    assert_includes stderr, "CONFLICT"
    assert_equal missing_before, external_snapshot(state)
    File.binwrite(path, original)
    metadata_path = File.join(state, "output/ingest-operations/v0.1", ID, "store.json")
    metadata_bytes = File.binread(metadata_path)
    metadata = JSON.parse(metadata_bytes)
    metadata["contract_version"] = "foreign-store/v99"
    File.binwrite(metadata_path, JSON.generate(metadata))
    foreign_before = external_snapshot(state)
    stdout, stderr, status = run_catalog(selected, "resume", ID)
    refute status.success?
    assert_includes stdout + stderr, "INCOMPATIBLE_VERSION"
    assert_equal foreign_before, external_snapshot(state)
    File.binwrite(metadata_path, metadata_bytes)
    File.binwrite(@base, "changed catalog\n")
    stdout, _stderr, status = run_catalog(selected, "resume", ID)
    refute status.success?
    assert_includes stdout, "STALE_INPUT"
    assert_equal before, external_snapshot(state)
  end

  private

  # Returns exact relative file hashes for refusal/replay comparisons; reads only.
  def external_snapshot(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
      .sort.to_h { |path| [path.delete_prefix(root), Digest::SHA256.file(path).hexdigest] }
  end

  # The dispatcher consumes argv; each call gets its own array and streams.
  # Executable/restart scenarios continue to use run_catalog below.
  def dispatch_catalog(*arguments)
    out = StringIO.new
    err = StringIO.new
    status = AdventureFinderWorkspace::CatalogIngestCLI.run(
      arguments,
      front_door_root: @front,
      project_root: @components,
      out: out,
      err: err,
      env: {
        "AF_PDF_CONVERTER_ROOT" => @converter,
        "AF_DATA_PIPELINE_ROOT" => @pipeline,
        "AF_SOURCE_ROOT" => @source,
        "PATH" => [@sentinel_bin, ENV.fetch("PATH", "")].join(File::PATH_SEPARATOR)
      }
    )
    [out.string, err.string, status]
  end

  def start_arguments(pdf: @pdf)
    [
      "start", pdf,
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

  def start_arguments_without_policy
    args = start_arguments
    %w[--policy-definition --policy-id --policy-version --policy-values].each do |flag|
      index = args.index(flag)
      args.slice!(index, 2)
    end
    args
  end

  def staged_policy
    write(
      File.join(@pipeline, "config", "staged_scoring_input_policy_v0.1.json"),
      JSON.generate(
        "schema_version" => "af-staged-scoring-input-policy/v0.1",
        "policy_id" => "approved-new-records", "policy_version" => "1",
        "scope" => "operation-approved-new-records", "selection" => "afw-qualified-default",
        "permissions" => %w[scoring_input workload_preparation]
      )
    )
  end

  def scoring_decision_path
    File.join(@front, "output", "staged-scoring-intents", "v0.1", ID, "decision.json")
  end

  def run_catalog(*arguments)
    extra_env = arguments.first.is_a?(Hash) ? arguments.shift : {}
    Open3.capture3(
      {
        "AF_PROJECT_ROOT" => @components,
        "AF_ADVENTURE_FINDER_ROOT" => @front,
        "AF_PDF_CONVERTER_ROOT" => @converter,
        "AF_DATA_PIPELINE_ROOT" => @pipeline,
        "AF_SOURCE_ROOT" => @source,
        "PATH" => [@sentinel_bin, ENV.fetch("PATH", "")].join(File::PATH_SEPARATOR)
      }.merge(extra_env),
      COMMAND,
      *arguments
    )
  end

  def fake_converter
    executable(File.join(@converter, "bin", "convert-cached"), <<~RUBY)
      require "fileutils"
      File.open(#{@converter_log.inspect}, "ab") { |file| file.puts("convert") }
      output = ARGV.fetch(ARGV.index("--output-dir") + 1)
      FileUtils.mkdir_p(output)
      unless ENV["NO_RECEIPT"]
        receipt = File.join(output, "fixture receipt.json")
        File.binwrite(receipt, "{\\\"schema\\\":\\\"pdf-to-llm-md/conversion-receipt/v0.1\\\"}\\n")
        puts "Conversion receipt: \#{receipt}"
      end
      exit Integer(ENV.fetch("CONVERTER_EXIT", "0"))
    RUBY
  end

  def fake_router
    executable(File.join(@pipeline, "bin", "af-ingest-next"), <<~RUBY)
      require "digest"
      require "json"
      def canonical(value)
        case value
        when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
        when Array then value.map { |item| canonical(item) }
        else value
        end
      end
      operation_input = ARGV.fetch(ARGV.index("--operation-input") + 1)
      projection = JSON.parse(File.binread(operation_input))
      File.binwrite(#{@router_log.inspect}, JSON.generate(
        "argv" => ARGV,
        "env" => ENV.to_h.slice("AF_PROJECT_ROOT", "AF_ADVENTURE_FINDER_ROOT")
      ))
      if ENV["ROUTER_FAIL"]
        warn JSON.generate(
          "schema_version" => "af-ingest-routing-error/v0.1",
          "error" => {"code" => "COMPONENT_ARTIFACT_CONFLICT", "message" => "fixture rejection"}
        )
        exit 2
      end
      operation = projection.fetch("operation").except("contract_version").merge(
        "routing_input_sha256" => Digest::SHA256.hexdigest(JSON.generate(canonical(projection)))
      )
      puts JSON.generate(
        "schema_version" => "af-ingest-routing-result/v0.1",
        "operation" => operation,
        "route" => {
          "state" => "NEEDS_CANONICAL_MARKDOWN_PLACEMENT",
          "artifact_type" => "conversion_receipt",
          "evidence" => ["fixture receipt validated"],
          "human_review" => ["place canonical Markdown"],
          "commands" => [],
          "warnings" => []
        }
      )
    RUBY
  end

  def operation_root
    File.join(@front, "output", "ingest-operations", "v0.1", ID)
  end

  def context_root
    File.join(@front, "output", "ingest-contexts", "v0.1")
  end

  def revision_path(revision)
    File.join(operation_root, "revisions", format("%08d.json", revision))
  end

  def revision_document(revision)
    JSON.parse(File.binread(revision_path(revision)))
  end

  def successor_authorization_path
    File.join(
      @front, "output", "ingest-authorities", "successor-version", "v0.1", ID,
      "authorization.json"
    )
  end

  def revision_snapshot
    Dir.glob(File.join(operation_root, "revisions", "*.json")).sort.to_h do |path|
      [File.basename(path), Digest::SHA256.file(path).hexdigest]
    end
  end

  def operation_snapshot
    Dir.glob(File.join(@front, "output", "**", "*"), File::FNM_DOTMATCH)
       .select { |path| File.file?(path) }
       .sort.to_h { |path| [path.delete_prefix(@front), Digest::SHA256.file(path).hexdigest] }
  end

  def directory(relative)
    File.join(@workspace, relative).tap { |path| FileUtils.mkdir_p(path) }
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
    path
  end

  def executable(path, body)
    write(path, "#!/usr/bin/env ruby\n#{body}")
    FileUtils.chmod(0o755, path)
  end
end
