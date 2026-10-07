# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

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
    %w[git ollama wlo rpof af-workloads af-cli-scoring-utility].each do |name|
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

  def test_missing_choices_and_unsupported_input_fail_before_creating_an_operation
    _stdout, stderr, status = run_catalog("start", @pdf)

    refute status.success?
    assert_includes stderr, "MISSING_CHOICE"
    refute File.exist?(operation_root)

    text = write(File.join(@input, "not-a-pdf.txt"), "not a pdf\n")
    _stdout, stderr, status = run_catalog(*start_arguments(pdf: text))
    refute status.success?
    assert_includes stderr, "UNSUPPORTED_INPUT"
    refute File.exist?(operation_root)
  end

  def test_reusing_a_handle_with_different_input_fails_closed
    _stdout, stderr, status = run_catalog(*start_arguments)
    assert status.success?, stderr
    other = write(File.join(@input, "other.pdf"), "%PDF different fixture\n")

    _stdout, conflict_err, conflict_status = run_catalog(*start_arguments(pdf: other))

    refute conflict_status.success?
    assert_includes conflict_err, "CONFLICT"
    assert_equal Digest::SHA256.file(@pdf).hexdigest, revision_document(0).dig("input", "content", "sha256")
  end

  def test_unknown_corrupt_context_and_corrupt_operation_are_distinct_failures
    _stdout, stderr, status = run_catalog("resume")
    refute status.success?
    assert_includes stderr, "INVALID_OPERATION_HANDLE"

    _stdout, stderr, status = run_catalog("resume", "not-a-handle")
    refute status.success?
    assert_includes stderr, "INVALID_OPERATION_HANDLE"

    _stdout, stderr, status = run_catalog("resume", ID)
    refute status.success?
    assert_includes stderr, "UNKNOWN_OPERATION"

    FileUtils.mkdir_p(context_root)
    File.binwrite(File.join(context_root, "#{ID}.json"), "{not json")
    _stdout, stderr, status = run_catalog("resume", ID)
    refute status.success?
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

  private

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
