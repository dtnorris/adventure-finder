# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../lib/adventure_finder_ingest_source_driver"

class CatalogIngestSourceDriverTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path("..", __dir__)
  COMMAND = File.join(ROOT, "bin", "af-catalog")
  ID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

  def setup
    @temporary = Dir.mktmpdir("catalog source driver")
    @front = directory("adventure-finder")
    @components = directory("adventure-finder-components")
    @converter = directory("adventure-finder-components/pdf-to-llm-md-converter")
    @pipeline = directory("adventure-finder-components/af-data-pipeline")
    @source = directory("adventure-finder-components/md-for-llm-book-content")
    @input = directory("owned-inputs")
    @catalog = directory("catalog-data")
    @pdf = write(File.join(@input, "owned.pdf"), "%PDF synthetic fixture\n")
    @base = write(File.join(@catalog, "AMC.xlsx"), "synthetic catalog\n")
    @policy = write(File.join(@temporary, "policy.yml"), "policy fixture\n")
    @canonical = File.join(@source, "Fixture_Source_LLM_Edition.md")
    @progress_log = File.join(@temporary, "progress.jsonl")
    @router_log = File.join(@temporary, "router.jsonl")
    @forbidden_log = File.join(@temporary, "forbidden.log")
    @sentinel_bin = directory("sentinel-bin")
    %w[git ollama wlo rpof af-workloads af-cli-scoring-utility af-boundary-freeze-apply].each do |name|
      executable(File.join(@sentinel_bin, name), <<~RUBY)
        File.open(#{@forbidden_log.inspect}, "ab") { |file| file.puts(File.basename($PROGRAM_NAME)) }
        exit 99
      RUBY
    end
    fake_converter
    fake_router
    fake_progression
  end

  def teardown
    FileUtils.remove_entry(@temporary) if @temporary && File.exist?(@temporary)
  end

  def test_editable_review_publication_replays_decisions_and_refuses_conflicts
    bound_dir = directory("bound-editorial")
    %w[editorial_context.json editorial_decisions.yml editorial_review.md].each do |name|
      write(File.join(bound_dir, name), "original #{name}\n")
    end
    driver = AdventureFinderWorkspace::IngestSourceDriver.new(
      store: nil, routing: nil, project_root: @components,
      front_door_root: @front, pipeline_root: @pipeline,
      source_root: @source, catalog_root: @catalog
    )
    operation = {"operation_id" => ID, "revision" => 4}
    destination = driver.send(:editable_review_workspace, operation, Pathname(bound_dir))
    assert_equal editable_review_dir, destination.to_s

    decisions = destination.join("editorial_decisions.yml")
    File.binwrite(decisions, "reviewed decision\n")
    assert_equal destination, driver.send(:editable_review_workspace, operation, Pathname(bound_dir))
    assert_equal "reviewed decision\n", File.binread(decisions)

    File.binwrite(destination.join("editorial_context.json"), "changed context\n")
    refusal = driver.send(:editable_review_workspace, operation, Pathname(bound_dir))
    assert_equal "EDITORIAL_WORKSPACE_CONFLICT", refusal.dig("diagnostic", "code")
    assert_equal "reviewed decision\n", File.binread(decisions)

    FileUtils.remove_entry(destination)
    File.symlink(bound_dir, destination)
    refusal = driver.send(:editable_review_workspace, operation, Pathname(bound_dir))
    assert_equal "EDITORIAL_WORKSPACE_CONFLICT", refusal.dig("diagnostic", "code")
    File.unlink(destination)

    File.unlink(File.join(bound_dir, "editorial_review.md"))
    refusal = driver.send(:editable_review_workspace, operation, Pathname(bound_dir))
    assert_equal "INCOMPLETE_EDITORIAL_BUNDLE", refusal.dig("diagnostic", "code")
    refute File.exist?(destination)
  end

  def test_clean_start_reaches_boundary_review_and_repeat_resume_is_no_write
    stdout, stderr, status = run_catalog(*start_arguments)

    assert status.success?, stderr
    assert_includes stdout, "Gate: BOUNDARY_EDITORIAL_REVIEW"
    assert_includes stdout, "Review workspace: #{editable_review_dir}"
    document = revision_document(4)
    assert_equal ID, document.fetch("operation_id")
    assert_equal Digest::SHA256.file(@pdf).hexdigest, document.dig("input", "content", "sha256")
    assert_equal Digest::SHA256.file(@base).hexdigest, document.dig("base_catalog", "content", "sha256")
    assert_equal(
      ["Fixture Source", "First printing", "Printed page labels", "Fixture Publisher"],
      %w[source_id edition pagination_authority publisher].map do |key|
        document.dig("source_declaration", key, "value")
      end
    )
    assert_equal(
      {"profile" => "standard", "execution" => "deferred"},
      document.dig("policy", "selected_values")
    )
    assert_equal(
      %w[conversion_receipt source_intake boundary_dossier editorial_context editorial_decisions],
      document.fetch("artifacts").map { |item| item.fetch("kind") }
    )
    context = JSON.parse(File.binread(context_path))
    assert_equal "adventurefinder-catalog-ingest-context/v0.2", context.fetch("contract_version")
    assert_equal(
      {"root" => "source", "path" => File.basename(@canonical)},
      context.dig("source_progression", "canonical_destination")
    )
    assert_equal 3, progress_calls.length
    assert progress_calls.all? { |call| File.basename(call.fetch("program")) == "af-source-progress" }
    allowed_options = %w[--operation-input --source-root --catalog-root --pipeline-root
                         --canonical-destination --json]
    assert(
      progress_calls.all? do |call|
        call.fetch("argv").grep(/\A--/).all? { |option| allowed_options.include?(option) }
      end
    )
    refute File.exist?(@forbidden_log)
    before = operation_snapshot
    calls_before = progress_calls.length

    resumed_out, resumed_err, resumed_status = run_catalog("resume", ID)

    assert resumed_status.success?, resumed_err
    assert_includes resumed_out, "Gate: BOUNDARY_EDITORIAL_REVIEW"
    assert_equal before, operation_snapshot
    assert_equal calls_before, progress_calls.length
  end

  def test_editorial_decisions_can_be_reviewed_without_changing_bound_operation_bytes
    stdout, stderr, status = run_catalog(*start_arguments)
    assert status.success?, stderr
    assert_includes stdout, "Review workspace: #{editable_review_dir}"
    bound = File.join(editorial_dir, "editorial_decisions.yml")
    original_digest = Digest::SHA256.file(bound).hexdigest
    reviewed = File.join(editable_review_dir, "editorial_decisions.yml")
    File.open(reviewed, "ab") { |file| file.write("# reviewed candidate evidence\n") }

    resumed_out, resumed_err, resumed_status = run_catalog("resume", ID)
    assert resumed_status.success?, resumed_err
    assert_includes resumed_out, "Gate: BOUNDARY_EDITORIAL_REVIEW"
    assert_includes resumed_out, "Review workspace: #{editable_review_dir}"
    assert_equal original_digest, Digest::SHA256.file(bound).hexdigest
    refute_equal original_digest, Digest::SHA256.file(reviewed).hexdigest
    assert_equal 4, latest_revision
  end

  def test_changed_review_context_refuses_replay_without_rewriting_human_ledger
    _, stderr, status = run_catalog(*start_arguments)
    assert status.success?, stderr
    context = File.join(editable_review_dir, "editorial_context.json")
    ledger = File.join(editable_review_dir, "editorial_decisions.yml")
    File.open(context, "ab") { |file| file.write("# changed context\n") }
    File.open(ledger, "ab") { |file| file.write("# reviewed candidate evidence\n") }
    before = Digest::SHA256.file(ledger).hexdigest

    stdout, _, resumed = run_catalog("resume", ID)
    assert_equal 2, resumed.exitstatus
    assert_includes stdout, "Diagnostic: EDITORIAL_WORKSPACE_CONFLICT"
    assert_equal before, Digest::SHA256.file(ledger).hexdigest
    assert_equal 4, latest_revision
  end

  def test_symlinked_review_workspace_is_refused_without_following_it
    FileUtils.mkdir_p(File.dirname(editable_review_dir))
    File.symlink(editorial_dir, editable_review_dir)

    stdout, _, status = run_catalog(*start_arguments)

    assert_equal 2, status.exitstatus
    assert_includes stdout, "Diagnostic: EDITORIAL_WORKSPACE_CONFLICT"
    assert File.symlink?(editable_review_dir)
  end

  def test_fresh_resume_after_intake_reuses_byte_identical_upstream_artifacts
    stdout, stderr, status = run_catalog(
      {"PROGRESS_GATE_ON" => "source_intake.json"},
      *start_arguments
    )
    assert status.success?, stderr
    assert_includes stdout, "Gate: NEEDS_SOURCE_QA_REVIEW"
    assert_equal 2, latest_revision
    upstream = snapshot_paths(@canonical, source_intake_path, source_intake_companion)

    resumed_out, resumed_err, resumed_status = run_catalog("resume", ID)

    assert resumed_status.success?, resumed_err
    assert_includes resumed_out, "Gate: BOUNDARY_EDITORIAL_REVIEW"
    assert_equal upstream, snapshot_paths(@canonical, source_intake_path, source_intake_companion)
    assert_equal 4, latest_revision
  end

  def test_fresh_resume_after_dossier_reuses_byte_identical_upstream_artifacts
    stdout, stderr, status = run_catalog(
      {"PROGRESS_GATE_ON" => "boundary_dossier.json"},
      *start_arguments
    )
    assert status.success?, stderr
    assert_includes stdout, "Gate: NEEDS_SOURCE_QA_REVIEW"
    assert_equal 3, latest_revision
    upstream = snapshot_paths(
      @canonical, source_intake_path, source_intake_companion,
      boundary_dossier_path, boundary_dossier_companion
    )

    resumed_out, resumed_err, resumed_status = run_catalog("resume", ID)

    assert resumed_status.success?, resumed_err
    assert_includes resumed_out, "Gate: BOUNDARY_EDITORIAL_REVIEW"
    assert_equal upstream, snapshot_paths(
      @canonical, source_intake_path, source_intake_companion,
      boundary_dossier_path, boundary_dossier_companion
    )
    assert_equal 4, latest_revision
  end

  def test_zero_exit_with_missing_output_and_mismatched_identity_fail_closed
    stdout, _stderr, status = run_catalog(
      {"PROGRESS_MODE" => "missing_output"},
      *start_arguments
    )
    assert_equal 2, status.exitstatus
    assert_includes stdout, "Diagnostic: SOURCE_PROGRESSION_PROTOCOL_ERROR"
    assert_equal 1, latest_revision
    assert_equal 1, progress_calls.length

    reset_front_door
    stdout, _stderr, status = run_catalog(
      {"PROGRESS_MODE" => "wrong_destination"},
      *start_arguments
    )
    assert_equal 2, status.exitstatus
    assert_includes stdout, "operation-bound destination"
    assert_equal 1, latest_revision
    assert_equal 1, progress_calls.length

    reset_front_door
    stdout, _stderr, status = run_catalog(
      {"PROGRESS_MODE" => "wrong_identity"},
      *start_arguments
    )
    assert_equal 2, status.exitstatus
    assert_includes stdout, "Diagnostic: SOURCE_PROGRESSION_PROTOCOL_ERROR"
    assert_equal 1, latest_revision
    assert_equal 1, progress_calls.length
  end

  def test_page_gate_and_wider_router_state_are_never_bypassed
    stdout, stderr, status = run_catalog(
      {"PROGRESS_GATE_ON" => "conversion-receipt.json", "PROGRESS_GATE_STATE" => "NEEDS_PAGE_REVIEW"},
      *start_arguments
    )
    assert status.success?, stderr
    assert_includes stdout, "Gate: NEEDS_PAGE_REVIEW"
    assert_equal 1, latest_revision
    assert_equal 1, progress_calls.length

    reset_front_door
    stdout, stderr, status = run_catalog(
      {"ROUTER_INTAKE_STATE" => "NEEDS_SOURCE_REGISTRY_REVIEW"},
      *start_arguments
    )
    assert status.success?, stderr
    assert_includes stdout, "Gate: NEEDS_SOURCE_REGISTRY_REVIEW"
    assert_equal 2, latest_revision
    assert_equal 1, progress_calls.length

    reset_front_door
    stdout, stderr, status = run_catalog(
      {"ROUTER_DOSSIER_STATE" => "READY_FOR_BOUNDARY_FREEZE"},
      *start_arguments
    )
    assert status.success?, stderr
    assert_includes stdout, "Gate: READY_FOR_BOUNDARY_FREEZE"
    assert_equal 3, latest_revision
    assert_equal 2, progress_calls.length
    refute File.exist?(@forbidden_log)
  end

  def test_canonical_destination_must_be_an_explicit_safe_markdown_path
    arguments = start_arguments
    arguments[arguments.index(@canonical)] = File.join(@temporary, "outside.md")

    _stdout, stderr, status = run_catalog(*arguments)

    refute status.success?
    assert_includes stderr, "UNSAFE_PATH"
    refute File.exist?(operation_root)
    assert_empty progress_calls
  end

  private

  def start_arguments
    [
      "start", @pdf,
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
      "--selected-by", "David",
      "--canonical-destination", @canonical
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
      require "json"
      output = ARGV.fetch(ARGV.index("--output-dir") + 1)
      FileUtils.mkdir_p(output)
      receipt = File.join(output, "conversion-receipt.json")
      File.binwrite(receipt, JSON.generate("schema" => "pdf-to-llm-md/conversion-receipt/v0.1") + "\\n")
      puts "Conversion receipt: \#{receipt}"
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
      artifact = ARGV.first
      operation_input = ARGV.fetch(ARGV.index("--operation-input") + 1)
      projection = JSON.parse(File.binread(operation_input))
      basename = File.basename(artifact)
      state, type = case basename
                    when "conversion-receipt.json"
                      ["NEEDS_CANONICAL_MARKDOWN_PLACEMENT", "conversion_receipt"]
                    when "source_intake.json"
                      [ENV.fetch("ROUTER_INTAKE_STATE", "READY_FOR_SOURCE_REGISTRATION"), "source_intake"]
                    when "boundary_dossier.json"
                      [ENV.fetch("ROUTER_DOSSIER_STATE", "READY_FOR_EDITORIAL_HANDOFF"), "boundary_dossier"]
                    else
                      abort "unexpected routing artifact \#{artifact}"
                    end
      File.open(#{@router_log.inspect}, "ab") do |file|
        file.puts(JSON.generate("artifact" => basename, "program" => $PROGRAM_NAME, "argv" => ARGV))
      end
      operation = projection.fetch("operation").except("contract_version").merge(
        "routing_input_sha256" => Digest::SHA256.hexdigest(JSON.generate(canonical(projection)))
      )
      puts JSON.generate(
        "schema_version" => "af-ingest-routing-result/v0.1",
        "operation" => operation,
        "route" => {
          "state" => state,
          "artifact_type" => type,
          "evidence" => ["validated fixture evidence"],
          "human_review" => [],
          "commands" => [],
          "warnings" => []
        }
      )
    RUBY
  end

  def fake_progression
    executable(File.join(@pipeline, "bin", "af-source-progress"), <<~RUBY)
      require "digest"
      require "fileutils"
      require "json"
      def canonical(value)
        case value
        when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
        when Array then value.map { |item| canonical(item) }
        else value
        end
      end
      def content(root_name, root, path)
        {
          "sha256" => Digest::SHA256.file(path).hexdigest,
          "bytes" => File.size(path),
          "locator" => {"root" => root_name, "path" => path.delete_prefix(root + "/")}
        }
      end
      def write(path, bytes)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, bytes) unless File.exist?(path)
        path
      end
      artifact = ARGV.first
      operation_input = ARGV.fetch(ARGV.index("--operation-input") + 1)
      source_root = ARGV.fetch(ARGV.index("--source-root") + 1)
      pipeline_root = ARGV.fetch(ARGV.index("--pipeline-root") + 1)
      projection = JSON.parse(File.binread(operation_input))
      basename = File.basename(artifact)
      type, state, transition = case basename
                                when "conversion-receipt.json"
                                  ["conversion_receipt", "SOURCE_INTAKE_READY", "accepted_conversion_to_source_intake"]
                                when "source_intake.json"
                                  ["source_intake", "BOUNDARY_DOSSIER_READY", "source_intake_to_boundary_dossier"]
                                when "boundary_dossier.json"
                                  ["boundary_dossier", "BOUNDARY_EDITORIAL_HANDOFF_READY", "boundary_dossier_to_editorial_handoff"]
                                else
                                  abort "unexpected progression artifact \#{artifact}"
                                end
      File.open(#{@progress_log.inspect}, "ab") do |file|
        file.puts(JSON.generate("artifact" => basename, "program" => $PROGRAM_NAME, "argv" => ARGV))
      end
      operation = projection.fetch("operation").except("contract_version").merge(
        "routing_input_sha256" => Digest::SHA256.hexdigest(JSON.generate(canonical(projection)))
      )
      operation["operation_id"] = "cccccccc-cccc-4ccc-8ccc-cccccccccccc" if ENV["PROGRESS_MODE"] == "wrong_identity"
      input = {
        "artifact_type" => type,
        "binding" => projection.fetch("artifact"),
        "validated" => true
      }
      contract = {
        "one_transition_maximum" => true,
        "operation_lifecycle_mutated" => false,
        "semantic_choices_created" => false,
        "catalog_roles_mutated" => false,
        "inference_or_scoring_executed" => false
      }
      if ENV["PROGRESS_GATE_ON"] == basename
        puts JSON.generate(
          "schema_version" => "af-source-progression-result/v0.1",
          "status" => "GATE",
          "state" => ENV.fetch("PROGRESS_GATE_STATE", "NEEDS_SOURCE_QA_REVIEW"),
          "transition" => nil,
          "operation" => operation,
          "input" => input,
          "outputs" => [],
          "evidence" => ["fixture gate evidence"],
          "human_review" => ["review fixture evidence"],
          "reused" => [],
          "contract" => contract
        )
        exit
      end

      outputs = case type
                when "conversion_receipt"
                  destination = ARGV.fetch(ARGV.index("--canonical-destination") + 1)
                  write(destination, "canonical fixture\\n")
                  reported_destination = if ENV["PROGRESS_MODE"] == "wrong_destination"
                                           write(File.join(source_root, "Wrong.md"), "canonical fixture\\n")
                                         else
                                           destination
                                         end
                  intake = write(
                    File.join(pipeline_root, "audits/pre-scoring/fixture-source-source-intake/source_intake.json"),
                    "{\\\"schema_version\\\":\\\"af-source-intake/v0.1\\\"}\\n"
                  )
                  companion = write(File.join(File.dirname(intake), "source_intake.md"), "intake companion\\n")
                  artifact_content = if ENV["PROGRESS_MODE"] == "missing_output"
                                       {"sha256" => ("a" * 64), "bytes" => 1,
                                        "locator" => {"root" => "pipeline", "path" => "missing/source_intake.json"}}
                                     else
                                       content("pipeline", pipeline_root, intake)
                                     end
                  [
                    {"role" => "operation_artifact", "kind" => "source_intake",
                     "owner" => "af-data-pipeline", "contract_version" => "af-source-intake/v0.1",
                     "content" => artifact_content},
                    {"role" => "canonical_source", "content" => content("source", source_root, reported_destination)},
                    {"role" => "companion_evidence", "content" => content("pipeline", pipeline_root, companion)}
                  ]
                when "source_intake"
                  dossier = write(
                    File.join(pipeline_root, "audits/pre-scoring/fixture-source-boundary-dossier/boundary_dossier.json"),
                    "{\\\"schema_version\\\":\\\"af-boundary-dossier/v0.2\\\"}\\n"
                  )
                  companion = write(File.join(File.dirname(dossier), "boundary_dossier.md"), "dossier companion\\n")
                  [
                    {"role" => "operation_artifact", "kind" => "boundary_dossier",
                     "owner" => "af-data-pipeline", "contract_version" => "af-boundary-dossier/v0.2",
                     "content" => content("pipeline", pipeline_root, dossier)},
                    {"role" => "companion_evidence", "content" => content("pipeline", pipeline_root, companion)}
                  ]
                when "boundary_dossier"
                  directory = File.join(pipeline_root, "audits/pre-scoring/fixture-source-boundary-editorial")
                  context = write(File.join(directory, "editorial_context.json"), "{\\\"fixture\\\":true}\\n")
                  decisions = write(File.join(directory, "editorial_decisions.yml"), "---\\ncandidates: []\\n")
                  review = write(File.join(directory, "editorial_review.md"), "review fixture\\n")
                  [
                    {"role" => "operation_artifact", "kind" => "editorial_context",
                     "owner" => "af-data-pipeline", "contract_version" => "af-boundary-editorial-context/v0.1",
                     "content" => content("pipeline", pipeline_root, context)},
                    {"role" => "operation_artifact", "kind" => "editorial_decisions",
                     "owner" => "af-data-pipeline", "contract_version" => "af-boundary-editorial-decisions/v0.2",
                     "content" => content("pipeline", pipeline_root, decisions)},
                    {"role" => "companion_evidence", "content" => content("pipeline", pipeline_root, review)}
                  ]
                end
      puts JSON.generate(
        "schema_version" => "af-source-progression-result/v0.1",
        "status" => "PASS",
        "state" => state,
        "transition" => transition,
        "operation" => operation,
        "input" => input,
        "outputs" => outputs,
        "evidence" => ["validated fixture output"],
        "human_review" => [],
        "reused" => [],
        "contract" => contract
      )
    RUBY
  end

  def revision_document(revision)
    JSON.parse(File.binread(File.join(operation_root, "revisions", format("%08d.json", revision))))
  end

  def latest_revision
    Dir.glob(File.join(operation_root, "revisions", "*.json")).length - 1
  end

  def operation_root
    File.join(@front, "output", "ingest-operations", "v0.1", ID)
  end

  def context_path
    File.join(@front, "output", "ingest-contexts", "v0.1", "#{ID}.json")
  end

  def source_intake_path
    File.join(@pipeline, "audits/pre-scoring/fixture-source-source-intake/source_intake.json")
  end

  def source_intake_companion
    File.join(File.dirname(source_intake_path), "source_intake.md")
  end

  def boundary_dossier_path
    File.join(@pipeline, "audits/pre-scoring/fixture-source-boundary-dossier/boundary_dossier.json")
  end

  def boundary_dossier_companion
    File.join(File.dirname(boundary_dossier_path), "boundary_dossier.md")
  end

  def editorial_dir
    File.join(@pipeline, "audits/pre-scoring/fixture-source-boundary-editorial")
  end

  def editable_review_dir
    File.join(@front, "output", "ingest-editorial-workspaces", "v0.1", ID)
  end

  def progress_calls
    return [] unless File.file?(@progress_log)

    File.readlines(@progress_log, chomp: true).map { |line| JSON.parse(line) }
  end

  def operation_snapshot
    Dir.glob(File.join(@front, "output", "**", "*"), File::FNM_DOTMATCH)
       .select { |path| File.file?(path) }
       .sort.to_h { |path| [path.delete_prefix(@front), Digest::SHA256.file(path).hexdigest] }
  end

  def snapshot_paths(*paths)
    paths.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }
  end

  def reset_front_door
    FileUtils.remove_entry(@front)
    FileUtils.mkdir_p(@front)
    FileUtils.rm_f(@progress_log)
    FileUtils.rm_f(@router_log)
  end

  def directory(relative)
    File.join(@temporary, relative).tap { |path| FileUtils.mkdir_p(path) }
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
