# frozen_string_literal: true

require_relative "empty_start_journey_fixture"

module Ig07cSourceAcceptance
  # Reuses the activated native facade at its reviewed inventory and writer
  # delta. Both recovery and the first-input control use these same code bytes.
  module ReviewedPipelineRuntime
    private

    # Copies the exact selected facade, pinned EV runtime and AF candidate.
    # Missing selectors, links, byte/mode drift or a changed inventory raise.
    def build_pipeline_facade
      first = File.realpath(ENV.fetch("AF_ACCEPTANCE_FIRST_ROOT"))
      native = File.realpath(ENV.fetch("AF_ACCEPTANCE_NATIVE_ROOT"))
      FileUtils.rmdir(@pipeline)
      @pipeline = directory("code/af-pipeline")
      @data_root = directory("af-pipeline-data")
      inventory_path = File.join(native, "current-runtime-inventory.json")
      raise "reviewed runtime inventory changed" unless Digest::SHA256.file(inventory_path).hexdigest == SecondInputFixture::RUNTIME_INVENTORY_SHA256
      expected = JSON.parse(File.binread(File.join(first, "root-map.json"))).fetch("code_inventory")
      writer = "lib/af_data_pipeline/production_evidence_shadow_writer.rb"
      expected.fetch(writer)["sha256"] = "6a6b9eea394cf35480f2d1935f3ce8e167d2190d7809008769ed1705b15717ad"
      facade = File.join(native, "code/af-pipeline")
      raise "reviewed activated facade changed" unless inventory(facade) == expected
      FileUtils.cp_r(File.join(facade, "."), pipeline, preserve: true)
      copy_evidence_runtime(File.join(root, "code/af-evidence"))
      self.class.copy_runtime(@repository_root, front, names: %w[bin lib], include_candidate: true)
    end
  end

  # Keeps the INT-02 public journey intact with an explicitly selected reviewed
  # facade. Without the new selector its original fixture class is unchanged.
  class ReviewedEmptyStartFixture < EmptyStartFixture
    include ReviewedPipelineRuntime
  end

  # Extends the unchanged synthetic public journey from an exact accepted first
  # catalog. Historical receipts keep their original absolute bindings; only the
  # new operation uses the independent copy. No Git history is created here.
  class SecondInputFixture < EmptyStartFixture
    include ReviewedPipelineRuntime
    SECOND_OPERATION = "99999999-9999-4999-8999-999999999999"
    SECOND_SOURCE = "Fixture Second Source"
    SUCCESSOR = "ee0b382aee2d34e3b62b6f8e311e566dc00c0131"
    FIRST_WORKBOOK = "5e_Adventure_Master_Catalog_0.0.2.xlsx"
    FIRST_SHA256 = "c26b7c1ab04a59dac2db77b691a9a6c5a39c6d6e2c234ed95c6a1176bb54d68c"
    RUNTIME_INVENTORY_SHA256 = "92ee664b7138d490639c5fa10259b05169cba38b44d86af3761df89ac0987b6d"

    # Builds fresh external seams while copying only exact synthetic accepted
    # inputs and first durable evidence. Missing or changed bindings raise.
    def initialize(**options)
      @first = File.realpath(ENV.fetch("AF_ACCEPTANCE_FIRST_ROOT"))
      super
      @canonical = File.join(source, "Fixture_Second_Source_LLM_Edition.md")
      raise "second source already exists" if File.exist?(canonical)

      File.binwrite(pdf, "%PDF second synthetic structural fixture OS-INT-03\n")
      FileUtils.cp_r(File.join(@first, "af-pipeline-data", "."), data_root, preserve: true)
      first_id = Fixture::OPERATION_ID
      %W[output/ingest-operations/v0.1/#{first_id}
        output/ingest-authorities/successor-version/v0.1/#{first_id}].each do |relative|
        target = File.join(front, relative)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp_r(File.join(@first, "front-door", relative), target, preserve: true)
      end
      context = "output/ingest-contexts/v0.1/#{first_id}.json"
      FileUtils.mkdir_p(File.dirname(File.join(front, context)))
      FileUtils.cp(File.join(@first, "front-door", context), File.join(front, context), preserve: true)
      @first_catalog = inventory(catalog)
      @first_source = inventory(source)
      @first_data = inventory(data_root)
      @first_front = inventory(front)
    end

    # Uses real FP to read the retained first tuple before any second work.
    # Source paths in this old pack resolve at their unchanged historical roots.
    def prepare_frontier(sources)
      super
      current = @pack
      @pack = File.join(@first, "frontier-pack")
      @first_pack = inventory(@pack)
      @first_rows = pack_records
      require_frontier("doctor")
      @first_rows.each { |record| require_frontier("source", record.fetch("adventure_id")) }
      @pack = current
      @fake_inventory["catalog"] = "Exact first accepted bytes and approved two-file successor history; independent copy."
      @fake_inventory["converter"] += " Distinct ready operation; frozen source-review control is never edited."
    end

    # Derives all result counts from frozen cases and the explicit synthetic
    # standing scope. A missing intent or another operation/source raises.
    def expected_accounting(operation_id)
      cases = Dir.glob(File.join(components, "af-workloads/build/workloads", "ingest-#{operation_id}", "cases/*.yml"))
        .map { |path| YAML.safe_load_file(path) }
      raise "missing distinct second intent" unless operation_id == SECOND_OPERATION && !cases.empty? &&
        cases.all? { |row| row.dig("staged_scoring", "operation_id") == operation_id && row.fetch("adventure_id") != "ADV-0001" }
      scope = JSON.parse(File.binread(File.join(pipeline, "config/standing_bulk_score_ingestion_policy_v0.1.json"))).fetch("scope")
      accepted = cases.count do |row|
        scope.fetch("dimensions").include?(row.fetch("dimension")) && scope.fetch("profiles").include?(row.fetch("profile")) &&
          scope.fetch("model_aliases").include?(row.fetch("model_alias")) && scope.fetch("models").include?(row.fetch("ollama_model"))
      end
      [cases.length, cases.length, accepted, cases.length - accepted, 0, 0]
    end

    # Tests absent second approval, a changed second source, exact restoration
    # and a cold final-review pause. Retains the empty approval request and all
    # failure evidence; no decision or completed work is regenerated.
    def verify_refusals(extra_env, candidate_path)
      raise "first result changed before review" unless @first_catalog.all? { |key, value| inventory(catalog)[key] == value }
      first_evidence_unchanged!
      before = [inventory(catalog), inventory(source), @first_pack]
      output, error, status = run_catalog(extra_env, "resume", SECOND_OPERATION,
        "--approve-final-by", "Fixture Operator", stdin_data: "")
      raise "missing second approval advanced: #{output}\n#{error}" unless
        !status.success? && output.include?("No approval recorded.") &&
        before == [inventory(catalog), inventory(source), inventory(File.join(@first, "frontier-pack"))]
      puts "SECOND_APPROVAL_CONTROL=missing verified FIRST_RESULT=unchanged"
      original = File.binread(canonical)
      with_changed_artifact(canonical, original + "changed") do
        protected = [inventory(catalog), inventory(data_root), inventory(source)]
        output, error, status = run_catalog(extra_env, "resume", SECOND_OPERATION,
          "--approve-final-by", "Fixture Operator", stdin_data: "APPROVE\n")
        prefix = "af-catalog: FINAL_PROMOTION_REFUSED: pipeline final-release validation failed: "
        line = error.lines.find { |entry| entry.start_with?(prefix) }
        refusal = JSON.parse(line.delete_prefix(prefix)) if line
        reason = "package reference changed: authority:source:#{File.basename(canonical)}"
        raise "changed second binding was not refused: #{output}\n#{error}" unless
          !status.success? && refusal&.values_at("schema_version", "status", "reason") ==
            ["af-final-release-package/v0.1", "BLOCKED", reason]
        raise "changed second binding modified protected state" unless
          protected == [inventory(catalog), inventory(data_root), inventory(source)]
      end
      retained = [front, data_root, catalog, source, File.join(components, "af-workloads")].to_h { |path| [path, inventory(path)] }
      output, error, status = run_catalog(extra_env, "resume", SECOND_OPERATION)
      raise "second pause did not recover: #{output}\n#{error}" unless
        status.success? && output.include?("Final catalog review awaits explicit human approval") &&
        retained.all? { |path, value| inventory(path) == value }
      raise "reviewed candidate disappeared" unless File.file?(candidate_path)
      first_evidence_unchanged!
      puts "SECOND_FINAL_REVIEW_PAUSE=durable FRESH_PROCESS_RECOVERY=exact CHANGED_BINDING=refused"
    end

    # Verifies both source records, every first value, current tuple and retained
    # first pack through real FP commands. Accepted replay must be byte-idempotent.
    def verify_frontier_replay(extra_env)
      retained = [front, data_root, catalog, source, File.join(components, "af-workloads"), @pack].to_h { |path| [path, inventory(path)] }
      output, error, status = run_catalog(extra_env, "resume", SECOND_OPERATION,
        "--approve-final-by", "Fixture Operator", stdin_data: "")
      raise "accepted second replay changed work: #{output}\n#{error}" unless
        status.success? && output.include?("ALREADY_PROMOTED") && retained.all? { |path, value| inventory(path) == value }
      rows = pack_records
      raise "two-source pack is incomplete" unless rows.length == @first_rows.length + 1 &&
        rows.map { |record| record.dig("source", "source_id") }.sort == [Fixture::SOURCE_ID, SECOND_SOURCE].sort
      @first_rows.each do |original|
        record = rows.find { |row| row.fetch("adventure_id") == original.fetch("adventure_id") }
        expected = Marshal.load(Marshal.dump(original))
        old_path = expected.fetch("source_locator").fetch("path")
        expected.fetch("source_locator")["path"] = File.join(source, File.basename(old_path))
        raise "first source relocation changed bytes" unless File.binread(old_path) == File.binread(expected.dig("source_locator", "path"))
        raise "first accepted record or values changed" unless record == expected
      end
      rows.each { |record| require_frontier("source", record.fetch("adventure_id")) }
      state = YAML.safe_load_file(File.join(catalog, "PROJECT_STATE.yml"))
      pointer = JSON.parse(File.binread(File.join(@pack, "CURRENT")))
      manifest = JSON.parse(File.binread(File.join(@pack, "generations", pointer.fetch("generation"), "manifest.json")))
      raise "second pack selected a different tuple" unless
        manifest.dig("inputs", "amc") == binding_for(File.join(catalog, state.dig("catalog_head", "filename"))).merge(
          "filename" => state.dig("catalog_head", "filename"), "version" => state.dig("catalog_head", "version")) &&
        manifest.dig("inputs", "source_registry", "sha256") == binding_for(registry).fetch("sha256") &&
        manifest.dig("inputs", "afao").slice("path", "sha256", "bytes") == @ontology_binding
      first_evidence_unchanged!
      current = @pack
      @pack = File.join(@first, "frontier-pack")
      require_frontier("doctor")
      @first_rows.each { |record| require_frontier("source", record.fetch("adventure_id")) }
      raise "first pack changed" unless inventory(@pack) == @first_pack
      @pack = current
      increments = five_increments
      increments.last["status"] = "PASS: synthetic second-source preservation, durable review pause, cold recovery and idempotent accepted replay"
      increments.last["remaining"] = "NOT RUN: actual-install migration and human acceptance"
      report = {"task" => "OS-INT-03", "synthetic_only" => true, "operation" => SECOND_OPERATION,
        "source_review_control" => "a670f6dc-efdc-4d3d-8514-c9456d6c4db0 (retained, unchanged)",
        "acceptance" => {"A" => "PASS", "B" => "PASS", "C" => "PASS", "D" => "PASS", "E" => "NOT RUN: host gates, CI and human acceptance"},
        "catalog" => state, "manifest" => manifest, "records" => rows, "external_fakes" => @fake_inventory,
        "five_increments" => increments}
      File.binwrite(File.join(root, "evidence/os-int-03-report.json"), JSON.pretty_generate(report) + "\n")
      puts "OS_INT_03_RESULT=#{JSON.generate(report)}"
    end

    private

    # Checks first historical receipts and evidence as a subset of legitimately
    # growing stores; copied history is never rebound or replayed under new roots.
    def first_evidence_unchanged!
      current = inventory(data_root)
      raise "first retained evidence changed" unless @first_data.all? { |key, value| current[key] == value }
      current = inventory(source)
      raise "first source changed" unless @first_source.except("source_registry.yml").all? { |key, value| current[key] == value }
      current = inventory(front)
      raise "first operation, context or authority changed" unless @first_front.all? { |key, value| current[key] == value }
    end

    # Reads JSONL using the same current generation selected by the real reader.
    def pack_records
      pointer = JSON.parse(File.binread(File.join(@pack, "CURRENT")))
      File.readlines(File.join(@pack, "generations", pointer.fetch("generation"), "adventures.jsonl")).map { |line| JSON.parse(line) }
    end

    # Selects a distinct source/operation without changing the frozen control.
    def start_arguments
      super.map { |value| {Fixture::OPERATION_ID => SECOND_OPERATION, Fixture::SOURCE_ID => SECOND_SOURCE}.fetch(value, value) }
    end

    # Copies the approved successor and exact workbook; preserves the original
    # origin, objects and index independently without init, staging or commits.
    def build_catalog
      original = File.join(@first, "catalog")
      head, error, status = Open3.capture3({"GIT_OPTIONAL_LOCKS" => "0"}, "git", "-C", original, "rev-parse", "HEAD")
      raise "first catalog successor changed: #{error}" unless status.success? && head.strip == SUCCESSOR
      raise "first accepted workbook changed" unless Digest::SHA256.file(File.join(original, FIRST_WORKBOOK)).hexdigest == FIRST_SHA256
      inventory(original)
      FileUtils.cp_r(File.join(original, "."), catalog, preserve: true)
      @base = File.join(catalog, FIRST_WORKBOOK)
      require File.join(pipeline, "lib/af_data_pipeline/ingest_next")
      require File.join(pipeline, "lib/af_data_pipeline/amc_finalize")
    end

    # Catalog state was already copied byte-for-byte by build_catalog.
    def write_project_state
      nil
    end

    # Retains the exact first registry and source, with relative owner locators.
    def write_registry(_sources = nil)
      FileUtils.cp_r(File.join(@first, "components/md-for-llm-book-content", "."), source, preserve: true)
    end
  end
end
