# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require_relative "adventure_finder_workspace"

module AdventureFinderWorkspace
  # Connects terminal local execution to owner-validated AFW evidence and the
  # pipeline's standing release. This class neither creates scoring receipts
  # nor decides a numeric value or a catalog transition.
  class IngestReleaseContinuation
    class Failure < Error
      attr_reader :code

      def initialize(code, message)
        @code = code
        super("#{code}: #{message}")
      end
    end

    def initialize(front_door_root:, project_root:, pipeline_root:, catalog_root:, env: ENV,
                   out: $stdout, runner: nil)
      @front = Pathname(front_door_root).expand_path
      @project = Pathname(project_root).expand_path
      @pipeline = Pathname(pipeline_root).expand_path
      @catalog = Pathname(catalog_root).expand_path
      @afw = Pathname(env.fetch("AF_AFW_ROOT", @project.join("af-workloads").to_s)).expand_path
      @scorer = Pathname(env.fetch("AF_SCORER_ROOT", @project.join("af-cli-scoring-utility").to_s)).expand_path
      @wlo = Pathname(env.fetch("WLO_REPO_ROOT", @project.join("workload-orchestrator").to_s)).expand_path
      @out = out
      @runner = runner || ->(environment, *argv, chdir:) { Open3.capture3(environment, *argv, chdir:) }
    end

    def prepare(operation_id:)
      preparation_dir = @front.join("output", "staged-workload-preparations", "v0.1", operation_id)
      preparation = read_json(preparation_dir.join("result.json"))
      fail_with("RELEASE_NOT_READY", "qualified workload preparation is unavailable") unless
        preparation["operation_id"] == operation_id && preparation["status"] == "PREPARED" &&
        preparation["qualified_cases"].is_a?(Integer) && preparation["qualified_cases"].positive?
      workload_id = preparation.fetch("workload_id")
      workload = @afw.join("workloads", workload_id)
      plan = workload.join("execution-plan.json")
      fail_with("STALE_WORKLOAD_BINDING", "frozen execution plan changed") unless
        plan.to_s == preparation.dig("plan", "path") &&
        Digest::SHA256.file(plan).hexdigest == preparation.dig("plan", "sha256")
      output = @front.join("output", "local-ingest-executions", "v0.1", operation_id, "wlo")
      status = invoke(@wlo, "wlo", "status", plan, "--output", output, "--json")
      report = parse_json(status)
      fail_with("RELEASE_NOT_READY", "WLO has not completed this exact frozen plan") unless
        report["plan_id"] == workload_id && report["plan_sha256"] == preparation.dig("plan", "sha256") &&
        report["status"] == "completed" && report["executor_active"] == false

      binding = parse_json(invoke(@afw, "afw-bind-scoring-evidence", workload_id, output))
      fail_with("INCOMPLETE_AFW_EVIDENCE", "AFW has not bound the complete workload denominator") unless
        binding["fully_evidenced"] == true
      publication = parse_json(invoke(@afw, "afw-workload-evidence", "publish", workload_id, output))
      manifest = @afw.join(publication.fetch("manifest_path")).cleanpath
      fail_with("INVALID_AFW_MANIFEST", "AFW returned an unexpected evidence manifest") unless
        manifest.dirname == @afw.join("output", "workloads", workload_id, "evidence", "manifests") &&
        publication["evidence_complete"] == true &&
        publication["intended_cases"] == preparation.fetch("qualified_cases") &&
        publication["receipt_count"] == preparation.fetch("qualified_cases")
      validated = parse_json(invoke(@afw, "afw-workload-evidence", "validate", manifest))
      fail_with("INVALID_AFW_MANIFEST", "AFW validation changed the evidence identity or denominator") unless
        validated["manifest_id"] == publication["manifest_id"] &&
        validated["evidence_complete"] == true &&
        validated["intended_cases"] == preparation.fetch("qualified_cases") &&
        validated["receipt_count"] == preparation.fetch("qualified_cases")

      root = @front.join("output", "ingest-releases", "v0.1", operation_id)
      private_directory!(root)
      review = root.join("review")
      audit = root.join("audit")
      [review, audit, root.join("release"), root.join("package.json")].each do |path|
        fail_with("UNSAFE_RELEASE_PATH", "release output is symlinked: #{path}") if path.symlink?
      end
      invoke(@pipeline, "af-data", "prepare-workload-review", manifest,
             "--afw-root", @afw, "--review-dir", review, "--audit-dir", audit)
      release_inputs = root.join("release-inputs.json")
      authority_inputs = read_json(preparation_dir.join("authority-inputs.json"))
      staged = {
        "evidence" => authority_inputs.fetch("evidence"),
        "store_root" => @pipeline.join("output", "staged-scoring-authority", "v0.1").to_s,
        "current_project_state_path" => @catalog.join("PROJECT_STATE.yml").to_s,
        "workload_binding_path" => @afw.join("workloads", ".selections", workload_id, "frozen-workload.json").to_s,
        "selection_path" => @afw.join("workloads", ".selections", workload_id, "selection.json").to_s,
        "selection_afw_root" => @afw.to_s,
        "selection_project_root" => @afw.to_s,
        "selection_scorer_root" => @scorer.to_s,
        "workload_paths" => {
          "plan" => plan.to_s,
          "snapshot" => workload.join("snapshot.yml").to_s,
          "index" => workload.join("case_index.csv").to_s,
          "generated" => @afw.join("build", "workloads", workload_id).to_s
        }
      }
      input = {
        "schema_version" => "af-standing-bulk-score-release-inputs/v0.2", "mode" => "production",
        "staged_scoring" => staged,
        "workload_review" => {"manifest_path" => manifest.to_s, "afw_root" => @afw.to_s,
                              "review_dir" => review.to_s, "audit_dir" => audit.to_s},
        "standing_policy_path" => @pipeline.join("config", "standing_bulk_score_ingestion_policy_v0.1.json").to_s,
        "owner_selection_path" => @pipeline.join("config", "standing_bulk_score_owner_selection_v0.1.json").to_s,
        "machine_acceptance" => nil
      }
      write_or_verify!(release_inputs, input)
      release = root.join("release")
      invoke(@pipeline, "af-standing-bulk-score-release", "--inputs", release_inputs, "--output", release)
      manifest_path = release.join("release-accounting.json")
      manifest_document = read_json(manifest_path)
      counts = manifest_document.fetch("counts")
      fail_with("INVALID_RELEASE_ACCOUNTING", "release used individual or machine acceptance") unless
        counts["individual_human_accepted"] == 0 && counts["ig16b_machine_accepted"] == 0
      package_inputs = root.join("package-inputs.json")
      write_or_verify!(package_inputs, {
        "schema_version" => "af-final-release-package-inputs/v0.1",
        "release_inputs_path" => release_inputs.to_s,
        "release_manifest_path" => manifest_path.to_s,
        "catalog_repository_root" => @catalog.to_s,
        "current_project_state_path" => @catalog.join("PROJECT_STATE.yml").to_s,
        "frontier_result_path" => nil
      })
      package = root.join("package.json")
      result = parse_json(invoke(@pipeline, "af-final-release-package", "prepare",
                                 "--inputs", package_inputs, "--output", package))
      fail_with("FINAL_RELEASE_BLOCKED", "owner package does not authorize final review") unless
        result.dig("readiness", "ready") == true &&
        result.dig("operation", "operation_id") == operation_id
      @out.puts "Final release ready for explicit approval: #{result.fetch('package_id')}"
      {inputs_path: package_inputs.to_s, package_path: package.to_s}
    rescue KeyError, JSON::ParserError, Errno::ENOENT, TypeError => e
      fail_with("INVALID_RELEASE_INPUT", e.message)
    end

    private

    def invoke(root, command, *arguments)
      executable = root.join("bin", command)
      fail_with("COMPONENT_UNAVAILABLE", "missing owner command #{executable}") unless executable.file? && executable.executable?
      stdout, stderr, status = @runner.call(
        {"AF_PROJECT_ROOT" => @project.to_s, "AF_ADVENTURE_FINDER_ROOT" => @front.to_s,
         "AFW_ROOT" => @afw.to_s}, executable.to_s, *arguments.map(&:to_s), chdir: root.to_s
      )
      unless status.success?
        if command == "afw-bind-scoring-evidence"
          observation = JSON.parse(stdout) rescue nil
          if observation.is_a?(Hash) && observation["fully_evidenced"] == false
            fail_with("INCOMPLETE_AFW_EVIDENCE", "AFW refused the full denominator: #{observation['reason_counts'].inspect}")
          end
        end
        fail_with("OWNER_HANDOFF_REFUSED", "#{command}: #{stderr.strip.empty? ? stdout.strip.lines.first.to_s.strip : stderr.strip}")
      end
      stdout
    end

    def read_json(path)
      JSON.parse(File.binread(path))
    end

    def parse_json(value)
      JSON.parse(value)
    end

    def private_directory!(path)
      current = @front
      path.relative_path_from(@front).each_filename do |part|
        current = current.join(part)
        fail_with("UNSAFE_RELEASE_PATH", "release path is symlinked: #{current}") if current.symlink?
      end
      FileUtils.mkdir_p(path)
    end

    def write_or_verify!(path, document)
      fail_with("UNSAFE_RELEASE_PATH", "release input is symlinked: #{path}") if path.symlink?
      bytes = JSON.pretty_generate(document) + "\n"
      if path.exist?
        fail_with("RELEASE_INPUT_CONFLICT", "release input changed: #{path}") unless
          path.file? && File.binread(path) == bytes
      else
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(bytes)
          file.flush
          file.fsync
        end
      end
    end

    def fail_with(code, message)
      raise Failure.new(code, message)
    end
  end
end
