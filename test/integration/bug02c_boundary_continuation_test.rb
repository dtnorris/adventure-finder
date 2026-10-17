# frozen_string_literal: true

require "minitest/autorun"
require_relative "../support/ig07c_source_acceptance_fixture"
require_relative "../../lib/adventure_finder_ingest_boundary_continuation"

class Bug02cBoundaryContinuationTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path("../..", __dir__)
  PIPELINE = ENV.fetch("AF_IG07C_PIPELINE_SOURCE_ROOT",
                       File.join(ENV.fetch("AF_PROJECT_ROOT", "/Users/davidnorris/code/adventure-finder-components"),
                                 "af-data-pipeline"))

  def setup
    @fixture = Ig07cSourceAcceptance::Fixture.new(repository_root: ROOT, pipeline_source_root: PIPELINE)
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
    _, start_error, started = @fixture.run_catalog(
      missing_afw.merge("IG07C_MARKDOWN_MODE" => "synthetic_procedure"), *arguments
    )
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
    continuation = File.join(@fixture.front, "output", "ingest-boundary-continuations", "v0.1", operation_id)
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
end
