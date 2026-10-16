# frozen_string_literal: true

require "json"
require "open3"
require "pathname"
require "fileutils"
require_relative "adventure_finder_ingest_routing"
require_relative "adventure_finder_successor_version_authorization"

module AdventureFinderWorkspace
  # Delegates the attested editorial boundary to pipeline-owned freeze/staging.
  # No candidate, version, score, or catalog policy is decided here.
  class IngestBoundaryContinuation
    class Failure < Error
      attr_reader :code

      def initialize(code, message)
        @code = code
        super("#{code}: #{message}")
      end
    end

    def initialize(store:, routing:, authorization_store:, front_door_root:,
                   project_root:, pipeline_root:, source_root:, catalog_root:,
                   out: $stdout, runner: nil)
      @store, @routing, @authorization_store = store, routing, authorization_store
      @front_door_root = Pathname(front_door_root).expand_path
      @project_root = Pathname(project_root).expand_path
      @pipeline_root = Pathname(pipeline_root).expand_path
      @source_root = Pathname(source_root).expand_path
      @catalog_root = Pathname(catalog_root).expand_path
      @out = out
      @runner = runner || ->(env, *argv) { Open3.capture3(env, *argv) }
    end

    # Locate immutable staging-time evidence beside the role workbooks, as
    # required by AFDP's historical ProjectState resolver. Inputs are the
    # configured catalog root and operation UUID; returns a Pathname and raises
    # Failure for an invalid operation identity.
    def self.historical_project_state_path(catalog_root:, operation_id:)
      unless operation_id.to_s.match?(IngestOperationStore::UUID_V4)
        raise Failure.new("BOUNDARY_CONTINUATION_CONFLICT", "invalid historical-state operation identity")
      end
      Pathname(catalog_root).expand_path.join("HISTORICAL_PROJECT_STATE_#{operation_id}.yml")
    end

    def drive(operation_id:, review_workspace:, approved_by:)
      operation = @store.validate!(operation_id)
      artifacts = operation.fetch("artifacts")
      decisions = artifacts.last
      fail_with("BOUNDARY_NOT_READY", "operation has no linked editorial handoff") unless
        decisions && decisions["kind"] == "editorial_decisions"
      dossier = artifacts.reverse.find { |item| item["kind"] == "boundary_dossier" }
      fail_with("BOUNDARY_NOT_READY", "operation has no bound dossier") unless dossier
      dossier_path = @store.binding_path(operation_id, dossier.fetch("artifact_id"))
      base_path = @store.binding_path(operation_id, "base_catalog")
      bundle = Pathname(review_workspace).expand_path
      expected_bundle = @front_door_root.join("output", "ingest-editorial-workspaces", "v0.1", operation_id)
      fail_with("BOUNDARY_NOT_READY", "review workspace is not the operation's editable handoff") unless
        bundle == expected_bundle && bundle.directory? && !bundle.symlink?
      authorization = @authorization_store.projection(operation_id)
      fail_with("BOUNDARY_NOT_READY", "successor version must be selected at ingest intent") unless
        authorization.dig("authorization", "successor_version")
      fail_with("MISSING_CHOICE", "boundary approver must be identified") unless
        approved_by.is_a?(String) && !approved_by.strip.empty? && approved_by == approved_by.strip

      destination = @front_door_root.join("output", "ingest-boundary-continuations", "v0.1", operation_id)
      check_private_path!(destination)
      fail_with("BOUNDARY_CONTINUATION_CONFLICT", "continuation path is not a directory") if
        destination.exist? && !destination.directory?
      FileUtils.mkdir_p(destination)
      check_private_path!(destination)
      approval = destination.join("approval.json")
      freeze = destination.join("boundary-freeze.yml")
      draft = destination.join("boundary-freeze-draft.yml")
      %w[approval.json boundary-freeze.yml boundary-freeze-draft.yml operation-input.json
         successor-authority.json].each { |name| check_private_path!(destination.join(name)) }
      common = [bundle.to_s, "--dossier", dossier_path.to_s,
                "--source-root", @source_root.to_s, "--amc", base_path.to_s]
      invoke("af-boundary-editorial", "validate", bundle.to_s, "--complete")
      invoke("af-boundary-editorial", "approve", *common,
             "--approved-by", approved_by, "--output", approval.to_s)
      invoke("af-boundary-editorial", "freeze-approved", bundle.to_s,
             "--approval", approval.to_s, "--dossier", dossier_path.to_s,
             "--freeze", draft.to_s, "--source-root", @source_root.to_s,
             "--amc", base_path.to_s, "--output", freeze.to_s)
      invoke("af-boundary-editorial", "validate-approved-freeze", bundle.to_s,
             "--approval", approval.to_s, "--dossier", dossier_path.to_s,
             "--source-root", @source_root.to_s, "--amc", base_path.to_s,
             "--output", freeze.to_s)

      prepared = @routing.boundary_freeze_input(operation_id, freeze_path: freeze)
      if prepared.is_a?(Hash)
        fail_with(prepared.dig("diagnostic", "code") || "BOUNDARY_NOT_READY",
                  prepared.dig("diagnostic", "message") || "freeze projection refused")
      end
      operation_input = destination.join("operation-input.json")
      authority_input = destination.join("successor-authority.json")
      write_exact(operation_input, prepared.projection)
      write_exact(authority_input, authorization)
      state = @catalog_root.join("PROJECT_STATE.yml")
      fail_with("PROJECT_STATE_MISSING", "current catalog project state is unavailable") unless state.file?
      state_bytes = File.binread(state)
      stage = invoke("af-data", "boundary-freeze-stage", freeze.to_s,
                     "--operation-input", operation_input.to_s,
                     "--successor-authority", authority_input.to_s,
                     "--source-root", @source_root.to_s,
                     "--catalog-root", @catalog_root.to_s,
                     "--project-state", state.to_s, "--no-progress")
      receipt = stage[/^(?:Staging|Trace) receipt: (.+)$/, 1]
      fail_with("STAGING_RECEIPT_MISSING", "pipeline did not report its staging receipt") unless
        receipt && Pathname(receipt).file?
      fail_with("PROJECT_STATE_CHANGED", "catalog state changed while retaining staging evidence") unless
        File.binread(state) == state_bytes
      historical_state = self.class.historical_project_state_path(catalog_root: @catalog_root, operation_id:)
      retain_project_state(historical_state, state_bytes)
      @out.puts stage
      {freeze_path: freeze, approval_path: approval, bundle_dir: bundle,
       historical_project_state_path: historical_state, current_project_state_path: state,
       staging_receipt_path: Pathname(receipt)}
    rescue IngestOperationStore::Failure, SuccessorVersionAuthorizationStore::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    end

    private

    # Preserve exact owner-validated staging bytes once. Existing conflicting,
    # symlinked or partial evidence raises Failure; no shared role is changed.
    def retain_project_state(path, bytes)
      if path.exist? || path.symlink?
        fail_with("BOUNDARY_CONTINUATION_CONFLICT", "retained historical project state changed or is unsafe") unless
          path.file? && !path.symlink? && File.binread(path) == bytes
        return
      end
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(bytes)
        file.flush
        file.fsync
      end
    rescue Errno::EEXIST
      fail_with("BOUNDARY_CONTINUATION_CONFLICT", "historical project state was created concurrently; validate before retry")
    end

    def check_private_path!(path)
      relative = path.relative_path_from(@front_door_root)
      current = @front_door_root
      relative.each_filename do |part|
        current = current.join(part)
        fail_with("BOUNDARY_CONTINUATION_CONFLICT", "symlinked continuation path: #{current}") if current.symlink?
      end
    end

    def invoke(command, *arguments)
      executable = @pipeline_root.join("bin", command)
      fail_with("PIPELINE_UNAVAILABLE", "public pipeline command is unavailable: #{executable}") unless
        executable.file? && executable.executable?
      stdout, stderr, status = @runner.call(
        {"AF_PROJECT_ROOT" => @project_root.to_s, "AF_ADVENTURE_FINDER_ROOT" => @front_door_root.to_s},
        executable.to_s, *arguments
      )
      fail_with("PIPELINE_REJECTED", "#{command} #{arguments.first}: #{stderr.to_s.strip}") unless status.success?
      stdout
    end

    def write_exact(path, document)
      bytes = JSON.pretty_generate(IngestOperation.canonical(document)) + "\n"
      if path.exist?
        fail_with("BOUNDARY_CONTINUATION_CONFLICT", "changed continuation input: #{path}") unless
          path.file? && !path.symlink? && File.binread(path) == bytes
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
