# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"
require "zip"

module Ig07cSourceAcceptance
  class Fixture
    OPERATION_ID = "77777777-7777-4777-8777-777777777777"
    SOURCE_ID = "Fixture Source"
    PIPELINE_COMMANDS = %w[
      af-boundary-dossier
      af-boundary-editorial
      af-ingest-next
      af-source-intake
      af-source-place
      af-source-register
    ].freeze
    FORBIDDEN_COMMANDS = %w[
      git ollama wlo rpof af-workloads af-cli-scoring-utility
      af-boundary-freeze-apply af-evaluate-scoring-policy af-project-state
    ].freeze

    attr_reader :root, :front, :components, :pipeline, :source, :catalog,
                :converter, :pdf, :base, :policy, :canonical, :registry,
                :progress_log, :forbidden_log, :spec_root, :pipeline_data

    def initialize(repository_root:, pipeline_source_root:, split_pipeline: false)
      @repository_root = File.expand_path(repository_root)
      @pipeline_source_root = File.realpath(pipeline_source_root)
      @root = File.realpath(Dir.mktmpdir("ig07c-source-acceptance"))
      @spec_root = directory("public-specifications")
      require File.join(@pipeline_source_root, "lib/af_data_pipeline/editorial_specifications")
      public_root = ENV.fetch("AF_PUBLIC_SPEC_ROOT", File.expand_path("../af-specification-md", repository_root))
      selected = AfDataPipeline::EditorialSpecifications.bind!(public_root)
      ["documents.json", *selected.fetch("files").map { |file| file.fetch("filename") }].each do |filename|
        FileUtils.cp(File.join(public_root, filename), spec_root)
      end
      @front = directory("front-door")
      @components = directory("components")
      @pipeline = split_pipeline ? @pipeline_source_root : directory("components/af-data-pipeline")
      @pipeline_data = split_pipeline ? directory("pipeline-private") : @front
      @source = directory("components/md-for-llm-book-content")
      @converter = directory("components/pdf-to-llm-md-converter")
      @catalog = directory("catalog")
      @input = directory("input")
      @different_cwd = directory("different-working-directory")
      @sentinel_bin = directory("sentinel-bin")
      @pdf = write(File.join(@input, "owned.pdf"), "%PDF synthetic structural fixture\n")
      @base = File.join(@catalog, "5e_Adventure_Master_Catalog_0.0.1.xlsx")
      @policy = write(File.join(@root, "policy.yml"), "policy: fixture\n")
      @canonical = File.join(@source, "Fixture_Source_LLM_Edition.md")
      @registry = File.join(@source, "source_registry.yml")
      @progress_log = File.join(@root, "source-progress.jsonl")
      @forbidden_log = File.join(@root, "forbidden.jsonl")
      build_pipeline_facade unless split_pipeline
      build_converter
      build_sentinels
      allow_pipeline_identity_reads if split_pipeline
      build_catalog
      write_project_state
      write_registry
    end

    def close
      FileUtils.remove_entry(root) if File.exist?(root)
    end

    def start(extra_env = {})
      run_catalog(extra_env, *start_arguments)
    end

    def resume(extra_env = {})
      run_catalog(extra_env, "resume", OPERATION_ID, chdir: @different_cwd)
    end

    def run_catalog(extra_env = {}, *arguments, chdir: @repository_root, stdin_data: "")
      Open3.capture3(environment.merge(extra_env), command, *arguments, chdir:, stdin_data:)
    end

    def register_source
      Open3.capture3(
        environment,
        File.join(pipeline, "bin", "af-source-register"),
        canonical,
        "--source-root", source,
        "--source-id", SOURCE_ID,
        chdir: @different_cwd
      )
    end

    def write_registry(sources = nil)
      if sources.nil?
        write(File.join(source, "Existing.md"), "<!-- PDF Page 1 -->\n<!-- Printed Page 1 -->\n# Existing Fixture\n")
        sources = {"Existing Fixture" => {"file" => "Existing.md"}}
      end
      write(
        registry,
        YAML.dump(
          "schema_version" => "adventurefinder-source-registry/v0.1",
          "sources" => sources
        )
      )
    end

    def write_invalid_registry
      write(registry, YAML.dump("schema_version" => "wrong", "sources" => []))
    end

    def remove_registry
      FileUtils.rm_f(registry)
    end

    def precreate_conflicting_canonical
      write(canonical, "conflicting canonical bytes\n")
    end

    def corrupt_bound_source_intake
      File.open(source_intake_path, "ab") { |file| file.write("changed\n") }
    end

    def change_bound_source_intent
      path = revision_path(latest_revision)
      document = JSON.parse(File.binread(path))
      document.fetch("source_declaration").fetch("edition")["value"] = "changed edition"
      File.binwrite(path, JSON.pretty_generate(document) + "\n")
    end

    def revision_document(revision = latest_revision)
      JSON.parse(File.binread(revision_path(revision)))
    end

    def latest_revision
      Dir.glob(File.join(operation_root, "revisions", "*.json")).length - 1
    end

    def operation_snapshot
      snapshot(*Dir.glob(File.join(front, "output", "**", "*")).select { |path| File.file?(path) })
    end

    def snapshot(*paths)
      paths.sort.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }
    end

    def progress_calls
      return [] unless File.file?(progress_log)

      File.readlines(progress_log, chomp: true).map { |line| JSON.parse(line) }
    end

    def forbidden_calls
      return [] unless File.file?(forbidden_log)

      File.readlines(forbidden_log, chomp: true).map { |line| JSON.parse(line) }
    end

    def source_intake_path
      File.join(pipeline, "audits/pre-scoring/fixture-source-llm-edition-source-intake/source_intake.json")
    end

    def source_intake_companion
      File.join(File.dirname(source_intake_path), "source_intake.md")
    end

    def dossier_path
      File.join(pipeline, "audits/pre-scoring/fixture-source-boundary-dossier/boundary_dossier.json")
    end

    def dossier_companion
      File.join(File.dirname(dossier_path), "boundary_dossier.md")
    end

    def editorial_dir
      File.join(pipeline, "audits/pre-scoring/fixture-source-boundary-editorial")
    end

    private

    def command
      File.join(@repository_root, "bin", "af-catalog")
    end

    def operation_root
      File.join(front, "output", "ingest-operations", "v0.1", OPERATION_ID)
    end

    def revision_path(revision)
      File.join(operation_root, "revisions", format("%08d.json", revision))
    end

    def start_arguments
      [
        "start", pdf,
        "--operation-id", OPERATION_ID,
        "--source-id", SOURCE_ID,
        "--edition", "Fixture edition",
        "--pagination-authority", "Explicit printed labels",
        "--publisher", "Fixture Publisher",
        "--base-catalog", base,
        "--policy-definition", policy,
        "--policy-id", "fixture-source-policy",
        "--policy-version", "v0.1",
        "--policy-values", JSON.generate("execution" => "deferred"),
        "--selected-by", "Fixture Operator",
        "--canonical-destination", canonical,
        "--spec-root", spec_root
      ]
    end

    def environment
      {
        "AF_PROJECT_ROOT" => components,
        "AF_ADVENTURE_FINDER_ROOT" => front,
        "AF_PDF_CONVERTER_ROOT" => converter,
        "AF_DATA_PIPELINE_ROOT" => pipeline,
        "AF_SOURCE_ROOT" => source,
        "PATH" => [@sentinel_bin, ENV.fetch("PATH", "")].join(File::PATH_SEPARATOR)
      }.tap do |selection|
        if pipeline_data != front
          selection["AF_DATA_PIPELINE_DATA_ROOT"] = pipeline_data
          selection["AF_PIPELINE_EXPECTED_DATA_ROOT"] = pipeline_data
        end
      end
    end

    # Permit only the caller's read-only Git identity commands in the selected
    # public checkout. All other calls still reach the offline fixture sentinel.
    def allow_pipeline_identity_reads
      real_git = ENV.fetch("PATH").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "git") }
        .find { |path| File.executable?(path) }
      guard = File.join(@sentinel_bin, "git")
      File.binwrite(guard, File.binread(guard).sub("require \"json\"\n", <<~RUBY))
        require "json"
        prefix = %w[--no-optional-locks -c core.fsmonitor=false]
        commands = [
          %w[rev-parse --show-toplevel], %w[remote get-url --all origin],
          %w[remote get-url --push --all origin], %w[rev-parse HEAD],
          %w[status --porcelain --untracked-files=all], %w[ls-files -v]
        ]
        if Dir.pwd == #{@pipeline.inspect} && ARGV.take(3) == prefix && commands.include?(ARGV.drop(3))
          exec(#{real_git.inspect}, *ARGV)
        end
      RUBY
    end

    def build_pipeline_facade
      FileUtils.ln_s(File.join(@pipeline_source_root, "lib"), File.join(pipeline, "lib"))
      bin = directory("components/af-data-pipeline/bin")
      PIPELINE_COMMANDS.each do |name|
        FileUtils.ln_s(File.join(@pipeline_source_root, "bin", name), File.join(bin, name))
      end
      executable(File.join(bin, "af-source-progress"), source_progress_wrapper)
    end

    def source_progress_wrapper
      <<~RUBY
        require "digest"
        require "json"
        artifact = ARGV.fetch(0)
        input_path = ARGV.fetch(ARGV.index("--operation-input") + 1)
        File.open(#{progress_log.inspect}, "ab") do |file|
          file.puts(JSON.generate("artifact" => File.basename(artifact), "argv" => ARGV))
        end

        def canonical(value)
          case value
          when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
          when Array then value.map { |item| canonical(item) }
          else value
          end
        end

        projection = JSON.parse(File.binread(input_path))
        operation = projection.fetch("operation").except("contract_version").merge(
          "routing_input_sha256" => Digest::SHA256.hexdigest(JSON.generate(canonical(projection)))
        )
        artifact_type = case File.basename(artifact)
                        when "conversion-receipt.json" then "conversion_receipt"
                        when "source_intake.json" then "source_intake"
                        when "boundary_dossier.json" then "boundary_dossier"
                        else abort "unexpected source-progression artifact"
                        end
        input = {
          "artifact_type" => artifact_type,
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

        if ENV["IG07C_PROGRESS_MODE"] == "zero_missing"
          missing = {"sha256" => "a" * 64, "bytes" => 1}
          destination = ARGV.fetch(ARGV.index("--canonical-destination") + 1)
          outputs = [
            {"role" => "operation_artifact", "kind" => "source_intake",
             "owner" => "af-data-pipeline", "contract_version" => "af-source-intake/v0.1",
             "content" => missing.merge("locator" => {"root" => "pipeline", "path" => "missing/source_intake.json"})},
            {"role" => "canonical_source",
             "content" => missing.merge("locator" => {"root" => "source", "path" => File.basename(destination)})},
            {"role" => "companion_evidence",
             "content" => missing.merge("locator" => {"root" => "pipeline", "path" => "missing/source_intake.md"})}
          ]
          puts JSON.generate(
            "schema_version" => "af-source-progression-result/v0.1",
            "status" => "PASS", "state" => "SOURCE_INTAKE_READY",
            "transition" => "accepted_conversion_to_source_intake",
            "operation" => operation, "input" => input, "outputs" => outputs,
            "evidence" => ["fixture declared missing output"], "human_review" => [],
            "reused" => [], "contract" => contract
          )
          exit 0
        end

        if ENV["IG07C_PROGRESS_MODE"] == "pause_intake" && File.basename(artifact) == "source_intake.json"
          puts JSON.generate(
            "schema_version" => "af-source-progression-result/v0.1",
            "status" => "GATE", "state" => "NEEDS_SOURCE_REGISTRY_REVIEW",
            "transition" => nil, "operation" => operation, "input" => input,
            "outputs" => [], "evidence" => ["fixture pause after validated source intake"],
            "human_review" => ["Apply an explicit registry correction through af-source-register, then resume the same operation."],
            "reused" => [], "contract" => contract
          )
          exit 0
        end

        exec(#{File.join(@pipeline_source_root, "bin", "af-source-progress").inspect}, *ARGV)
      RUBY
    end

    def build_converter
      executable(File.join(converter, "bin", "convert-cached"), <<~RUBY)
        require "digest"
        require "fileutils"
        require "json"
        output_dir = ARGV.fetch(ARGV.index("--output-dir") + 1)
        FileUtils.mkdir_p(output_dir)
        markdown = File.join(output_dir, "fixture.md")
        body = case ENV["IG07C_MARKDOWN_MODE"]
               when "unknown_page"
                 "<!-- PDF Page 1 -->\\n# Structural Fixture\\n"
               when "synthetic_procedure"
                 "<!-- PDF Page 1 -->\\n<!-- Printed Page 1 -->\\n" \
                   "# Synthetic Procedure\\nEntry: select the marked input.\\n" \
                   "Middle: apply the stated transformation.\\nExit: record the output.\\n"
               else
                 "<!-- PDF Page 1 -->\\n<!-- Printed Page 1 -->\\n# Structural Fixture\\n"
               end
        File.binwrite(markdown, body)
        mode = ENV.fetch("IG07C_RECEIPT_MODE", "ready")
        state = mode == "page_review" ? "needs_page_review" : mode
        ready = mode == "ready"
        receipt = {
          "schema" => "pdf-to-llm-md/conversion-receipt/v0.1",
          "state" => state,
          "downstream_ready" => ready,
          "source" => {"path" => ARGV.fetch(0)},
          "output" => {"path" => markdown, "sha256" => Digest::SHA256.file(markdown).hexdigest},
          "unresolved_issue_fingerprints" => (mode == "page_review" ? ["fixture-page-1"] : []),
          "extraction_quality" => {
            "issues" => (mode == "page_review" ? [{"fingerprint" => "fixture-page-1", "pdf_page" => 1}] : [])
          }
        }
        path = File.join(output_dir, "conversion-receipt.json")
        File.binwrite(path, JSON.pretty_generate(receipt) + "\\n")
        puts "Conversion receipt: \#{path}"
      RUBY
    end

    def build_sentinels
      FORBIDDEN_COMMANDS.each do |name|
        executable(File.join(@sentinel_bin, name), <<~RUBY)
          require "json"
          File.open(#{forbidden_log.inspect}, "ab") do |file|
            file.puts(JSON.generate("program" => File.basename($PROGRAM_NAME), "argv" => ARGV))
          end
          exit 99
        RUBY
      end
    end

    def build_catalog
      headers = [
        "ADV - ID", "Adventure Title", "Page Count", "Source Book", "Book Publisher",
        "Start Page", "End Page", "Level Start", "Level End", "Scored"
      ]
      entries = {
        "[Content_Types].xml" => content_types_xml,
        "_rels/.rels" => package_relationships_xml,
        "xl/workbook.xml" => workbook_xml,
        "xl/_rels/workbook.xml.rels" => workbook_relationships_xml,
        "xl/worksheets/sheet1.xml" => worksheet_xml(headers),
        "xl/worksheets/sheet2.xml" => worksheet_xml(headers + [">99 pgs"])
      }
      Zip::File.open(base, create: true) do |zip|
        entries.each do |name, content|
          zip.get_output_stream(name) { |stream| stream.write(content) }
        end
      end
    end

    def write_project_state
      role = lambda do
        {
          "version" => "0.0.1",
          "filename" => File.basename(base),
          "sha256" => Digest::SHA256.file(base).hexdigest,
          "bytes" => File.size(base)
        }
      end
      write(
        File.join(catalog, "PROJECT_STATE.yml"),
        YAML.dump(
          "schema_version" => "adventurefinder-project-state/v0.2",
          "catalog_head" => role.call,
          "matcher_authorized_baseline" => role.call,
          "production_dependency_floor" => role.call
        )
      )
    end

    def worksheet_xml(headers)
      cells = headers.each_with_index.map do |header, index|
        reference = "#{column_name(index + 1)}1"
        %(<c r="#{reference}" t="inlineStr"><is><t>#{header}</t></is></c>)
      end.join
      <<~XML
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <dimension ref="A1:#{column_name(headers.length)}1"/>
          <sheetData><row r="1">#{cells}</row></sheetData>
        </worksheet>
      XML
    end

    def column_name(number)
      value = +""
      while number.positive?
        number -= 1
        value.prepend((65 + (number % 26)).chr)
        number /= 26
      end
      value
    end

    def content_types_xml
      <<~XML
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
          <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        </Types>
      XML
    end

    def package_relationships_xml
      <<~XML
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
      XML
    end

    def workbook_xml
      <<~XML
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>
            <sheet name="Adventure Catalog" sheetId="1" r:id="rId1"/>
            <sheet name="AMC &gt;100pg" sheetId="2" r:id="rId2"/>
          </sheets>
        </workbook>
      XML
    end

    def workbook_relationships_xml
      <<~XML
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
        </Relationships>
      XML
    end

    def directory(relative)
      File.join(root, relative).tap { |path| FileUtils.mkdir_p(path) }
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
end
