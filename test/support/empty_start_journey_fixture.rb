# frozen_string_literal: true

require_relative "frontier_journey_fixture"

module Ig07cSourceAcceptance
  # Uses the accepted XL-02 constructor and MD-02 registry representation.
  # Catalog history is copied only from the explicit operator-approved empty baseline.
  class EmptyStartFixture < FrontierJourneyFixture
    # Empty final controls are separate public-entry worlds, never erased to
    # recover a positive. Returns false to skip the legacy branch cleanup.
    def final_approval_controls?
      false
    end

    # Runs one final approval refusal after real release readiness. Keeps the
    # resulting decision/request and last accepted export for inspection; returns
    # nil or raises on mutation/export. The caller ends this independent world.
    def verify_final_review_control(extra_env, answer)
      export_frontier
      protected = [catalog, source, File.join(data_root, "output/ingest-releases"),
        File.join(front, "output/local-ingest-executions"), File.join(components, "af-workloads"), @pack]
        .to_h { |path| [path, inventory(path)] }
      stdout, stderr, status = approve_and_export(extra_env, "resume", OPERATION_ID,
        "--approve-final-by", "Fixture Operator", stdin_data: answer)
      expected = answer.empty? ? "No approval recorded." : "DECLINED"
      raise "final refusal advanced: #{stdout}\n#{stderr}" unless
        !status.success? && stdout.include?(expected) &&
        protected.all? { |path, before| inventory(path) == before }
      puts "FINAL_REVIEW_CONTROL=#{expected} verified LAST_ACCEPTED_EXPORT=unchanged DECISION=retained"
    end

    # Exercises existing converter readiness/QA authority at the public entry.
    # No separate source-approval CLI exists: blocked conversion and unresolved
    # page review are the applicable owner gates. Fresh resume must preserve them.
    def verify_source_review_control(extra_env, arguments, mode)
      before = [inventory(catalog), inventory(source)]
      selected = extra_env.merge("IG07C_RECEIPT_MODE" => mode)
      stdout, stderr, status = run_catalog(selected, *arguments)
      expected = mode == "page_review" ? "NEEDS_PAGE_REVIEW" : "BLOCKED_CONVERSION"
      raise "source review control advanced: #{stdout}\n#{stderr}" unless
        status.success? && stdout.include?("Gate: #{expected}") &&
        before == [inventory(catalog), inventory(source)] && !File.exist?(canonical)
      retained = [inventory(front), inventory(data_root)]
      stdout, stderr, status = run_catalog(selected, "resume", OPERATION_ID)
      raise "source review replay advanced: #{stdout}\n#{stderr}" unless
        status.success? && stdout.include?("Gate: #{expected}") &&
        retained == [inventory(front), inventory(data_root)] && before == [inventory(catalog), inventory(source)] &&
        !File.exist?(File.join(root, "frontier-pack")) && forbidden_calls.empty?
      puts "SOURCE_REVIEW_CONTROL=#{expected} verified REGISTRY=empty ROLES=unchanged EXPORT=absent"
    end

    # Withholds boundary authority, then explicitly holds the reviewed candidate.
    # Both public resumes stop before allocation; the original ledger is restored
    # before the independent explicit positive. No approval file is regenerated.
    def verify_boundary_review_controls(extra_env, ledger_path)
      before = [inventory(catalog), inventory(source), inventory(data_root), inventory(front)]
      stdout, stderr, status = run_catalog(extra_env, "resume", OPERATION_ID)
      raise "missing boundary authority advanced: #{stdout}\n#{stderr}" unless
        status.success? && stdout.include?("BOUNDARY_EDITORIAL_REVIEW") &&
        before == [inventory(catalog), inventory(source), inventory(data_root), inventory(front)]
      puts "BOUNDARY_REVIEW_CONTROL=missing verified ALLOCATION=absent"
      held = YAML.safe_load_file(ledger_path)
      held.fetch("candidates").each do |candidate|
        candidate.delete("decision")
        candidate["disposition"] = "hold"
        candidate["decision_rationale"] = "Fixture operator withholds boundary acceptance."
      end
      with_changed_artifact(ledger_path, YAML.dump(held)) do
        before = [inventory(catalog), inventory(source), inventory(data_root), inventory(front)]
        stdout, stderr, status = run_catalog(extra_env, "resume", OPERATION_ID,
          "--approve-final-by", "Fixture Operator", stdin_data: "APPROVE\n")
        raise "held boundary advanced: #{stdout}\n#{stderr}" unless
          !status.success? && (stdout + stderr).include?("FINAL_APPROVAL_NOT_READY") &&
          before == [inventory(catalog), inventory(source), inventory(data_root), inventory(front)] &&
          !File.exist?(File.join(root, "frontier-pack"))
        puts "BOUNDARY_REVIEW_CONTROL=held verified ALLOCATION=absent EXPORT=absent"
      end
    end

    # Copies the metadata-free AF candidate only when explicitly requested by
    # the inherited setup. Owner repositories still use the original reader.
    # Returns nil; links, nonregular files or a missing candidate raise.
    def self.copy_runtime(source, destination, names: %w[bin lib config schemas contracts specifications Gemfile Gemfile.lock], include_candidate: false)
      return super unless include_candidate && !File.exist?(File.join(source, ".git"))

      raise "missing AF candidate" unless File.file?(File.join(source, "bin/af-catalog"))
      names.each do |name|
        Dir.glob(File.join(source, name, "**", "*"), File::FNM_DOTMATCH).sort.each do |path|
          next if File.directory?(path) && !File.symlink?(path)
          raise "unsafe AF candidate entry: #{path}" unless File.file?(path) && !File.symlink?(path)

          target = File.join(destination, path.delete_prefix(source + "/"))
          FileUtils.mkdir_p(File.dirname(target))
          FileUtils.cp(path, target, preserve: true)
        end
      end
      nil
    end

    # Adds only unassigned workflow fill definitions to a newly empty workbook.
    # The accepted owner constructor supplies every worksheet and base style.
    # Returns path; duplicate fills, malformed XML or ZIP failures raise.
    def self.add_release_fills(path)
      Zip::File.open(path) do |zip|
        document = REXML::Document.new(zip.read("xl/styles.xml"))
        fills = REXML::XPath.first(document, "//s:styleSheet/s:fills", AfDataPipeline::AmcApply::NS)
        raise "missing empty-workbook fills" unless fills

        [AfDataPipeline::AmcApply::REQUIRED_FILL, AfDataPipeline::AmcFinalize::ACCEPTED_FILL].each do |color|
          present = REXML::XPath.match(fills, "./s:fill/s:patternFill/s:fgColor", AfDataPipeline::AmcApply::NS)
            .any? { |node| node.attributes["rgb"].to_s.upcase.end_with?(color.delete_prefix("#")) }
          raise "workflow fill already present: #{color}" if present

          pattern = fills.add_element("fill").add_element("patternFill", {"patternType" => "solid"})
          pattern.add_element("fgColor", {"rgb" => "FF#{color.delete_prefix('#')}"})
          pattern.add_element("bgColor", {"indexed" => "64"})
        end
        fills.attributes["count"] = fills.elements.to_a.length.to_s
        zip.get_output_stream("xl/styles.xml") { |stream| stream.write(AfDataPipeline::AmcApply.serialize_xml(document)) }
      end
      path
    end

    # Records independently resolved roles, owner validation and zero cells.
    # Returns a measurement hash; any representation mismatch raises.
    def measure_empty_inputs
      require File.join(pipeline, "lib/af_data_pipeline/project_state")
      require File.join(pipeline, "lib/af_data_pipeline/amc_compatibility_check")
      workbook = AfDataPipeline::BoundaryFreezeApply::Workbook.new(base)
      sheets = ["Adventure Catalog", "AMC >100pg"].to_h do |name|
        sheet = workbook.sheet_by_name!(name)
        sheet.validate_catalog_schema!
        raise "seeded catalog records" unless sheet.catalog_records.empty?
        first = name == "Adventure Catalog" ? 2 : 3
        raise "nonblank catalog capacity" unless sheet.cell_references.grep(/\d+$/).all? do |reference|
          row = reference[/\d+$/].to_i
          row < first || (sheet.cell_value(reference).nil? && sheet.cell_formula(sheet.cell(reference)).nil?)
        end
        [name, {records: 0, first_slots: sheet.next_available_rows(2)}]
      end
      books = workbook.sheet_by_name!("Current Books")
      raise "seeded source/publisher" unless books.rows_with_nonblank("C") == [4] && books.rows_with_nonblank("H") == [4] && books.rows_with_nonblank("D").empty?
      raise "nonzero summary" unless %w[B2 C2 G2 H2].all? { |ref| books.cell_value(ref) == 0 }
      raise "unsafe ratios" unless books.cell_formula(books.cell("A4")) == "IF($B$2=0,0,B4/$B$2)" && books.cell_formula(books.cell("F4")) == "IF($G$2=0,0,G4/$G$2)"
      raise "seeded registry" unless AfDataPipeline::BoundaryFreeze.registry_context(source, nil).fetch("sources") == {}
      state = AfDataPipeline::ProjectState.new(manifest_path: File.join(catalog, "PROJECT_STATE.yml"))
      state.validate!
      roles = AfDataPipeline::ProjectState::ROLES.to_h do |role|
        resolved = state.resolve(role)
        [role, {version: resolved.version, filename: resolved.filename, sha256: resolved.sha256, bytes: resolved.bytes}]
      end
      styles = AfDataPipeline::AmcApply::Workbook.new(base).styles
      red_style = styles.red_style_for(1)
      accepted_style = styles.style_for_fill(1, AfDataPipeline::AmcFinalize::ACCEPTED_FILL)
      raise "workflow fill resolution failed" unless
        styles.fill_rgb(red_style.to_s) == AfDataPipeline::AmcApply::REQUIRED_FILL &&
        styles.fill_rgb(accepted_style.to_s) == AfDataPipeline::AmcFinalize::ACCEPTED_FILL
      measurement = {sheets: sheets, roles: roles, registry_sources: 0,
        registry_sha256: Digest::SHA256.file(registry).hexdigest,
        compatibility: AfDataPipeline::AmcCompatibilityCheck.validate!(candidate_path: base)}
      initial = directory("evidence/empty-inputs")
      [base, registry, File.join(catalog, "PROJECT_STATE.yml")].each { |path| FileUtils.cp(path, initial, preserve: true) }
      File.binwrite(File.join(initial, "measurement.json"), JSON.pretty_generate(measurement) + "\n")
      measurement
    end

    # Keeps the inherited Frontier checks while identifying this empty input
    # composition and its separately authorized baseline. No fixture is approved here.
    def prepare_frontier(sources)
      super
      @fake_inventory["catalog"] = "Exact operator-authorized empty baseline; independent copy, no populated archive."
      File.write(File.join(root, "evidence/frontier-inputs.json"), JSON.pretty_generate(
        source_heads: @source_heads, ontology: @ontology_binding, fakes: @fake_inventory,
        empty_baseline: @empty_baseline_binding) + "\n")
    end

    # Records the inherited real adoption/consumer proof at its empty-start scope.
    # Full AF/owner gates and remaining approval controls are not implied by this run.
    def write_frontier_report(report)
      report["task"] = "OS-INT-02"
      report["focused_journey"] = "PASS: empty registration through exact adoption and Frontier consumption"
      report["empty_baseline"] = @empty_baseline_binding
      report["acceptance"] = {
        "A" => "PASS: empty inputs and explicitly authorized baseline",
        "B" => "PASS: synthetic public-entry composition",
        "C" => "PARTIAL: boundary hold/missing, handoff and staleness controls passed in this journey; source QA and final decline/missing require separate control runs",
        "D" => "PASS: retained preapproval pause and fresh-process accepted replay",
        "E" => "PENDING: full AF/owner/host gates and operator acceptance"
      }
      report["five_increments"].first["status"] = "PASS: explicitly supplied mechanical empty baseline and first ingestion"
      report["five_increments"].first["required_evidence"] = "NOT RUN: public independent setup/initialization"
      File.write(File.join(root, "evidence/os-int-02-report.json"), JSON.pretty_generate(report) + "\n")
      puts "OS_INT_02_RESULT=#{JSON.generate(report)}"
    end

    private

    # Invokes only the inspected, content-free owner constructor. It writes new
    # ZIP bytes, never reads a catalog template and performs no Git operations.
    def build_catalog
      if ENV["AF_ACCEPTANCE_EMPTY_BASELINE"]
        baseline = File.expand_path(ENV.fetch("AF_ACCEPTANCE_EMPTY_BASELINE"))
        raise "linked empty baseline" unless File.realpath(baseline) == baseline
        receipt_path = File.join(baseline, "baseline.json")
        raise "baseline receipt changed" unless Digest::SHA256.file(receipt_path).hexdigest ==
          ENV.fetch("AF_ACCEPTANCE_EMPTY_BASELINE_RECEIPT_SHA256")
        receipt = JSON.parse(File.binread(receipt_path))
        raise "wrong baseline receipt" unless receipt.fetch("target") == baseline &&
          receipt.fetch("status") == "PASS: exact empty baseline only"
        @empty_baseline = baseline
        baseline_catalog = File.join(baseline, "catalog")
        expected_head = ENV.fetch("AF_ACCEPTANCE_EMPTY_BASELINE_HEAD")
        head, error, status = Open3.capture3({"GIT_OPTIONAL_LOCKS" => "0"}, "git", "-C", baseline_catalog, "rev-parse", "HEAD")
        raise "empty baseline HEAD differs: #{error}" unless status.success? && head.strip == expected_head && receipt.fetch("head") == expected_head
        [File.basename(base), "PROJECT_STATE.yml"].each do |name|
          path = File.join(baseline_catalog, name)
          raise "empty baseline file changed" unless Digest::SHA256.file(path).hexdigest == receipt.fetch("inputs").fetch(name)
          bytes, failure, observed = Open3.capture3({"GIT_OPTIONAL_LOCKS" => "0"}, "git", "-C", baseline_catalog, "show", "HEAD:#{name}", binmode: true)
          raise "baseline commit differs: #{failure}" unless observed.success? && bytes == File.binread(path)
        end
        FileUtils.cp(File.join(baseline_catalog, File.basename(base)), base, preserve: true)
        @empty_baseline_binding = {"path" => baseline, "head" => expected_head,
          "receipt_sha256" => Digest::SHA256.file(receipt_path).hexdigest, "inputs" => receipt.fetch("inputs")}
        require File.join(pipeline, "lib/af_data_pipeline/ingest_next")
        require File.join(pipeline, "lib/af_data_pipeline/amc_finalize")
        return
      end
      require File.join(pipeline, "lib/af_data_pipeline/ingest_next")
      require File.join(@pipeline_source_root, "test/support/empty_catalog_fixture")
      Object.new.extend(EmptyCatalogFixture).write_empty_catalog(base)
      require File.join(pipeline, "lib/af_data_pipeline/amc_finalize")
      self.class.add_release_fills(base)
    end

    # Installs the exact initial manifest and independent Git objects/index before
    # public start. Only the disposable manifest receives normal write permissions.
    def write_project_state
      return super unless @empty_baseline

      source_catalog = File.join(@empty_baseline, "catalog")
      destination = File.join(catalog, "PROJECT_STATE.yml")
      FileUtils.cp(File.join(source_catalog, "PROJECT_STATE.yml"), destination, preserve: true)
      File.chmod(0o644, destination)
      self.class.copy_git_metadata(source_catalog, catalog)
      # A copied repository's origin is its actual local source. The package
      # owner reads this identity; no fetch/push or original-baseline edit occurs.
      config = File.join(catalog, ".git/config")
      original_config = "[core]\n\trepositoryformatversion = 0\n\tbare = false\n\tfilemode = true\n"
      raise "unexpected copied Git configuration" unless File.binread(config) == original_config
      File.binwrite(config, original_config + "[remote \"origin\"]\n\turl = #{JSON.generate(source_catalog)}\n")
      origin, failure, observed = Open3.capture3({"GIT_OPTIONAL_LOCKS" => "0"}, "git", "-C", catalog, "remote", "get-url", "origin")
      raise "copied baseline origin differs: #{failure}" unless observed.success? && origin.strip == source_catalog
      @empty_baseline_binding["copy_origin"] = source_catalog
      clean, error, status = Open3.capture3({"GIT_OPTIONAL_LOCKS" => "0"}, "git", "-C", catalog, "status", "--porcelain=v1")
      raise "copied empty baseline is not clean: #{error}" unless status.success? && clean.empty?
    end

    # Starts with the exact valid inline empty map; SourceRegister owns mutation.
    def write_registry(_sources = nil)
      write(registry, "schema_version: adventurefinder-source-registry/v0.1\nsources: {}\n")
    end
  end
end
