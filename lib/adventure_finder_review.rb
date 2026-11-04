# frozen_string_literal: true

require "json"
require "open3"
require "pathname"
require_relative "adventure_finder_workspace"
require_relative "adventure_finder_production_context"
require_relative "adventure_finder_job_handle_resolver"
require_relative "adventure_finder_state_paths"

module AdventureFinderWorkspace
  # Composes the public AFW evidence-binding and pipeline review-preparation
  # commands for one exact frozen AdventureFinder batch/job context.
  class ReviewFrontDoor
    PLAN_CONTRACT_VERSION = "wlo-execution-plan/v0.3"
    PIPELINE_REPOSITORY = "af-data-pipeline"
    SAFE_PATH_SEGMENT = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

    class ComponentRunner
      Result = Struct.new(:stdout, :stderr, :status, keyword_init: true)

      def capture(environment, argv, chdir:)
        stdout, stderr, status = Open3.capture3(environment, *argv, chdir:)
        Result.new(stdout:, stderr:, status:)
      end
    end

    def initialize(registry_path:, manifest_path:, workspace_root:,
                   component_runner: ComponentRunner.new, out: $stdout)
      @registry = ProductionContextRegistry.new(registry_path, workspace_root:)
      @manifest = Manifest.new(manifest_path)
      @workspace_root = Pathname(workspace_root).expand_path.cleanpath
      @component_runner = component_runner
      @out = out
    end

    # Prepares review for registered batch/job handles and returns exit status 0.
    # Uses DPS-05's optional private data root for review/audit destinations;
    # AFDP owns destination validation. Raises Error for invalid context,
    # evidence, storage or conflicting durable artifacts reported by components.
    def prepare(batch_handle, job_handle)
      context = verified_batch_context(batch_handle)
      plan = load_frozen_plan(context)
      job_id = JobHandleResolver.new(plan).resolve(job_handle)
      plan_id = context.fetch("production_batch_id")
      safe_path_segment!(plan_id, "registered plan ID")
      safe_path_segment!(job_id, "canonical job ID")
      pipeline_root = pipeline_repository_root
      StatePaths.root(front_door_root: ENV.fetch("AF_ADVENTURE_FINDER_ROOT", File.expand_path("..", __dir__)),
        project_root: @workspace_root, owner_roots: [pipeline_root, context.dig("afw", "repository_root"), context.dig("wlo", "output_root")])

      afw_root = context.dig("afw", "repository_root")
      receipt_path = bind_evidence(context, plan_id, job_id)
      receipt_id = receipt_identity(receipt_path)
      storage_root = ENV.fetch("AF_DATA_PIPELINE_DATA_ROOT", pipeline_root)
      review_dir = File.join(storage_root, "output", "adventure-finder-review", plan_id, job_id)
      audit_dir = File.join(storage_root, "audits", "adventure-finder-review", plan_id, job_id)
      pipeline_output = prepare_review_package(
        pipeline_root:, receipt_path:, afw_root:, review_dir:, audit_dir:
      )

      @out.puts "Batch: #{batch_handle} (#{plan_id})"
      @out.puts "Job: #{job_handle} -> #{job_id}"
      @out.puts "AFW receipt: #{receipt_path}"
      @out.puts "AFW receipt ID: #{receipt_id}"
      @out.puts pipeline_output
      0
    end

    private

    def verified_batch_context(handle)
      context = @registry.resolve("batch", handle)
      failures = @registry.verify("batch", handle)
      unless failures.empty?
        raise Error, "registered batch context is invalid: #{failures.join('; ')}"
      end

      context
    end

    def load_frozen_plan(context)
      path = context.dig("afw", "plan_path")
      document = JSON.parse(File.binread(path))
      raise Error, "registered frozen plan must be a JSON object" unless document.is_a?(Hash)

      expected_id = context.dig("plan", "plan_id")
      unless document["plan_id"] == expected_id && expected_id == context.fetch("production_batch_id")
        raise Error, "registered frozen plan identity does not match Batch context"
      end
      unless document["contract_version"] == PLAN_CONTRACT_VERSION
        raise Error, "unsupported frozen plan contract #{document['contract_version'].inspect}"
      end
      document
    rescue Errno::ENOENT, JSON::ParserError => e
      raise Error, "registered frozen plan is invalid: #{e.message}"
    end

    # Returns the explicit executable checkout or the conventional manifest
    # location. Invalid overrides never fall back; unsafe roots and missing
    # public commands raise Error before either owner can persist evidence.
    def pipeline_repository_root
      if ENV.key?("AF_DATA_PIPELINE_ROOT")
        selected = ENV.fetch("AF_DATA_PIPELINE_ROOT")
        unless !selected.strip.empty? && Pathname(selected).absolute? &&
            !selected.include?("\0") && !selected.split(File::SEPARATOR).any? { |part| %w[. ..].include?(part) }
          raise Error, "AF_DATA_PIPELINE_ROOT must name an existing absolute pipeline code directory without traversal"
        end
        root = Pathname(selected).expand_path
        current = root
        loop do
          raise Error, "pipeline code root contains a symlink: #{current}" if current.symlink?
          break if current == current.parent

          current = current.parent
        end
      else
        root = manifest_pipeline_root
      end
      raise Error, "pipeline repository is not a directory: #{root}" unless root.directory?
      executable = root.join("bin", "af-data")
      unless executable.file? && executable.executable?
        raise Error, "pipeline review command is not executable: #{executable}"
      end

      root.to_s
    end

    # Resolves the legacy manifest entry within the workspace. Returns a
    # Pathname or raises Error for absent, ambiguous or escaping entries.
    def manifest_pipeline_root
      matches = @manifest.repositories.select { |repo| repo["name"] == PIPELINE_REPOSITORY }
      unless matches.length == 1
        raise Error, "workspace manifest must contain exactly one #{PIPELINE_REPOSITORY} repository"
      end

      root = (@workspace_root / matches.first.fetch("name")).cleanpath
      prefix = "#{@workspace_root}#{File::SEPARATOR}"
      raise Error, "pipeline repository resolves outside workspace root" unless root.to_s.start_with?(prefix)
      root
    end

    def bind_evidence(context, workload_id, job_id)
      root = context.dig("afw", "repository_root")
      executable = File.join(root, "bin", "afw-bind-scoring-evidence")
      raise Error, "AFW evidence-binding command is not executable: #{executable}" unless File.executable?(executable)

      result = @component_runner.capture(
        {}, [executable, workload_id, context.dig("wlo", "output_root"), job_id], chdir: root
      )
      unless result.status.success?
        component_failure!(
          "AFW evidence binding", result,
          "resolve the reported evidence/execution problem, then rerun bin/af-review prepare"
        )
      end
      match = result.stdout.to_s.match(/^Evidence receipt: (.+)$/)
      raise Error, "AFW evidence binding did not report a receipt path" unless match

      path = File.expand_path(match[1].strip)
      afw_root = File.realpath(root)
      unless File.file?(path) && File.realpath(path).start_with?("#{afw_root}#{File::SEPARATOR}")
        raise Error, "AFW evidence binding reported an invalid receipt path: #{path}"
      end
      path
    rescue Errno::ENOENT => e
      raise Error, "AFW evidence binding reported an invalid receipt path: #{e.message}"
    end

    def receipt_identity(path)
      document = JSON.parse(File.binread(path))
      identity = document["receipt_id"]
      unless identity.is_a?(String) && identity.match?(ProductionContextRegistry::SHA256_PATTERN)
        raise Error, "AFW receipt did not expose a valid receipt identity"
      end
      identity
    rescue JSON::ParserError => e
      raise Error, "AFW receipt is invalid JSON: #{e.message}"
    end

    def prepare_review_package(pipeline_root:, receipt_path:, afw_root:, review_dir:, audit_dir:)
      executable = File.join(pipeline_root, "bin", "af-data")
      raise Error, "pipeline review command is not executable: #{executable}" unless File.executable?(executable)

      argv = [
        executable, "prepare-review", receipt_path,
        "--afw-root", afw_root,
        "--review-dir", review_dir,
        "--audit-dir", audit_dir
      ]
      result = @component_runner.capture({}, argv, chdir: pipeline_root)
      unless result.status.success?
        component_failure!(
          "pipeline review preparation", result,
          "resolve the reported review package/ledger problem, then rerun bin/af-review prepare"
        )
      end
      output = result.stdout.to_s.strip
      raise Error, "pipeline review preparation did not report package status" if output.empty?

      output
    end

    def component_failure!(label, result, next_action)
      detail = result.stderr.to_s.strip
      detail = result.stdout.to_s.strip if detail.empty?
      detail = "component exited without an error message" if detail.empty?
      raise Error, "#{label} failed: #{detail}. Next: #{next_action}."
    end

    def safe_path_segment!(value, label)
      return if value.is_a?(String) && SAFE_PATH_SEGMENT.match?(value) && !%w[. ..].include?(value)

      raise Error, "#{label} is unsafe for deterministic review storage: #{value.inspect}"
    end
  end
end
