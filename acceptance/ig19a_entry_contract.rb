# frozen_string_literal: true

require "digest"
require "json"
require "minitest/autorun"
require_relative "../lib/adventure_finder_ingest_operation_store"
require_relative "../lib/adventure_finder_operator_acceptance"
require_relative "../test/support/ig07c_source_acceptance_fixture"

# Public-entry acceptance only. Converter IO is synthetic; pipeline routing
# and durable operation validation use their real public seams.
class Ig19aEntryContractTest < Minitest::Test
  ID = Ig07cSourceAcceptance::Fixture::OPERATION_ID
  SOURCE_ID = Ig07cSourceAcceptance::Fixture::SOURCE_ID
  SOURCE_CHOICES = {
    "source_id" => SOURCE_ID,
    "edition" => "Fixture edition",
    "pagination_authority" => "Explicit printed labels",
    "publisher" => "Fixture Publisher"
  }.freeze

  def setup
    pipeline = ENV["AF_IG19B_PIPELINE_SOURCE_ROOT"] || ENV.fetch("AF_DATA_PIPELINE_ROOT")
    @fixture = Ig07cSourceAcceptance::Fixture.new(
      repository_root: File.expand_path("..", __dir__),
      pipeline_source_root: pipeline
    )
    write_valid_synthetic_pdf
  end

  def teardown
    @fixture&.close
  end

  def test_public_start_binds_one_operation_and_fresh_process_resume_replays_the_entry_gate
    assert_refusal("MISSING_CHOICE", *start_arguments)
    assert_refusal("SCORING_POLICY_MISSING", *start_arguments, "--prepare-staged-scoring")
    assert_refusal("MISSING_INPUT", *start_arguments(pdf: File.join(@fixture.root, "missing.pdf")),
                   "--decline-staged-scoring")
    invalid_pdf = File.join(@fixture.root, "not-a-pdf.txt")
    File.binwrite(invalid_pdf, "synthetic input\n")
    assert_refusal("UNSUPPORTED_INPUT", *start_arguments(pdf: invalid_pdf), "--decline-staged-scoring")
    assert_refusal("MISSING_INPUT", *start_arguments(base: File.join(@fixture.root, "missing.xlsx")),
                   "--decline-staged-scoring")
    assert_refusal("INVALID_SCORING_CHOICE", *start_arguments,
                   "--prepare-staged-scoring", "--decline-staged-scoring")

    stdout, stderr, status = run_catalog(*start_arguments, "--decline-staged-scoring")
    assert status.success?, "start exited #{status.exitstatus}: #{stderr}\n#{stdout}"
    assert_empty stderr
    assert_includes stdout, "Operation handle: #{ID}"
    assert_includes stdout, "Gate: NEEDS_CANONICAL_MARKDOWN_PLACEMENT"
    refute_includes stdout, "READY_FOR_BOUNDARY"

    context_root = File.join(@fixture.front, "output", "ingest-contexts", "v0.1")
    assert_equal ["#{ID}.json"], Dir.children(context_root).sort
    context = JSON.parse(File.binread(File.join(context_root, "#{ID}.json")))
    store_root = AdventureFinderWorkspace::IngestOperationStore.default_root(
      front_door_root: @fixture.front
    )
    assert_equal [ID], Dir.children(store_root).grep(AdventureFinderWorkspace::IngestOperationStore::UUID_V4)
    store = AdventureFinderWorkspace::IngestOperationStore.new(root: store_root, roots: context.fetch("roots"))
    inspection = store.inspect(ID)
    assert_equal "VALID", inspection.fetch("operation_status")
    assert_equal "BOUND", inspection.fetch("artifact_state")
    assert inspection.fetch("bindings").all? { |binding| binding.fetch("status") == "PRESENT" }
    assert_equal %w[00000000.json 00000001.json],
                 Dir.children(File.join(store_root, ID, "revisions")).sort

    operation = inspection.fetch("operation")
    assert_equal ID, operation.fetch("operation_id")
    assert_equal 1, operation.fetch("revision")
    assert_nil operation.fetch("policy")
    assert_equal "explicit", operation.dig("base_catalog", "selection", "method")
    assert_equal "Fixture Operator", operation.dig("base_catalog", "selection", "selected_by")
    SOURCE_CHOICES.each do |key, value|
      assert_equal value, operation.dig("source_declaration", key, "value")
      assert_equal "Fixture Operator", operation.dig("source_declaration", key, "selected_by")
    end
    assert_equal @fixture.pdf, store.binding_path(ID, "input").to_s
    assert_equal @fixture.base, store.binding_path(ID, "base_catalog").to_s
    assert_binding(operation.dig("input", "content"), @fixture.pdf)
    assert_binding(operation.dig("base_catalog", "content"), @fixture.base)

    receipt_path = File.join(@fixture.converter, "build", "conversion-receipt.json")
    receipt = JSON.parse(File.binread(receipt_path))
    assert_equal "pdf-to-llm-md/conversion-receipt/v0.1", receipt.fetch("schema")
    assert_equal "ready", receipt.fetch("state")
    assert_equal true, receipt.fetch("downstream_ready")
    artifact = operation.fetch("artifacts").fetch(0)
    assert_equal 1, operation.fetch("artifacts").length
    assert_equal "conversion_receipt", artifact.fetch("kind")
    assert_equal "pdf-to-llm-md-converter", artifact.fetch("owner")
    assert_equal ["input"], artifact.fetch("inputs")
    assert_equal receipt_path, store.binding_path(ID, "conversion-receipt").to_s
    assert_binding(artifact.fetch("content"), receipt_path)
    assert_equal Digest::SHA256.file(receipt.fetch("output").fetch("path")).hexdigest,
                 receipt.dig("output", "sha256")

    decision_root = File.join(@fixture.front, "output", "staged-scoring-intents", "v0.1", ID)
    decision = JSON.parse(File.binread(File.join(decision_root, "decision.json")))
    assert_equal "decline", decision.fetch("choice")
    assert_equal "Fixture Operator", decision.fetch("selected_by")
    assert_equal "ingest_start", decision.fetch("interaction")
    assert_nil decision.fetch("intent_id")
    refute File.exist?(File.join(decision_root, "intent.json"))

    before = @fixture.operation_snapshot
    2.times do
      resumed_out, resumed_err, resumed_status = run_catalog("resume", ID)
      assert resumed_status.success?, "resume exited #{resumed_status.exitstatus}: #{resumed_err}"
      assert_empty resumed_err
      assert_includes resumed_out, "Ingest operation: #{ID}"
      assert_includes resumed_out, "Gate: NEEDS_CANONICAL_MARKDOWN_PLACEMENT"
      assert_equal before, @fixture.operation_snapshot
      assert_equal "VALID", store.inspect(ID).fetch("operation_status")
    end
    assert_empty @fixture.forbidden_calls
  end

  private

  def write_valid_synthetic_pdf
    objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
        "/Contents 4 0 R /Resources << >> >>",
      "<< /Length 0 >>\nstream\nendstream"
    ]
    pdf = +"%PDF-1.4\n"
    offsets = objects.each_with_index.map do |body, index|
      offset = pdf.bytesize
      pdf << "#{index + 1} 0 obj\n#{body}\nendobj\n"
      offset
    end
    xref = pdf.bytesize
    pdf << "xref\n0 5\n0000000000 65535 f \n"
    offsets.each { |offset| pdf << format("%010d 00000 n \n", offset) }
    pdf << "trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
    File.binwrite(@fixture.pdf, pdf)
  end

  def start_arguments(pdf: @fixture.pdf, base: @fixture.base)
    [
      "start", pdf,
      "--operation-id", ID,
      "--source-id", SOURCE_ID,
      "--edition", "Fixture edition",
      "--pagination-authority", "Explicit printed labels",
      "--publisher", "Fixture Publisher",
      "--base-catalog", base,
      "--selected-by", "Fixture Operator"
    ]
  end

  def run_catalog(*arguments)
    guard = File.expand_path("../test/support/offline_network_guard.rb", __dir__)
    environment = AdventureFinderWorkspace::OperatorAcceptance::CREDENTIAL_NAMES.to_h do |name|
      [name, nil]
    end
    environment["RUBYOPT"] = ["-r#{guard}", ENV["RUBYOPT"]].compact.join(" ")
    environment["AF_OPERATOR_ACCEPTANCE_OFFLINE"] = "1"
    @fixture.run_catalog(environment, *arguments)
  end

  def assert_refusal(code, *arguments)
    stdout, stderr, status = run_catalog(*arguments)
    refute status.success?, "unexpected admission: #{stdout}"
    assert_empty stdout
    assert_includes stderr, "af-catalog: #{code}:"
    refute File.exist?(File.join(@fixture.front, "output", "ingest-operations"))
    refute File.exist?(File.join(@fixture.front, "output", "ingest-contexts"))
    assert_empty @fixture.forbidden_calls
  end

  def assert_binding(content, path)
    assert_equal Digest::SHA256.file(path).hexdigest, content.fetch("sha256")
    assert_equal File.size(path), content.fetch("bytes")
  end
end
