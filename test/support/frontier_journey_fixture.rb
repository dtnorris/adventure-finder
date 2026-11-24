# frozen_string_literal: true

require_relative "dual_root_journey_fixture"

module Ig07cSourceAcceptance
  # Extends the existing synthetic journey with unchanged public FP commands.
  # All state and copied owner code remain inside this fixture's disposable root.
  class FrontierJourneyFixture < DualRootFixture
    # Copies tracked FP runtime and the scorer's named ontology from selected
    # repositories. Records source identities; missing inputs/Git errors raise.
    def prepare_frontier(sources)
      directory("evidence")
      @frontier = directory("frontier-code")
      @pack = File.join(root, "frontier-pack")
      @afao = File.join(directory("definitions"), "AdventureFinder_Analysis_Ontology_AFAO_v1.6.1.md")
      self.class.copy_runtime(File.join(sources, "af-frontier-pack"), @frontier)
      FileUtils.cp(File.join(sources, "md-specification-files", File.basename(@afao)), @afao, preserve: true)
      @frontier_code = inventory(@frontier)
      @ontology_binding = binding_for(@afao)
      @source_heads = %w[adventure-finder af-data-pipeline af-workloads workload-orchestrator local-ollama-workers
        af-cli-scoring-utility af-frontier-pack af-xlsx-files-data af-cli-query-matcher md-specification-files].to_h do |name|
        source = name == "af-data-pipeline" ? @pipeline_source_root : File.join(sources, name)
        source = @repository_root if name == "adventure-finder"
        source = ENV.fetch("AF_QUERY_MATCHER_ROOT", source) if name == "af-cli-query-matcher"
        identity_source = if name == "adventure-finder" && !File.exist?(File.join(source, ".git"))
          ENV.fetch("AF_ACCEPTANCE_AF_SOURCE_ROOT")
        else
          source
        end
        head, error, status = Open3.capture3({"GIT_OPTIONAL_LOCKS" => "0"}, "git", "-C", identity_source, "rev-parse", "HEAD")
        raise "cannot bind #{name}: #{error}" unless status.success?

        binding = {"path" => File.realpath(source), "head" => head.strip}
        if identity_source != source
          binding["head_source"] = File.realpath(identity_source)
          binding["candidate_files"] = inventory(source)
        end
        [name, binding]
      end
      @fake_inventory = {
        "converter" => "Existing convert-cached fixture: mechanical synthetic PDF/Markdown and receipt; no conversion or fidelity proof.",
        "scorer" => "Existing af-score replacement: prepared source, preflight, proposed CSV and raw request payloads; no inference or method qualification.",
        "local_capacity" => "Existing LOW observer/hardware/client replacements: synthetic worker, installed models and residency; no model pull/load or real capacity proof.",
        "afw_adapter" => "Unchanged real AFW ScorerAdapter, selection, compiler and evidence binder; invokes the replaced scorer executable. Git identity alone does not attest that executable.",
        "standing_authority" => "Existing synthetic owner selection/policy and Fixture Operator decisions; no real human approval.",
        "catalog" => "Existing pinned populated synthetic Git archive; no empty initialization proof."
      }
      File.write(File.join(root, "evidence/frontier-inputs.json"), JSON.pretty_generate(
        source_heads: @source_heads, ontology: @ontology_binding, fakes: @fake_inventory) + "\n")
      nil
    end

    # Freezes activated owner runtime bytes separately from generated workload
    # state. Returns nil; missing/unsafe code entries raise before execution.
    def seal_code
      super
      @owner_code = %w[af-workloads af-cli-scoring-utility workload-orchestrator local-ollama-workers].to_h do |name|
        [name, %w[bin lib config].to_h { |part| [part, inventory(File.join(components, name, part))] }]
      end
      File.write(File.join(root, "evidence/activated-owner-code.json"), JSON.pretty_generate(@owner_code) + "\n")
      nil
    end

    # Adds two same-path controls after the unchanged DPS controls. The last
    # accepted pack is built deliberately, then must survive both refusals.
    # Corrupted intake bytes are restored exactly, even when assertions raise.
    def verify_refusals(extra_env, candidate_path)
      super
      export_frontier
      @previous_export = inventory(@pack)
      @previous_catalog = inventory(catalog)
      previous_pointer = JSON.parse(File.binread(File.join(@pack, "CURRENT")))
      previous_rows = File.readlines(File.join(@pack, "generations", previous_pointer.fetch("generation"), "adventures.jsonl"))
        .map { |line| JSON.parse(line) }
      raise "unapproved candidate already exported" if previous_rows.any? { |row| row.dig("source", "source_id") == SOURCE_ID }
      intake = File.join(data_root, "audits/pre-scoring/fixture-source-llm-edition-source-intake/source_intake.json")
      original = File.binread(intake)
      [["withheld-handoff", nil, "MISSING_BOUND_ARTIFACT"],
       ["changed-bound-handoff", original + "changed", "STALE_INPUT"]].each do |name, changed, diagnostic|
        with_changed_artifact(intake, changed) do
          protected_before = [inventory(data_root), inventory(pipeline), inventory(catalog), inventory(source)]
          stdout, stderr, status = approve_and_export(extra_env, "resume", OPERATION_ID,
            "--approve-final-by", "Fixture Operator", stdin_data: "APPROVE\n")
          raise "#{name} missed its invariant: #{stdout}\n#{stderr}" unless
            status.exited? && !status.success? && (stdout + stderr).include?(diagnostic)
          raise "#{name} changed protected inputs or exported the proposed candidate" unless
            protected_before == [inventory(data_root), inventory(pipeline), inventory(catalog), inventory(source)] &&
            inventory(@pack) == @previous_export && inventory(catalog) == @previous_catalog
          puts "FRONTIER_NEGATIVE_CONTROL=#{name} verified LAST_ACCEPTED_EXPORT=unchanged"
        end
      end
      restored, error, status = run_catalog(extra_env, "resume", OPERATION_ID)
      raise "restoration did not retain original review: #{error}" unless status.success? &&
        restored.include?("Final catalog review awaits explicit human approval") && inventory(@pack) == @previous_export
      nil
    end

    # Runs explicit public approval followed by intentional public build/doctor.
    # Returns the public entry tuple; refused approval never invokes FP. Component
    # failure raises and retains logs; there is no fabricated receipt or pointer.
    def approve_and_export(extra_env, *arguments, **options)
      result = run_catalog(extra_env, *arguments, **options)
      export_frontier if result.last.success?
      result
    end

    # Proves a cold public replay preserves completed jobs, decisions, adopted
    # bytes and pack. Exercises real FP stale-source refusal and exact recovery,
    # then deliberately exports a metadata bundle from the same accepted pack.
    # Returns nil; any broken binding, duplicate work or consumer failure raises.
    def verify_frontier_replay(extra_env)
      retained = [front, data_root, catalog, source, File.join(components, "af-workloads")].to_h do |path|
        [path, inventory(path)]
      end
      pack_before = inventory(@pack)
      stdout, stderr, status = run_catalog(extra_env, "resume", OPERATION_ID,
        "--approve-final-by", "Fixture Operator", stdin_data: "")
      raise "cold replay did not verify adoption: #{stderr}" unless status.success? && stdout.include?("ALREADY_PROMOTED")
      raise "cold replay duplicated work, adoption or decisions" unless
        retained.all? { |path, before| inventory(path) == before } && inventory(@pack) == pack_before

      original = File.binread(canonical)
      with_changed_artifact(canonical, original + "changed") do
        output, error, result = run_frontier("doctor")
        raise "FP failed to refuse stale bound source: #{output}\n#{error}" unless
          result.exited? && !result.success? && error.include?("source hash changed since build")
        raise "stale-source refusal rewrote last accepted export" unless inventory(@pack) == pack_before
      end
      require_frontier("doctor")
      pointer = JSON.parse(File.binread(File.join(@pack, "CURRENT")))
      generation = File.join(@pack, "generations", pointer.fetch("generation"))
      manifest = JSON.parse(File.binread(File.join(generation, "manifest.json")))
      state = YAML.safe_load_file(File.join(catalog, "PROJECT_STATE.yml"))
      raise "FP consumed a different catalog/source/ontology" unless
        manifest.dig("inputs", "amc") == binding_for(File.join(catalog, state.dig("catalog_head", "filename"))).merge(
          "filename" => state.dig("catalog_head", "filename"), "version" => state.dig("catalog_head", "version")) &&
        manifest.dig("inputs", "source_registry", "sha256") == binding_for(registry).fetch("sha256") &&
        manifest.dig("inputs", "afao").slice("path", "sha256", "bytes") == @ontology_binding
      records = File.readlines(File.join(generation, "adventures.jsonl")).map { |line| JSON.parse(line) }
      record = records.find { |row| row.dig("source", "source_id") == SOURCE_ID }
      raise "accepted source missing or rebound" unless record && record.dig("source_locator", "path") == canonical
      raise "deferred assessments were invented" unless record.dig("assessments", "EE").nil? &&
        record.dig("assessment_status", "unassessed").include?("EE")
      require_frontier("source", record.fetch("adventure_id"))
      bundle = File.join(root, "frontier-context.json")
      require_frontier("bundle", "--ids", record.fetch("adventure_id"), "--format", "json", "--output", bundle)
      raise "bundle differs from accepted record" unless JSON.parse(File.binread(bundle)).fetch("adventures") == [{"record" => record}]
      raise "consumer changed owner inputs" unless retained.all? { |path, before| inventory(path) == before }
      raise "frontier code/ontology changed" unless inventory(@frontier) == @frontier_code && binding_for(@afao) == @ontology_binding
      raise "activated owner code changed" unless @owner_code.all? do |name, parts|
        parts.all? { |part, before| inventory(File.join(components, name, part)) == before }
      end
      observations = Dir.glob(File.join(root, "evidence/processes/*.json")).map { |path| JSON.parse(File.binread(path)) }
      consumers = observations.select { |row| row.fetch("executable") == File.join(@frontier, "bin/af-frontier") }
      raise "missing real FP process/library provenance" unless consumers.length >= 7 && consumers.all? do |row|
        row.fetch("consumer_libraries").any? && row.fetch("consumer_libraries").keys.all? { |path| path.start_with?(@frontier + "/lib/") }
      end
      report = {"acceptance_owner" => "David Norris", "synthetic_only" => true,
        "acceptance" => {"A" => "PASS", "B" => "PASS", "C" => "PASS", "D" => "NOT RUN: host checkpoint/gates and operator acceptance"},
        "catalog" => state, "manifest" => manifest, "bundle" => binding_for(bundle),
        "source" => binding_for(canonical), "source_heads" => @source_heads, "external_fakes" => @fake_inventory,
        "execution_bindings" => Dir.glob(File.join(components, "af-workloads/build/workloads", "ingest-#{OPERATION_ID}", "cases/*.yml")).sort.map do |path|
          {"case" => binding_for(path), "frozen_inputs" => YAML.safe_load_file(path)}
        end,
        "five_increments" => five_increments, "public_processes" => observations.select { |row| row.fetch("executable") == command }.map { |row| row.slice("pid", "parent_pid", "argv") }}
      write_frontier_report(report)
      nil
    end

    private

    # Writes this journey's report after all inherited consumer checks pass.
    # Empty-start composition overrides the report's task and acceptance scope.
    def write_frontier_report(report)
      File.write(File.join(root, "evidence/os-int-01-report.json"), JSON.pretty_generate(report) + "\n")
      puts "OS_INT_01_RESULT=#{JSON.generate(report)}"
    end

    # Intentionally builds from catalog_head, with explicit original source and
    # ontology selectors. Missing or invalid owner inputs raise without fallback.
    def export_frontier
      require_frontier("build", "--state", File.join(catalog, "PROJECT_STATE.yml"),
        "--source-registry", registry, "--corpus-root", source, "--afao", @afao)
      require_frontier("doctor")
    end

    # Captures raw IO and status for one fresh FP CLI process in the detached
    # fixture. Returns the Open3 tuple; spawn and filesystem errors propagate.
    def run_frontier(*arguments)
      @frontier_invocations = (@frontier_invocations || 0) + 1
      evidence = directory("evidence/frontier-#{@frontier_invocations}")
      cleared = ENV.keys.grep(/\A(?:BUNDLE_|BUNDLER_)/).to_h { |key| [key, nil] }
      selected = cleared.merge(environment).merge("AF_PROJECT_ROOT" => components,
        "AF_FRONTIER_AMC" => nil, "AF_FRONTIER_OUTPUT" => @pack)
      argv = [File.join(@frontier, "bin/af-frontier"), *arguments]
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stdout = stderr = "".b
      status = nil
      begin
        stdout, stderr, status = Open3.capture3(selected, *argv, chdir: @different_cwd)
      rescue SystemCallError => error
        failure = {"class" => error.class.name, "message" => error.message}
        raise
      ensure
        File.binwrite(File.join(evidence, "stdout.bin"), stdout)
        File.binwrite(File.join(evidence, "stderr.bin"), stderr)
        File.write(File.join(evidence, "invocation.json"), JSON.pretty_generate(command: argv, cwd: @different_cwd,
          environment: selected, exitstatus: status&.exitstatus, signal: status&.termsig, exception: failure,
          seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) + "\n")
      end
      [stdout, stderr, status]
    end

    # Requires a completed successful real FP command. Returns stdout; refusal
    # raises with the retained raw diagnostic rather than advancing the test.
    def require_frontier(*arguments)
      stdout, stderr, status = run_frontier(*arguments)
      raise "frontier #{arguments.first} refused: #{stdout}\n#{stderr}" unless status.success?

      stdout
    end

    # Returns an exact absolute file binding; missing files and IO errors raise.
    def binding_for(path)
      {"path" => File.realpath(path), "sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => File.size(path)}
    end

    # Names the remaining independent owner gates without treating synthetic
    # composition as real source, method, initialization or usefulness evidence.
    def five_increments
      [
        {"increment" => 1, "owners" => %w[AF XL MD PL WL EV], "status" => "NOT RUN",
         "required_evidence" => "Valid empty owner initialization and explicit initial catalog baseline; populated archive proves neither."},
        {"increment" => 2, "owners" => %w[converter MD PL SP David], "status" => "PASS: synthetic handoffs only",
         "remaining" => "NOT RUN: supported real owned PDF, page-addressable conversion and human fidelity/boundary review."},
        {"increment" => 3, "owners" => %w[PL AFW WLO SC LOW David], "status" => "PASS: 11 first-attempt jobs/11 receipts, 6 standing accepted/5 deferred",
         "remaining" => "NOT RUN: real selected local method qualification/execution, exact model/profile/runtime authority and human assessment acceptance."},
        {"increment" => 4, "owners" => %w[PL EV XL FP SP David], "status" => "PASS: exact fixture adoption, real FP build/doctor/locator/metadata bundle",
         "remaining" => "NOT RUN: real human acceptance, source-bearing useful frontier review, public availability and rights clearance."},
        {"increment" => 5, "owners" => %w[AF INT MIG David], "status" => "PASS: fresh-process fixture replay and stale-input recovery",
         "remaining" => "NOT RUN: second-source preservation/recovery and existing-install migration; no regenerated decision or duplicate completed work permitted."}
      ]
    end
  end
end
