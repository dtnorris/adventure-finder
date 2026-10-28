# frozen_string_literal: true

require_relative "dual_root_journey_fixture"

module Ig07cSourceAcceptance
  # Extends the split journey with an independent legacy checkout and saved
  # selectors. All operations are sequential and use synthetic inputs only.
  class CoexistenceFixture < DualRootFixture
    # Records byte/mode inventories around each public invocation, including
    # intentionally corrupt negative inputs. Returns Open3's tuple; IO errors
    # propagate. Link identities are observed without following their targets.
    def run_catalog(extra_env = {}, *arguments, **options)
      before = world_inventory
      previous = process_paths
      result = super
      after = world_inventory
      evidence = File.join(root, "evidence/public-#{@invocation_count}")
      File.binwrite(File.join(evidence, "inventories.json"), JSON.pretty_generate(
        before: before, after: after
      ) + "\n")
      selected = environment.merge(extra_env)["AF_DATA_PIPELINE_ROOT"] || @legacy
      verify_processes(previous, selected, cached: true)
      raise "unselected legacy checkout changed" if selected != @legacy && before[@legacy] != after[@legacy]
      raise "split code changed" unless before[pipeline] == after[pipeline]
      raise "unselected private data changed" if selected != pipeline && before[data_root] != after[data_root]
      result
    end

    # Seals both checkouts and records their accepted source identity. Returns
    # nil; unsafe entries or failed Git reads stop the rehearsal.
    def seal_code
      @legacy = directory("components/af-data-pipeline")
      self.class.copy_runtime(@pipeline_source_root, @legacy)
      [pipeline, @legacy].each { |path| self.class.copy_git_metadata(@pipeline_source_root, path) }
      @code_inventory = inventory(pipeline)
      @legacy_runtime = %w[bin lib config schemas Gemfile Gemfile.lock .git].to_h do |name|
        path = File.join(@legacy, name)
        [name, File.directory?(path) ? inventory(path) : Digest::SHA256.file(path).hexdigest]
      end
      @legacy_converter = directory("legacy-converter")
      FileUtils.cp_r(File.join(converter, "bin"), @legacy_converter)
      @legacy_source = directory("legacy-source")
      FileUtils.cp(File.join(source, "Existing.md"), @legacy_source)
      FileUtils.cp(registry, @legacy_source)
      @legacy_selectors = {"AF_DATA_PIPELINE_ROOT" => nil, "AF_DATA_PIPELINE_DATA_ROOT" => nil,
        "AF_PDF_CONVERTER_ROOT" => @legacy_converter, "AF_SOURCE_ROOT" => @legacy_source}
      File.binwrite(File.join(root, "root-map.json"), JSON.pretty_generate(
        front_executable: command, front_state: front, components: components,
        pipeline_code: pipeline, pipeline_data: data_root, legacy_code: @legacy,
        corpus: source, catalog: catalog, temporary: environment.fetch("TMPDIR"),
        split_configuration: environment, legacy_configuration: environment.merge(@legacy_selectors),
        code_inventory: @code_inventory, legacy_runtime: @legacy_runtime
      ) + "\n")
      nil
    end

    # Starts a fresh legacy operation with selectors absent. Inputs are the
    # shared owner environment and a distinct UUID; returns nil or raises on
    # failure, unintended split writes or foreign process/library execution.
    def legacy_probe(extra_env, operation_id)
      before = inventory(pipeline)
      private_before = inventory(data_root)
      arguments = start_arguments
      arguments[arguments.index("--operation-id") + 1] = operation_id
      arguments[arguments.index("--source-id") + 1] = "Fixture Source #{operation_id}"
      arguments[arguments.index("--canonical-destination") + 1] = File.join(@legacy_source, "#{operation_id}.md")
      previous = process_paths
      output, error, status = run_catalog(extra_env.merge(@legacy_selectors).merge(
        "IG07C_MARKDOWN_MODE" => "synthetic_procedure"), *arguments)
      raise "fresh legacy operation failed: #{output}\n#{error}" unless status.success?
      raise "legacy selection changed split state/code" unless before == inventory(pipeline) && private_before == inventory(data_root)

      verify_processes(previous, @legacy)
      raise "legacy audit destination missing" unless File.directory?(File.join(@legacy, "audits/pre-scoring"))
      puts "LEGACY_OPERATION=#{operation_id} verified"
      nil
    end

    # Restores legacy selection after a split pause, preserves exact bound
    # state, then cold-resumes with the original split configuration. Raises
    # on changed bindings, foreign execution or failure to recover.
    def verify_switch(extra_env)
      protected_paths = [data_root, source, converter,
        File.join(front, "output/ingest-operations/v0.1", OPERATION_ID),
        File.join(front, "output/ingest-contexts/v0.1", "#{OPERATION_ID}.json")]
      before = protected_paths.to_h do |path|
        [path, File.directory?(path) ? inventory(path) : File.binread(path)]
      end
      legacy_probe(extra_env, "99999999-9999-4999-8999-999999999999")
      raise "legacy rollback changed split bindings" unless before.all? do |path, bytes|
        bytes == (File.directory?(path) ? inventory(path) : File.binread(path))
      end
      previous = process_paths
      output, error, status = run_catalog(extra_env, "resume", OPERATION_ID)
      raise "cold split recovery failed: #{output}\n#{error}" unless status.success? &&
        output.include?("Gate: BOUNDARY_EDITORIAL_REVIEW")
      verify_processes(previous, pipeline, cached: true)
      raise "cold resume rewrote retained bindings" unless before.all? do |path, bytes|
        bytes == (File.directory?(path) ? inventory(path) : File.binread(path))
      end
      puts "COEXISTENCE_SWITCH=verified"
      nil
    end

    # Exercises explicit invalid selectors with discoverable legacy code still
    # present, then restores split selection after each refusal. Returns nil;
    # wrong diagnostics, fallback execution or owner mutation raise.
    def verify_refusals(extra_env, candidate_path)
      super
      alternate = directory("alternate-data")
      controls = [
        ["blank-code", {"AF_DATA_PIPELINE_ROOT" => ""}, /pipeline root must/],
        ["other-code", {"AF_DATA_PIPELINE_ROOT" => @legacy}, /code selector conflicts with retained context/],
        ["blank-data", {"AF_DATA_PIPELINE_DATA_ROOT" => ""}, /pipeline root must/],
        ["other-data", {"AF_DATA_PIPELINE_DATA_ROOT" => alternate}, /PIPELINE_DATA_ROOT_MISMATCH/],
        ["unset-data", {"AF_DATA_PIPELINE_DATA_ROOT" => nil}, /PIPELINE_DATA_ROOT_MISMATCH/]
      ]
      controls.each do |name, selectors, diagnostic|
        before = world_inventory
        previous = process_paths
        output, error, status = run_catalog(extra_env.merge(selectors), "resume", OPERATION_ID,
          "--approve-final-by", "Fixture Operator", stdin_data: "APPROVE\n")
        raise "#{name} did not refuse for its invariant: #{output}\n#{error}" unless
          !status.success? && diagnostic.match?(output + error)
        raise "#{name} changed owner state" unless before == world_inventory && Dir.empty?(alternate)
        verify_processes(previous, pipeline, cached: true)
        restored, restored_error, restored_status = run_catalog(extra_env, "resume", OPERATION_ID)
        raise "#{name} recovery failed: #{restored_error}" unless restored_status.success? &&
          restored.include?("Final catalog review awaits explicit human approval")
        puts "NEGATIVE_CONTROL=#{name} verified; original split configuration recovered"
      end
      nil
    end

    # Rehearses legacy selection against split-bound work before approval and
    # after adoption. The caller restores split selectors for cold replay.
    # Inputs are owner environment and adoption flag; raises on fallback,
    # changed bound evidence or catalog rollback, returning nil.
    def rollback_selection(extra_env, adopted: false)
      protected_paths = [pipeline, data_root, catalog, source, converter,
        File.join(front, "output/ingest-operations/v0.1", OPERATION_ID)]
      before = protected_paths.to_h { |path| [path, inventory(path)] }
      output, error, status = run_catalog(extra_env.merge(@legacy_selectors), "resume", OPERATION_ID)
      raise "split operation continued under legacy configuration: #{output}\n#{error}" unless
        !status.success? && (output + error).include?("PIPELINE_DATA_ROOT_MISMATCH")
      raise "rollback changed split evidence or catalog authority" unless
        before.all? { |path, bytes| bytes == inventory(path) }
      puts "ROLLBACK_SELECTION=#{adopted ? 'after-adoption' : 'before-approval'} verified; restore original split configuration to resume"
      nil
    end

    # Checks both retained code copies and all observed owner selections after
    # the complete journey. Missing commands or changed runtime bytes raise.
    def verify_code
      raise "split code changed" unless inventory(pipeline) == @code_inventory
      @legacy_runtime.each do |name, expected|
        path = File.join(@legacy, name)
        raise "legacy runtime changed: #{name}" unless expected ==
          (File.directory?(path) ? inventory(path) : Digest::SHA256.file(path).hexdigest)
      end
      rows = process_paths.map { |path| JSON.parse(File.binread(path)) }
      required = %w[af-source-progress af-source-intake af-source-register af-boundary-editorial
        af-data af-staged-scoring-authority af-standing-bulk-score-release af-final-release-package
        af-final-release-adoption af-project-state]
      observed = rows.select { |row| row.fetch("executable").start_with?(pipeline + "/bin/") }
      raise "missing real split owner commands" unless (required - observed.map { |row| File.basename(row.fetch("executable")) }).empty?
      raise "foreign library loaded" if rows.any? do |row|
        row.fetch("libraries").keys.any? { |path| !path.start_with?(row.fetch("code_root") + "/lib/") }
      end
      nil
    end

    private

    # Binds the home directory as well as inherited scratch/cache selectors to
    # this fixture. Returns child environment entries; directory errors raise.
    def environment
      super.merge("HOME" => directory("home"))
    end

    # Returns sorted per-process provenance paths; takes no arguments.
    def process_paths
      Dir.glob(File.join(root, "evidence/processes/*.json")).sort
    end

    # Checks new process observations against the selected owner checkout.
    # Inputs are prior paths and code root; missing/foreign execution raises.
    def verify_processes(previous, selected, cached: false)
      rows = (process_paths - previous).map { |path| JSON.parse(File.binread(path)) }
      owner_rows = rows.select { |row| row.fetch("executable").start_with?(selected + "/bin/") }
      raise "no public entry observation" unless rows.any? { |row| row.fetch("executable") == command }
      unless cached
        raise "no real selected pipeline execution" if owner_rows.empty?
        raise "no selected pipeline library loaded" unless owner_rows.any? { |row| row.fetch("libraries").any? }
      end
      raise "unselected pipeline executed" if rows.any? do |row|
        [pipeline, @legacy].any? { |code| code != selected && row.fetch("executable").start_with?(code + "/bin/") } ||
          row.fetch("libraries").keys.any? { |path| !path.start_with?(selected + "/lib/") }
      end
      nil
    end

    # Returns complete owner inventories for before/after evidence. Takes no
    # inputs; filesystem errors propagate. Scratch and observer output are
    # separate from the code, state, corpus and catalog owners being measured.
    def world_inventory
      owners = [pipeline, @legacy, data_root, front, source, converter, catalog,
        @legacy_source, @legacy_converter, File.join(root, "low-state"),
        *%w[af-workloads af-cli-scoring-utility workload-orchestrator local-ollama-workers].map do |name|
          File.join(components, name)
        end]
      owners.compact.uniq.to_h do |owner|
        entries = Dir.glob(File.join(owner, "**", "*"), File::FNM_DOTMATCH).sort
          .reject { |path| File.basename(path) == "." }.to_h do |path|
          stat = File.lstat(path)
          [path.delete_prefix(owner + "/"), {mode: stat.mode & 0o777,
            sha256: stat.file? ? Digest::SHA256.file(path).hexdigest : nil,
            link: stat.symlink? ? File.readlink(path) : nil}]
        end
        [owner, entries]
      end.merge("component_entries" => Dir.children(components).sort)
    end
  end
end
