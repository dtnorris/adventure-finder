# frozen_string_literal: true

require "minitest/autorun"
require_relative "../support/ig07c_source_acceptance_fixture"
require_relative "../../lib/adventure_finder_ingest_boundary_continuation"

class Bug02cBoundaryContinuationTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path("../..", __dir__)
  SPLIT_PIPELINE = ENV["AF_TEST_PUBLIC_PIPELINE_ROOT"]
  PIPELINE = SPLIT_PIPELINE || ENV.fetch("AF_IG07C_PIPELINE_SOURCE_ROOT",
                       File.join(ENV.fetch("AF_PROJECT_ROOT", "/Users/davidnorris/code/adventure-finder-components"),
                                 "af-data-pipeline"))

  def setup
    @fixture = Ig07cSourceAcceptance::Fixture.new(repository_root: ROOT, pipeline_source_root: PIPELINE,
                                                   split_pipeline: !!SPLIT_PIPELINE)
    return if SPLIT_PIPELINE

    %w[af-data af-staged-scoring-authority].each do |command|
      File.symlink(File.join(PIPELINE, "bin", command), File.join(@fixture.pipeline, "bin", command))
    end
    config = File.join(@fixture.pipeline, "config")
    FileUtils.mkdir_p(config)
    FileUtils.cp(File.join(PIPELINE, "config", "staged_scoring_input_policy_v0.1.json"), config)
  end

  def teardown
    @fixture&.close
  end

  def test_accepted_review_stages_verified_successor_before_missing_afw_fixture
    # This scenario must refuse at the absent fixture AFW, regardless of caller overrides.
    missing_afw = {"AF_AFW_ROOT" => File.join(@fixture.components, "af-workloads")}
    require File.join(PIPELINE, "lib", "af_data_pipeline")
    require File.join(PIPELINE, "test", "support", "compatibility_amc_fixture")
    builder = Object.new.extend(CompatibilityAmcFixture)
    FileUtils.rm_f(@fixture.base)
    builder.write_compatible_amc(@fixture.base, rows: [
      builder.compatible_row("ADV-0001", title: "Existing Unit", source: "Existing Fixture",
                             start_page: 10, end_page: 21)
    ])
    Zip::File.open(@fixture.base) do |zip|
      (1..3).each do |number|
        member = "xl/worksheets/sheet#{number}.xml"
        body = zip.read(member)
        last = body.scan(/<row r="(\d+)"/).flatten.map(&:to_i).max
        body = body.sub("</sheetData>", ((last + 1)..12).map { |row| %(<row r="#{row}"></row>) }.join + "</sheetData>")
        zip.get_output_stream(member) { |stream| stream.write(body) }
      end
    end
    @fixture.send(:write_project_state)
    original_state = File.binread(File.join(@fixture.catalog, "PROJECT_STATE.yml"))
    base_digest = Digest::SHA256.file(@fixture.base).hexdigest
    arguments = @fixture.send(:start_arguments)
    %w[--policy-definition --policy-id --policy-version --policy-values].each do |flag|
      arguments.slice!(arguments.index(flag), 2)
    end
    arguments.concat(["--prepare-staged-scoring", "--successor-version", "0.0.2"])
    start_env = missing_afw.merge("IG07C_MARKDOWN_MODE" => "synthetic_procedure")
    if SPLIT_PIPELINE
      wrong_pipeline_data = File.join(@fixture.root, "wrong-pipeline-data")
      FileUtils.mkdir(wrong_pipeline_data)
      before = workload_hashes(@fixture.root)
      {
        nil => "set AF_DATA_PIPELINE_DATA_ROOT",
        wrong_pipeline_data => "differs from the installed private pipeline store"
      }.each do |selected, expected|
        _, error, status = @fixture.run_catalog(start_env.merge("AF_DATA_PIPELINE_DATA_ROOT" => selected), *arguments)
        refute status.success?
        assert_includes error, expected
        assert_equal before, workload_hashes(@fixture.root)
      end
    end
    _, start_error, started = @fixture.run_catalog(start_env, *arguments)
    assert started.success?, start_error

    operation_id = Ig07cSourceAcceptance::Fixture::OPERATION_ID
    _, pending_error, pending = @fixture.run_catalog(missing_afw, "resume", operation_id,
                                                     "--approve-boundary-by", "Fixture Operator")
    refute pending.success?
    assert_includes pending_error, "cannot approve an unreviewed empty editorial ledger"
    bundle = File.join(@fixture.front, "output", "ingest-editorial-workspaces", "v0.1", operation_id)
    ledger_path = File.join(bundle, "editorial_decisions.yml")
    ledger = YAML.safe_load_file(ledger_path)
    ledger.fetch("candidates") << {
      "candidate_key" => "synthetic-sequence",
      "provisional_title" => "Synthetic Procedure",
      "playability_evidence" => "Entry, authored middle, and exit on the synthetic page.",
      "open_questions" => [],
      "review_history" => [
        {"phase" => "phase1", "status" => "retained", "rationale" => "Three steps."},
        {"phase" => "phase1b", "status" => "survived", "rationale" => "Entry, middle and exit."},
        {"phase" => "phase2", "status" => "accepted", "rationale" => "One bounded procedure."}
      ],
      "disposition" => "accept",
      "decision" => {
        "canonical_title" => "Synthetic Procedure",
        "printed_pages" => {"start" => 1, "end" => 1},
        "pdf_pages" => {"start" => 1, "end" => 1},
        "levels" => {"start" => 1, "end" => 1},
        "editorial_rationale" => "Synthetic page supplies complete procedural sequence."
      }
    }
    File.binwrite(ledger_path, YAML.dump(ledger))

    output, error, status = @fixture.run_catalog(missing_afw, "resume", operation_id,
                                                 "--approve-boundary-by", "Fixture Operator")
    refute status.success?, output
    assert_includes output, "VERIFIED STAGED SUCCESSOR"
    assert_includes error, "AFW_PREPARATION_REFUSED: AFW public library is unavailable"
    continuation = File.join(@fixture.pipeline_data, "output", "ingest-boundary-continuations", "v0.1", operation_id)
    receipts = Dir.glob(File.join(continuation, "*verified-staged-successor*.json"))
    assert_equal 1, receipts.length
    receipt = JSON.parse(File.binread(receipts.fetch(0)))
    assert_equal "af-boundary-freeze-staged-successor/v0.1", receipt.fetch("schema_version")
    assert_equal "verified_staged_successor", receipt.fetch("status")
    assert_equal operation_id, receipt.dig("operation", "operation_id")
    assert_equal base_digest, Digest::SHA256.file(@fixture.base).hexdigest
    assert_equal original_state, File.binread(File.join(@fixture.catalog, "PROJECT_STATE.yml"))
    assert_equal 4, @fixture.latest_revision
    assert_empty @fixture.forbidden_calls
    exact = %w[approval.json boundary-freeze.yml operation-input.json successor-authority.json].to_h do |name|
      [name, Digest::SHA256.file(File.join(continuation, name)).hexdigest]
    end
    replay_output, replay_error, replay = @fixture.run_catalog(missing_afw, "resume", operation_id,
                                                               "--approve-boundary-by", "Fixture Operator")
    refute replay.success?, replay_output
    assert_includes replay_output, "VERIFIED STAGED SUCCESSOR"
    assert_includes replay_error, "AFW_PREPARATION_REFUSED"
    exact.each do |name, digest|
      assert_equal digest, Digest::SHA256.file(File.join(continuation, name)).hexdigest
    end

    # AFDP resolves historical role artifacts beside its supplied manifest.
    # Retain staging-time bytes rather than an alias to the moving head.
    historical = AdventureFinderWorkspace::IngestBoundaryContinuation.historical_project_state_path(
      catalog_root: @fixture.catalog, operation_id:
    ).to_s
    assert_equal original_state, File.binread(historical)
    verify_public_workload(operation_id, bundle, continuation, historical) if ENV["AF_TEST_PUBLIC_AFW_ROOT"]
    state = File.join(@fixture.catalog, "PROJECT_STATE.yml")
    File.binwrite(state, original_state + "\n")
    options = {
      freeze_path: File.join(continuation, "boundary-freeze.yml"),
      operation_input_path: File.join(continuation, "operation-input.json"),
      successor_authorization_path: File.join(continuation, "successor-authority.json"),
      source_root: @fixture.source, catalog_root: @fixture.catalog, project_state_path: historical
    }
    verified = AfDataPipeline::BoundaryFreezeStage.verify!(**options)
    assert_equal "verified_staged_successor", verified.status
    assert_equal receipt, verified.receipt
    assert_equal original_state + "\n", File.binread(state)
    assert_equal original_state, File.binread(historical)
    File.binwrite(historical, original_state + "\n")
    error = assert_raises(AfDataPipeline::ValidationError) do
      AfDataPipeline::BoundaryFreezeStage.verify!(**options)
    end
    assert_includes error.message, "existing staged-successor receipt conflicts"
    assert_equal original_state + "\n", File.binread(historical)
    assert_equal base_digest, Digest::SHA256.file(@fixture.base).hexdigest
  end

  private

  # Continue from the real editorial approval into preparation and fresh-process
  # EE replay. The existing converter fixture is the external boundary.
  def verify_public_workload(operation_id, bundle, continuation, historical)
    afw = File.realpath(ENV.fetch("AF_TEST_PUBLIC_AFW_ROOT"))
    scorer = File.realpath(ENV.fetch("AF_SCORER_ROOT"))
    specs = File.realpath(ENV.fetch("AF_PUBLIC_SPEC_ROOT"))
    data = File.join(@fixture.root, "workload-data")
    decoy = File.join(@fixture.root, "wrong-workload-data")
    FileUtils.mkdir(data)
    FileUtils.mkdir(decoy)
    File.symlink(afw, File.join(@fixture.components, "af-workloads"))
    config = File.join(@fixture.root, "scorer-selection.yml")
    config_bytes = YAML.dump("paths" => {"xlsx_root" => @fixture.catalog,
      "source_root" => @fixture.source, "specification_root" => specs,
      "output_root" => File.join(data, "output")})
    File.binwrite(config, config_bytes)
    env = {"AF_AFW_ROOT" => afw, "AF_AFW_DATA_ROOT" => data, "AF_SCORER_ROOT" => scorer,
           "AF_SCORER_CONFIG" => config}
    real_git = ENV.fetch("PATH").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "git") }
      .find { |path| File.executable?(path) }
    git_guard = File.join(@fixture.root, "sentinel-bin", "git")
    sentinel = File.binread(git_guard)
    File.binwrite(git_guard, sentinel.sub("require \"json\"\n", <<~RUBY))
      require "json"
      if ARGV.take(2) == ["-C", #{scorer.inspect}] &&
         (ARGV.drop(2) == ["rev-parse", "HEAD"] ||
          [%w[diff --quiet --], %w[diff --cached --quiet --]].any? { |prefix| ARGV.drop(2).take(prefix.length) == prefix })
        exec({"GIT_OPTIONAL_LOCKS" => "0"}, #{real_git.inspect}, *ARGV)
      end
    RUBY
    approval = File.join(continuation, "approval.json")
    approval_bytes = File.binread(approval)
    command = ["prepare-workload", operation_id, "--freeze", File.join(continuation, "boundary-freeze.yml"),
               "--approval", approval, "--editorial-bundle", bundle, "--historical-project-state", historical]
    preparation = File.join(@fixture.front, "output/staged-workload-preparations/v0.1", operation_id)
    records = []
    [{ "AF_AFW_ROOT" => nil }, { "AF_AFW_ROOT" => @fixture.pipeline },
     { "AF_AFW_DATA_ROOT" => nil }, { "AF_AFW_DATA_ROOT" => decoy }].each do |override|
      _, error, status = @fixture.run_catalog(env.merge(override), *command)
      refute status.success?
      assert_includes error, "AFW_PREPARATION_REFUSED"
      refute File.exist?(preparation)
      assert Dir.empty?(data)
      assert Dir.empty?(decoy)
      records << {"overrides" => override, "status" => status.exitstatus, "stderr" => error}
    end

    output, error, status = @fixture.run_catalog(env, *command)
    assert status.success?, "#{output}\n#{error}"
    result = JSON.parse(File.binread(File.join(preparation, "result.json")))
    assert_equal "PREPARED", result.fetch("status"), result.inspect
    assert_equal "reuse", result.dig("inspection", "action")
    plan_path = result.fetch("plan").fetch("path")
    assert plan_path.start_with?(data + "/")
    plan = JSON.parse(File.binread(plan_path))
    job = plan.fetch("jobs").find { |entry| entry.fetch("job_id").end_with?("-ee") }
    argv = job.fetch("argv")
    assert_equal ["bin/afw-score-job", "build/workloads/#{result.fetch('workload_id')}/cases/#{job.fetch('job_id')}.yml"], argv
    case_path = argv.fetch(1)
    replay = [File.join(afw, argv.fetch(0)), "--data-root", data, "--verify-only", case_path]
    files = workload_hashes(data)

    _, error, status = @fixture.run_catalog(env, *command)
    assert status.success?, error
    assert_equal files, workload_hashes(data)
    wrong_config = File.join(@fixture.root, "wrong-scorer-selection.yml")
    File.binwrite(wrong_config, config_bytes.sub(File.join(data, "output"), File.join(decoy, "output")))
    _, error, status = @fixture.run_catalog(env.merge("AF_AFW_DATA_ROOT" => decoy, "AF_SCORER_CONFIG" => wrong_config), *command)
    refute status.success?
    assert_includes error, "PREPARATION_CONFLICT: AFW code or data binding changed"
    assert Dir.empty?(decoy)

    guarded_path = [File.dirname(git_guard), ENV.fetch("PATH")].join(File::PATH_SEPARATOR)
    [data, decoy, data, data].zip([config_bytes, config_bytes, config_bytes + "\n", config_bytes]).each do |root, bytes|
      File.binwrite(config, bytes)
      invocation = replay.dup
      invocation[2] = root
      stdout, stderr, verified = Open3.capture3(env.merge("PATH" => guarded_path), *invocation, chdir: afw)
      assert_equal root == data && bytes == config_bytes, verified.success?, "#{stdout}\n#{stderr}"
      records << {"argv" => invocation, "status" => verified.exitstatus, "stdout" => stdout, "stderr" => stderr}
    end
    assert_equal files, workload_hashes(data)
    assert_equal approval_bytes, File.binread(approval)
    assert_equal 1, Dir.glob(File.join(continuation, "*verified-staged-successor*.json")).length
    assert_equal 1, Dir.glob(File.join(@fixture.front, "output/ingest-operations/v0.1/*")).count { |path| File.directory?(path) }
    assert_empty @fixture.forbidden_calls

    if ENV["AF_TEST_EVIDENCE_ROOT"]
      path = File.join(ENV.fetch("AF_TEST_EVIDENCE_ROOT"), "public-front-door.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate("code" => afw, "scorer" => scorer, "specification" => specs,
        "pipeline" => File.realpath(File.join(@fixture.pipeline, "bin", "af-staged-scoring-authority")),
        "selection_owner" => File.join(afw, "bin", "afw-staged-selection"),
        "data" => data, "front_door" => [File.join(ROOT, "bin", "af-catalog"), *command], "selections" => env,
        "preparation" => result, "workdir" => afw, "wlo_argv" => argv, "hashes" => files, "checks" => records))
    end
  end

  # Return the frozen and generated workload hashes under the disposable store.
  def workload_hashes(root)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: root).sort.filter_map do |name|
      path = File.join(root, name)
      [name, Digest::SHA256.file(path).hexdigest] if File.file?(path)
    end.to_h
  end
end
