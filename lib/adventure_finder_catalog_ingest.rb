# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "pathname"
require "securerandom"
require "time"
require_relative "adventure_finder_ingest_operation_store"
require_relative "adventure_finder_ingest_routing"
require_relative "adventure_finder_ingest_source_driver"
require_relative "adventure_finder_ingest_boundary_continuation"
require_relative "adventure_finder_ingest_release_continuation"
require_relative "adventure_finder_final_promotion"
require_relative "adventure_finder_local_capability_plan"
require_relative "adventure_finder_local_execution"
require_relative "adventure_finder_staged_scoring_intent"
require_relative "adventure_finder_staged_workload_preparation"
require_relative "adventure_finder_successor_version_authorization"
require_relative "adventure_finder_pipeline_data_paths"

module AdventureFinderWorkspace
  # Human-facing start/resume lifecycle for one durable digital-book ingest.
  class CatalogIngest
    CONTEXT_VERSION = "adventurefinder-catalog-ingest-context/v0.1"
    SOURCE_CONTEXT_VERSION = "adventurefinder-catalog-ingest-context/v0.2"
    STATE_CONTEXT_VERSION = "adventurefinder-catalog-ingest-context/v0.3"
    RECEIPT_VERSION = "pdf-to-llm-md/conversion-receipt/v0.1"
    CONTEXT_ROOTS = IngestOperation::ROOTS.sort.freeze
    STAGED_SCORING_POLICY = StagedScoringIntentStore::SUPPORTED_POLICY

    class Failure < Error
      attr_reader :code, :status

      def initialize(code, message, status: 1)
        @code = code
        @status = status
        super("#{code}: #{message}")
      end
    end

    class UniquePolicyObject < Hash
      def []=(key, value)
        raise Failure.new("SCORING_POLICY_MISMATCH", "duplicate staged-scoring policy key") if key?(key)

        super
      end
    end

    attr_reader :front_door_root, :project_root, :out, :env

    def initialize(front_door_root:, project_root:, out: $stdout, env: ENV)
      @front_door_root = Pathname(front_door_root).expand_path
      @project_root = Pathname(project_root).expand_path
      @out = out
      @env = env
    end

    def start(pdf:, base_catalog:, source_declaration:, policy_definition: nil, policy_id: nil,
              policy_version: nil, policy_values: nil, selected_by:, operation_id: SecureRandom.uuid,
              canonical_destination: nil, scoring_choice: nil, successor_version: nil)
      input = required_file(pdf, "input PDF")
      fail_with("UNSUPPORTED_INPUT", "input must be a .pdf file") unless input.extname.casecmp?(".pdf")
      catalog = required_file(base_catalog, "base catalog")
      selected_at = utc_now
      context = build_context(operation_id, input:, catalog:, canonical_destination:)
      policy = start_policy(context, policy_definition:, policy_id:, policy_version:,
                            policy_values:, scoring_choice:, selected_by:, selected_at:)
      if successor_version && (!canonical_destination ||
                               !SuccessorVersionAuthorizationStore::SUCCESSOR_VERSION.match?(successor_version))
        fail_with("INVALID_SUCCESSOR_VERSION", "select a dotted numeric successor version for continuous ingest")
      end
      store = store_for(context)
      if env.key?("AF_STATE_ROOT") &&
         (store.root.join(operation_id).exist? || context_path(operation_id).exist?)
        fail_with("CONFLICT", "operation or context already exists; resume it or use explicit recovery for a missing context")
      end
      choices = source_declaration.to_h do |key, value|
        [key, choice(value, selected_by:, selected_at:)]
      end

      operation = store.create(
        operation_id:,
        created_at: selected_at,
        input_locator: locator(input, Pathname(context.dig("roots", "input")), "input"),
        base_catalog_locator: locator(catalog, Pathname(context.dig("roots", "catalog")), "catalog"),
        catalog_selected_by: selected_by,
        catalog_selected_at: selected_at,
        source_declaration: choices,
        policy:
      )
      write_context!(context)
      authority_store_for(context, store).bind!(
        operation_id:, successor_version:, selected_by:
      ) if successor_version
      capture_scoring_choice!(context, store, operation_id, scoring_choice,
                              selected_by:, interaction: "ingest_start") if scoring_choice

      out.puts "Started durable catalog ingest"
      out.puts "Operation handle: #{operation_id}"
      out.puts "Input: #{input}"
      out.puts "Base catalog: #{catalog}"
      out.puts

      status, receipt = convert(input, context)
      unless receipt&.file?
        fail_with(
          "CONVERSION_RECEIPT_MISSING",
          "converter did not report a durable conversion receipt; conversion exit status was #{status.exitstatus}",
          status: status.success? ? 1 : status.exitstatus
        )
      end

      current = bind_receipt(store, operation, receipt, context)
      result = continue_or_route(store, context, current.fetch("operation_id"))
      out.puts
      routing_for(store, context).render(result, out:)
      return status.exitstatus unless status.success?

      result["status"] == "REJECTED" ? 2 : 0
    rescue IngestOperationStore::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    rescue StagedScoringIntentStore::Failure, SuccessorVersionAuthorizationStore::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    end

    def resume(operation_id, scoring_choice: nil, selected_by: nil, approved_by: nil, final_approver: nil)
      context = load_context(operation_id)
      store = store_for(context)
      routing = routing_for(store, context)
      inspection = routing.source_continuation_input(operation_id)
      if inspection.is_a?(Hash) && inspection["status"] == "REJECTED"
        routing.render(inspection, out:)
        return 2
      end
      # The public decision validator checks the frozen policy definition and
      # intent again, even when this invocation makes no new decision.
      begin
        scoring_intent_store_for(context, store).decision(operation_id)
      rescue StagedScoringIntentStore::Failure => e
        raise unless e.code == "MISSING_SCORING_INTENT"
      end
      capture_scoring_choice!(context, store, operation_id, scoring_choice,
                              selected_by:, interaction: "post_boundary_resume") if scoring_choice
      retained_release = release_paths(context, operation_id)
      if final_approver && File.file?(retained_release.fetch(:package_path))
        return final_promotion(context, retained_release, final_approver)
      end
      result = continue_or_route(store, context, operation_id)
      if approved_by || boundary_approval_path(context, operation_id).file?
        fail_with("BOUNDARY_NOT_READY", "explicit boundary approval requires the editorial review gate") unless
          result["status"] == "WAITING" && result.dig("gate", "state") == "BOUNDARY_EDITORIAL_REVIEW"
        scoring_intent_store_for(context, store).intent!(operation_id)
        paths = if approved_by
                  IngestBoundaryContinuation.new(
                    store:, routing:, authorization_store: authority_store_for(context, store),
                    front_door_root: context.fetch("front_door_root"),
                    project_root: context.fetch("project_root"),
                    pipeline_root: context.fetch("pipeline_root"),
                    source_root: context.fetch("source_root"),
                    catalog_root: context.fetch("catalog_root"), out:, env:
                  ).drive(operation_id:, review_workspace: result.fetch("review_workspace"), approved_by:)
                else
                  continued_boundary_paths(context, operation_id, result.fetch("review_workspace"))
                end
        prepared = prepare_workload_result(operation_id, context, store, **paths.slice(
          :freeze_path, :approval_path, :bundle_dir,
          :historical_project_state_path, :current_project_state_path
        ))
        render_workload_result(prepared)
        return 0 unless prepared["status"] == "PREPARED"

        release_paths = release_paths(context, operation_id)
        unless File.file?(release_paths.fetch(:package_path))
          local_intent = LocalExecutionIntentStore.new(
            root: LocalExecutionIntentStore.default_root(front_door_root: context.fetch("front_door_root"), env:)
          ).intent_path(operation_id)
          if local_intent.file?
            local_resume(operation_id, automatic: true)
          else
            identity = JSON.parse(File.binread(paths.fetch(:approval_path))).dig("approval", "approved_by")
            local_start(operation_id, selected_by: identity, automatic: true)
          end
        end
        ready = release_continuation(context).prepare(operation_id:)
        return final_promotion(context, ready, final_approver) if final_approver

        out.puts "Final catalog review awaits explicit human approval: bin/af-catalog resume #{operation_id} --approve-final-by NAME"
        return 0
      end
      fail_with("FINAL_APPROVAL_NOT_READY", "boundary approval and verified release are required") if final_approver
      routing_for(store, context).render(result, out:)
      result["status"] == "REJECTED" ? 2 : 0
    rescue IngestOperationStore::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    rescue StagedScoringIntentStore::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    rescue IngestBoundaryContinuation::Failure, IngestReleaseContinuation::Failure, StagedWorkloadPreparation::Failure,
           SuccessorVersionAuthorizationStore::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    end

    def prepare_workload(operation_id, freeze_path:, approval_path:, bundle_dir:,
                         historical_project_state_path:, current_project_state_path: nil)
      context = load_context(operation_id)
      store = store_for(context)
      result = prepare_workload_result(
        operation_id, context, store, freeze_path:, approval_path:, bundle_dir:,
        historical_project_state_path:, current_project_state_path:
      )
      render_workload_result(result)
      0
    rescue IngestOperationStore::Failure, StagedScoringIntentStore::Failure,
           StagedWorkloadPreparation::Failure, SuccessorVersionAuthorizationStore::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    end

    def prepare_workload_result(operation_id, context, store, freeze_path:, approval_path:, bundle_dir:,
                                historical_project_state_path:, current_project_state_path: nil)
      routing = routing_for(store, context)
      intent_store = scoring_intent_store_for(context, store)
      StagedWorkloadPreparation.new(
        front_door_root: context.fetch("front_door_root"),
        project_root: context.fetch("project_root"),
        pipeline_root: context.fetch("pipeline_root"),
        afw_root: env["AF_AFW_ROOT"] || Pathname(context.fetch("project_root")).join("af-workloads"),
        scorer_root: env["AF_SCORER_ROOT"] || Pathname(context.fetch("project_root")).join("af-cli-scoring-utility"),
        source_root: context.fetch("source_root"),
        catalog_root: context.fetch("catalog_root"),
        operation_store: store,
        intent_store:,
        authorization_store: authority_store_for(context, store),
        routing:, env:
      ).prepare(
        operation_id:, freeze_path:, approval_path:, bundle_dir:,
        historical_project_state_path:, current_project_state_path:
      )
    end

    def plan_local_capabilities(operation_id)
      context = load_context(operation_id)
      planner = LocalCapabilityPlan.new(
        front_door_root: context.fetch("front_door_root"),
        project_root: context.fetch("project_root"),
        env:
      )
      out.write(planner.bytes(operation_id:))
      0
    rescue LocalCapabilityPlan::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    end

    def local_start(operation_id, selected_by:, automatic: false)
      context = load_context(operation_id)
      plan = local_capability_plan(context, operation_id)
      local_execution(context, automatic:).start(operation_id:, selected_by:, capability_plan: plan)
    rescue LocalCapabilityPlan::Failure, LocalExecution::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    end

    def local_resume(operation_id, continue_operator_pause: false, automatic: false)
      context = load_context(operation_id)
      plan = local_capability_plan(context, operation_id)
      local_execution(context, automatic:).resume(operation_id:, capability_plan: plan, continue_operator_pause:)
    rescue LocalCapabilityPlan::Failure, LocalExecution::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    end

    def continued_boundary_paths(context, operation_id, workspace)
      destination = pipeline_storage_root(context).join(
        "output", "ingest-boundary-continuations", "v0.1", operation_id
      )
      fail_with("BOUNDARY_NOT_READY", "retained boundary continuation is missing") unless
        destination.directory? && !destination.symlink?
      %w[approval.json boundary-freeze.yml].each do |name|
        path = destination.join(name)
        fail_with("BOUNDARY_NOT_READY", "retained boundary #{name} is missing or unsafe") unless
          path.file? && !path.symlink?
      end
      state = Pathname(context.fetch("catalog_root")).join("PROJECT_STATE.yml")
      historical_state = IngestBoundaryContinuation.historical_project_state_path(
        catalog_root: context.fetch("catalog_root"), operation_id:
      )
      fail_with("BOUNDARY_NOT_READY", "retained historical project state is missing or unsafe; explicit recovery is required") unless
        historical_state.file? && !historical_state.symlink?
      {freeze_path: destination.join("boundary-freeze.yml"),
       approval_path: destination.join("approval.json"), bundle_dir: Pathname(workspace),
       historical_project_state_path: historical_state, current_project_state_path: state}
    end

    def boundary_approval_path(context, operation_id)
      pipeline_storage_root(context).join(
        "output", "ingest-boundary-continuations", "v0.1", operation_id, "approval.json"
      )
    end

    def release_paths(context, operation_id)
      root = pipeline_storage_root(context).join("output", "ingest-releases", "v0.1", operation_id)
      coordination = env.key?("AF_STATE_ROOT") ? state_root(context).join("output", "ingest-releases", "v0.1", operation_id) : root
      {inputs_path: coordination.join("package-inputs.json").to_s, package_path: root.join("package.json").to_s}
    end

    def release_continuation(context)
      IngestReleaseContinuation.new(
        front_door_root: context.fetch("front_door_root"), project_root: context.fetch("project_root"),
        pipeline_root: context.fetch("pipeline_root"), catalog_root: context.fetch("catalog_root"),
        out:, env:
      )
    end

    # Returns the AFDP handoff store selected for this context, retaining the
    # historical front-door layout when unset. Unsafe roots raise Error.
    def pipeline_storage_root(context)
      PipelineDataPaths.root(code_root: context.fetch("pipeline_root"),
                             legacy_root: context.fetch("front_door_root"), env:)
    end

    # Route this operation's package and approver to owner review or replay.
    # Returns the owner's exit code; malformed, foreign or refused inputs raise
    # Failure without rebuilding work or substituting a different package.
    def final_promotion(context, ready, final_approver)
      package = JSON.parse(File.binread(ready.fetch(:package_path)))
      fail_with("FINAL_PROMOTION_REFUSED", "retained final package belongs to a different operation") unless
        package.is_a?(Hash) && package["operation"].is_a?(Hash) &&
        package.dig("operation", "operation_id") == context.fetch("operation_id")
      FinalPromotion.new(
        front_door_root: context.fetch("front_door_root"), project_root: context.fetch("project_root"),
        pipeline_root: context.fetch("pipeline_root"), out:, env:
      ).run(**ready, approver: final_approver)
    rescue AdventureFinderWorkspace::Error, JSON::ParserError, SystemCallError => e
      fail_with("FINAL_PROMOTION_REFUSED", e.message)
    end

    def local_status(operation_id)
      context = load_context(operation_id)
      plan = local_capability_plan(context, operation_id)
      local_execution(context).status(operation_id:, capability_plan: plan)
    rescue LocalCapabilityPlan::Failure, LocalExecution::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    end

    def bind_successor_version(operation_id, successor_version:, selected_by:)
      context = load_context(operation_id)
      store = store_for(context)
      authorization = authority_store_for(context, store).bind!(
        operation_id:, successor_version:, selected_by:
      )
      out.puts "Bound successor-version authority"
      out.puts "Operation handle: #{operation_id}"
      out.puts "Successor version: #{authorization.fetch('successor_version')}"
      out.puts "Authorization: #{authorization.fetch('authorization_id')}"
      0
    rescue IngestOperationStore::Failure, SuccessorVersionAuthorizationStore::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    end

    def successor_version_authority(operation_id)
      context = load_context(operation_id)
      store = store_for(context)
      out.puts JSON.pretty_generate(authority_store_for(context, store).projection(operation_id))
      0
    rescue IngestOperationStore::Failure, SuccessorVersionAuthorizationStore::Failure => e
      fail_with(e.code, e.message.sub(/\A[^:]+: /, ""))
    end

    private

    def local_capability_plan(context, operation_id)
      LocalCapabilityPlan.new(
        front_door_root: context.fetch("front_door_root"),
        project_root: context.fetch("project_root"),
        env:
      ).call(operation_id:)
    end

    def local_execution(context, automatic: false)
      LocalExecution.new(
        front_door_root: context.fetch("front_door_root"),
        project_root: context.fetch("project_root"), out:, env:, evidence_continuation: automatic
      )
    end

    def build_context(operation_id, input:, catalog:, canonical_destination:)
      pipeline_root = Pathname(env.fetch("AF_DATA_PIPELINE_ROOT", project_root.join("af-data-pipeline").to_s)).expand_path
      converter_root = Pathname(
        env.fetch("AF_PDF_CONVERTER_ROOT", project_root.join("pdf-to-llm-md-converter").to_s)
      ).expand_path
      source_root = Pathname(env.fetch("AF_SOURCE_ROOT", project_root.join("md-for-llm-book-content").to_s)).expand_path
      roots = {
        "input" => input.dirname.to_s,
        "front_door" => front_door_root.to_s,
        "pipeline" => PipelineDataPaths.root(code_root: pipeline_root, legacy_root: pipeline_root, env:).to_s,
        "converter" => converter_root.to_s,
        "source" => source_root.to_s,
        "catalog" => catalog.dirname.to_s
      }
      context = {
        "contract_version" => canonical_destination ? SOURCE_CONTEXT_VERSION : CONTEXT_VERSION,
        "operation_id" => operation_id,
        "project_root" => project_root.to_s,
        "front_door_root" => front_door_root.to_s,
        "pipeline_root" => pipeline_root.to_s,
        "source_root" => source_root.to_s,
        "catalog_root" => catalog.dirname.to_s,
        "roots" => roots
      }
      if env.key?("AF_STATE_ROOT")
        context["contract_version"] = STATE_CONTEXT_VERSION
        root = state_root(context)
        validate_operation_id!(operation_id)
        StatePaths.check_operation!(root, operation_id)
        context["state_binding"] = StatePaths.binding(root)
      end
      if canonical_destination
        context["source_progression"] = {
          "canonical_destination" => destination_locator(
            canonical_destination, Pathname(source_root), "source"
          )
        }
      end
      context
    end

    def store_for(context)
      IngestOperationStore.new(
        root: IngestOperationStore.default_root(front_door_root: context.fetch("front_door_root"), env:),
        roots: context.fetch("roots")
      )
    end

    def routing_for(store, context)
      IngestOperationRouting.new(
        store:,
        project_root: context.fetch("project_root"),
        front_door_root: context.fetch("front_door_root"),
        pipeline_root: context.fetch("pipeline_root"),
        source_root: context.fetch("source_root"),
        catalog_root: context.fetch("catalog_root")
      )
    end

    def continue_or_route(store, context, operation_id)
      routing = routing_for(store, context)
      progression = context["source_progression"]
      return routing.compose(operation_id) unless progression

      driver = IngestSourceDriver.new(
        store:,
        routing:,
        project_root: context.fetch("project_root"),
        front_door_root: context.fetch("front_door_root"),
        pipeline_root: context.fetch("pipeline_root"),
        source_root: context.fetch("source_root"),
        catalog_root: context.fetch("catalog_root"), env:
      )
      driver.drive(
        operation_id,
        canonical_destination: resolve_destination(
          progression.fetch("canonical_destination"),
          Pathname(context.fetch("source_root"))
        )
      )
    end

    def authority_store_for(context, store)
      SuccessorVersionAuthorizationStore.new(
        root: SuccessorVersionAuthorizationStore.default_root(
          front_door_root: context.fetch("front_door_root"), env:
        ),
        operation_store: store
      )
    end

    def scoring_intent_store_for(context, store)
      StagedScoringIntentStore.new(
        root: StagedScoringIntentStore.default_root(front_door_root: context.fetch("front_door_root"), env:),
        operation_store: store,
        policy_path: Pathname(context.fetch("pipeline_root")).join(
          "config", "staged_scoring_input_policy_v0.1.json"
        )
      )
    end

    def start_policy(context, policy_definition:, policy_id:, policy_version:,
                     policy_values:, scoring_choice:, selected_by:, selected_at:)
      supplied = [policy_definition, policy_id, policy_version, policy_values]
      if scoring_choice == "decline" && supplied.any? { |value| !value.nil? }
        fail_with("INVALID_SCORING_CHOICE", "decline cannot be combined with explicit policy fields")
      end
      if supplied.all?(&:nil?)
        return nil if scoring_choice == "decline"
        fail_with("MISSING_CHOICE", "select --prepare-staged-scoring or supply an explicit policy") unless
          scoring_choice == "prepare"
        policy_definition, definition = staged_scoring_policy(context)
        policy_id = definition.fetch("policy_id")
        policy_version = definition.fetch("policy_version")
        policy_values = {"selection" => definition.fetch("selection")}
      elsif supplied.any?(&:nil?)
        fail_with("MISSING_CHOICE", "supply all four explicit policy fields or none")
      end

      path = required_file(policy_definition, "policy definition")
      policy = {
        "policy_id" => required_text(policy_id, "policy ID"),
        "policy_version" => required_text(policy_version, "policy version"),
        "definition_sha256" => Digest::SHA256.file(path).hexdigest,
        "selected_values" => policy_values,
        "selected_by" => required_text(selected_by, "selected by"),
        "selected_at" => selected_at
      }
      if scoring_choice == "prepare"
        expected_path, definition = staged_scoring_policy(context)
        expected_values = {"selection" => definition.fetch("selection")}
        unless policy.slice("policy_id", "policy_version", "definition_sha256", "selected_values") == {
          "policy_id" => definition.fetch("policy_id"),
          "policy_version" => definition.fetch("policy_version"),
          "definition_sha256" => Digest::SHA256.file(expected_path).hexdigest,
          "selected_values" => expected_values
        }
          fail_with("SCORING_POLICY_MISMATCH", "explicit policy conflicts with the selected staged-scoring authority")
        end
      end
      policy
    end

    def staged_scoring_policy(context)
      path = Pathname(context.fetch("pipeline_root")).join("config", "staged_scoring_input_policy_v0.1.json")
      fail_with("SCORING_POLICY_MISSING", "restore the supported staged-scoring policy definition") unless path.file?
      definition = JSON.parse(File.binread(path), object_class: UniquePolicyObject)
      unless definition == STAGED_SCORING_POLICY
        fail_with("SCORING_POLICY_MISMATCH", "restore the exact supported staged-scoring policy definition")
      end
      [path, definition]
    rescue JSON::ParserError, SystemCallError
      fail_with("SCORING_POLICY_MISMATCH", "staged-scoring policy authority is unreadable")
    end

    def capture_scoring_choice!(context, store, operation_id, choice, selected_by:, interaction:)
      scoring_intent_store_for(context, store).capture!(
        operation_id:, choice:, selected_by: required_text(selected_by, "scoring choice selected by"), interaction:
      )
    end

    def render_workload_result(result)
      out.puts "Staged scoring workload: #{result.fetch('status')}"
      out.puts "Operation: #{result.fetch('operation_id')}"
      out.puts "Workload: #{result.fetch('workload_id')}"
      out.puts "Qualified cases / metric denominator: #{result.fetch('qualified_cases')} / #{result.fetch('metric_denominator')}"
      result.fetch("selected").each do |entry|
        out.puts "Selected: #{entry.fetch('adventure_id')} (#{entry.fetch('case_count')} cases)"
      end
      result.fetch("deferred").each do |entry|
        label = entry["adventure_id"] || "no new record"
        out.puts "Deferred: #{label} — #{render_workload_reason(entry.fetch('reason'))}"
      end
      result.fetch("refused", []).each do |entry|
        out.puts "Refused: #{entry.fetch('adventure_id')} — #{render_workload_reason(entry.fetch('reason'))}"
      end
      out.puts "Owner decision: #{result.dig('decision', 'code')}"
      if result["inspection"]
        out.puts "AFW inspection: #{result.dig('inspection', 'action')} (#{result.dig('inspection', 'reason_code')})"
      end
      out.puts "Execution authorized: no"
      out.puts "Catalog adoption authorized: no"
      out.puts "Next inspection: #{result.fetch('next_action')}" if result["next_action"]
    end

    def render_workload_reason(reason)
      return reason unless reason.is_a?(Hash)

      [reason["code"], reason["detail"]].compact.join(": ")
    end

    def convert(input, context)
      converter_root = Pathname(context.dig("roots", "converter"))
      converter = converter_root.join("bin", "convert-cached")
      executable!(converter, "cached PDF converter")
      child_env = {
        "AF_PROJECT_ROOT" => context.fetch("project_root"),
        "AF_ADVENTURE_FINDER_ROOT" => context.fetch("front_door_root")
      }
      venv_bin = converter_root.join(".venv", "bin")
      if venv_bin.directory?
        child_env["PATH"] = [venv_bin.to_s, env.fetch("PATH", "")].reject(&:empty?).join(File::PATH_SEPARATOR)
      end

      receipt = nil
      status = nil
      Open3.popen2e(child_env, converter.to_s, input.to_s, "--output-dir", converter_root.join("build").to_s) do |_in, io, wait|
        buffer = +""
        begin
          loop do
            chunk = io.readpartial(4096)
            out.write(chunk)
            out.flush
            buffer << chunk
            while (newline = buffer.index("\n"))
              receipt = receipt_from(buffer.slice!(0..newline)) || receipt
            end
          end
        rescue EOFError
          receipt = receipt_from(buffer) || receipt
        end
        status = wait.value
      end
      [status, receipt]
    end

    def bind_receipt(store, operation, receipt, context)
      root = Pathname(context.dig("roots", "converter"))
      relative = locator(receipt, root, "converter")
      content = File.binread(receipt)
      updated = JSON.parse(JSON.generate(operation))
      updated["revision"] += 1
      updated["previous_revision_sha256"] = IngestOperation.digest(operation)
      updated["artifacts"] << {
        "artifact_id" => "conversion-receipt",
        "kind" => "conversion_receipt",
        "owner" => "pdf-to-llm-md-converter",
        "contract_version" => RECEIPT_VERSION,
        "content" => {
          "sha256" => Digest::SHA256.hexdigest(content),
          "bytes" => content.bytesize,
          "locator" => relative
        },
        "inputs" => ["input"],
        "supersedes" => nil
      }
      updated["coordination"]["status"] = "open"
      updated["coordination"]["route_observation"] = nil
      store.persist!(updated, expected_revision: operation.fetch("revision"),
                     expected_sha256: IngestOperation.digest(operation))
    end

    def context_root
      StatePaths.root(front_door_root:, project_root:, env:).join("output", "ingest-contexts", "v0.1")
    end

    # Returns this operation's namespace after checking all selected owner roles.
    # Accepts a validated context and raises Error on unsafe state placement.
    def state_root(context)
      StatePaths.root(front_door_root:, project_root:,
                      owner_roots: [context.fetch("pipeline_root"), *context.fetch("roots").values.reject { |root| root == front_door_root.to_s }], env:)
    end

    def context_path(operation_id)
      validate_operation_id!(operation_id)
      context_root.join("#{operation_id}.json")
    end

    def write_context!(context)
      path = context_path(context.fetch("operation_id"))
      fail_with("CONFLICT", "resume context already exists for this operation") if path.exist?

      FileUtils.mkdir_p(path.dirname)
      temporary = path.dirname.join(".#{path.basename}.tmp-#{Process.pid}-#{SecureRandom.hex(6)}")
      begin
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.binmode
          file.write(JSON.pretty_generate(context) + "\n")
          file.flush
          file.fsync
        end
        File.rename(temporary, path)
      ensure
        File.unlink(temporary) if temporary.exist?
      end
    rescue SystemCallError => e
      fail_with("CORRUPT_RESUME_CONTEXT", "could not persist resume context: #{e.class}")
    end

    # Loads a retained operation context and requires its original data binding.
    # Takes an operation UUID and returns its context; malformed context, unsafe
    # selectors or changed private storage raise Failure or Error before work.
    def load_context(operation_id)
      path = context_path(operation_id)
      fail_with("UNKNOWN_OPERATION", "unknown operation handle #{operation_id}") unless path.file?
      context = JSON.parse(File.binread(path))
      base_keys = %w[catalog_root contract_version front_door_root operation_id pipeline_root project_root roots source_root]
      external = context.is_a?(Hash) && context["contract_version"] == STATE_CONTEXT_VERSION
      valid_keys = if external
                     expected = base_keys + %w[state_binding]
                     expected += %w[source_progression] if context.key?("source_progression")
                     context.keys.sort == expected.sort &&
                       (!context.key?("source_progression") || valid_source_progression?(context["source_progression"]))
                   elsif context.is_a?(Hash) && context["contract_version"] == SOURCE_CONTEXT_VERSION
                     context.keys.sort == (base_keys + %w[source_progression]).sort &&
                       valid_source_progression?(context["source_progression"])
                   else
                     context.is_a?(Hash) && context.keys.sort == base_keys &&
                       context["contract_version"] == CONTEXT_VERSION
                   end
      unless valid_keys && context["operation_id"] == operation_id &&
             context["roots"].is_a?(Hash) && context["roots"].keys.sort == CONTEXT_ROOTS
        fail_with("CORRUPT_RESUME_CONTEXT", "resume context is malformed or incompatible")
      end
      context.fetch("roots").each_value { |value| absolute_path!(value) }
      %w[catalog_root front_door_root pipeline_root project_root source_root].each do |key|
        absolute_path!(context.fetch(key))
      end
      if external || env.key?("AF_STATE_ROOT")
        unless external && env.key?("AF_STATE_ROOT") &&
               context["state_binding"] == StatePaths.binding(state_root(context)) &&
               context["front_door_root"] == front_door_root.to_s &&
               context["project_root"] == project_root.to_s
          fail_with("STATE_ROOT_MISMATCH", "state selector or retained namespace binding changed; restore the original configuration")
        end
        {
          "AF_DATA_PIPELINE_ROOT" => context.fetch("pipeline_root"),
          "AF_SOURCE_ROOT" => context.fetch("source_root"),
          "AF_PDF_CONVERTER_ROOT" => context.dig("roots", "converter")
        }.each do |selector, retained|
          if env.key?(selector) && Pathname(env.fetch(selector)).expand_path.to_s != retained
            fail_with("STATE_ROOT_MISMATCH", "#{selector} conflicts with retained context; restore the original configuration")
          end
        end
        StatePaths.check_operation!(state_root(context), operation_id)
      end
      selected_data = PipelineDataPaths.root(code_root: context.fetch("pipeline_root"),
        legacy_root: context.fetch("pipeline_root"), env:)
      unless selected_data == Pathname(context.dig("roots", "pipeline"))
        fail_with("PIPELINE_DATA_ROOT_MISMATCH", "pipeline data selector conflicts with retained context; restore the original configuration")
      end
      context
    rescue JSON::ParserError, TypeError
      fail_with("CORRUPT_RESUME_CONTEXT", "resume context is malformed or incompatible")
    rescue SystemCallError => e
      fail_with("CORRUPT_RESUME_CONTEXT", "resume context could not be read: #{e.class}")
    end

    def locator(path, root, root_name)
      resolved_root = root.realpath
      resolved_path = Pathname(path).realpath
      relative = resolved_path.relative_path_from(resolved_root).to_s
      if relative == ".." || relative.start_with?("../")
        fail_with("UNSAFE_PATH", "#{resolved_path} is outside configured root #{resolved_root}")
      end
      {"root" => root_name, "path" => relative}
    rescue ArgumentError, Errno::ENOENT
      fail_with("UNSAFE_PATH", "could not resolve a safe portable locator")
    end

    def destination_locator(path, root, root_name)
      resolved_root = root.realpath
      destination = Pathname(path.to_s).expand_path
      fail_with("MISSING_CHOICE", "canonical destination must end in .md") unless
        destination.extname.casecmp?(".md")
      relative = destination.relative_path_from(root).to_s
      if relative == ".." || relative.start_with?("../") ||
         relative.include?("\\") || relative.include?(":") ||
         relative.match?(/[[:cntrl:]]/) ||
         relative.split("/", -1).any? { |part| ["", ".", ".."].include?(part) }
        fail_with("UNSAFE_PATH", "canonical destination is outside configured source root")
      end
      ancestor = destination
      ancestor = ancestor.parent until ancestor.exist? || ancestor.symlink?
      unless ancestor.realpath == resolved_root ||
             ancestor.realpath.to_s.start_with?(resolved_root.to_s + File::SEPARATOR)
        fail_with("UNSAFE_PATH", "canonical destination escapes configured source root")
      end
      {"root" => root_name, "path" => relative}
    rescue ArgumentError, Errno::ENOENT
      fail_with("UNSAFE_PATH", "could not resolve a safe canonical destination")
    end

    def resolve_destination(locator, root)
      unless locator.is_a?(Hash) && locator.keys.sort == %w[path root] &&
             locator["root"] == "source"
        fail_with("CORRUPT_RESUME_CONTEXT", "resume context has an invalid canonical destination")
      end
      destination_locator(root.join(locator.fetch("path")), root, "source")
      root.join(locator.fetch("path")).cleanpath
    end

    def valid_source_progression?(value)
      value.is_a?(Hash) && value.keys == %w[canonical_destination] &&
        value["canonical_destination"].is_a?(Hash) &&
        value["canonical_destination"].keys.sort == %w[path root]
    end

    def choice(value, selected_by:, selected_at:)
      {"value" => required_text(value, "source declaration"),
       "selected_by" => required_text(selected_by, "selected by"), "selected_at" => selected_at}
    end

    def receipt_from(line)
      match = line.match(/\AConversion receipt:\s+(.+?)\s*\z/)
      Pathname(match[1]).expand_path if match
    end

    def required_file(path, label)
      value = Pathname(path.to_s).expand_path
      fail_with("MISSING_INPUT", "#{label} does not exist: #{value}") unless value.file?
      value
    end

    def executable!(path, label)
      fail_with("COMPONENT_UNAVAILABLE", "#{label} not found or not executable: #{path}") unless path.file? && path.executable?
    end

    def required_text(value, label)
      unless value.is_a?(String) && !value.empty? && value == value.strip && !value.match?(/[[:cntrl:]]/)
        fail_with("MISSING_CHOICE", "#{label} must be a non-empty trimmed value")
      end
      value
    end

    def absolute_path!(value)
      path = Pathname(value.to_s)
      fail_with("CORRUPT_RESUME_CONTEXT", "resume context contains a non-absolute path") unless path.absolute?
    end

    def validate_operation_id!(value)
      fail_with("INVALID_OPERATION_HANDLE", "operation handle must be a lowercase UUIDv4") unless
        value.is_a?(String) && IngestOperationStore::UUID_V4.match?(value)
    end

    def utc_now
      Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def fail_with(code, message, status: 1)
      raise Failure.new(code, message, status:)
    end
  end

  class CatalogIngestCLI
    REQUIRED_START_OPTIONS = %i[source_id edition pagination_authority publisher base_catalog
                                selected_by].freeze

    def self.run(argv, front_door_root:, project_root:, out: $stdout, err: $stderr, env: ENV)
      command = argv.shift
      service = CatalogIngest.new(front_door_root:, project_root:, out:, env:)
      case command
      when "start"
        options = {}
        parser = OptionParser.new do |opts|
          opts.on("--source-id VALUE") { |value| options[:source_id] = value }
          opts.on("--edition VALUE") { |value| options[:edition] = value }
          opts.on("--pagination-authority VALUE") { |value| options[:pagination_authority] = value }
          opts.on("--publisher VALUE") { |value| options[:publisher] = value }
          opts.on("--base-catalog PATH") { |value| options[:base_catalog] = value }
          opts.on("--policy-definition PATH") { |value| options[:policy_definition] = value }
          opts.on("--policy-id VALUE") { |value| options[:policy_id] = value }
          opts.on("--policy-version VALUE") { |value| options[:policy_version] = value }
          opts.on("--policy-values JSON") { |value| options[:policy_values] = parse_policy_values(value) }
          opts.on("--selected-by VALUE") { |value| options[:selected_by] = value }
          opts.on("--operation-id UUID") { |value| options[:operation_id] = value }
          opts.on("--canonical-destination FILE") { |value| options[:canonical_destination] = value }
          opts.on("--successor-version VERSION") { |value| options[:successor_version] = value }
          opts.on("--prepare-staged-scoring") { select_scoring_choice!(options, "prepare") }
          opts.on("--decline-staged-scoring") { select_scoring_choice!(options, "decline") }
        end
        parser.parse!(argv)
        pdf = argv.shift
        missing = REQUIRED_START_OPTIONS.reject { |key| options.key?(key) }
        unless pdf && argv.empty? && missing.empty?
          detail = missing.empty? ? "" : "; missing: #{missing.join(', ')}"
          raise CatalogIngest::Failure.new(
            "MISSING_CHOICE", "usage: bin/af-catalog start INPUT.pdf [required options]#{detail}"
          )
        end
        source = IngestOperation::SOURCE_CHOICES.to_h { |key| [key, options.fetch(key.to_sym)] }
        service.start(pdf:, source_declaration: source, **options.slice(
          :base_catalog, :policy_definition, :policy_id, :policy_version, :policy_values,
          :selected_by, :operation_id, :canonical_destination, :scoring_choice, :successor_version
        ))
      when "resume"
        options = {}
        parser = OptionParser.new do |opts|
          opts.on("--prepare-staged-scoring") { select_scoring_choice!(options, "prepare") }
          opts.on("--decline-staged-scoring") { select_scoring_choice!(options, "decline") }
          opts.on("--selected-by VALUE") { |value| options[:selected_by] = value }
          opts.on("--approve-boundary-by NAME") { |value| options[:approved_by] = value }
          opts.on("--approve-final-by NAME") { |value| options[:final_approver] = value }
        end
        parser.parse!(argv)
        operation_id = argv.shift
        valid_choice = !options.key?(:scoring_choice) || options[:selected_by]
        valid_selector = options.key?(:scoring_choice) || !options.key?(:selected_by)
        unless operation_id && argv.empty? && valid_choice && valid_selector
          raise CatalogIngest::Failure.new(
            "INVALID_OPERATION_HANDLE",
            "usage: bin/af-catalog resume OPERATION_ID " \
            "[--prepare-staged-scoring|--decline-staged-scoring --selected-by VALUE] " \
            "[--approve-boundary-by NAME] [--approve-final-by NAME]"
          )
        end
        service.resume(operation_id, **options)
      when "prepare-workload"
        options = {}
        parser = OptionParser.new do |opts|
          opts.on("--freeze PATH") { |value| options[:freeze_path] = value }
          opts.on("--approval PATH") { |value| options[:approval_path] = value }
          opts.on("--editorial-bundle DIR") { |value| options[:bundle_dir] = value }
          opts.on("--historical-project-state PATH") { |value| options[:historical_project_state_path] = value }
          opts.on("--current-project-state PATH") { |value| options[:current_project_state_path] = value }
        end
        parser.parse!(argv)
        operation_id = argv.shift
        required = %i[freeze_path approval_path bundle_dir historical_project_state_path]
        missing = required.reject { |key| options.key?(key) }
        unless operation_id && argv.empty? && missing.empty?
          raise CatalogIngest::Failure.new(
            "MISSING_CHOICE",
            "usage: bin/af-catalog prepare-workload OPERATION_ID --freeze PATH --approval PATH " \
            "--editorial-bundle DIR --historical-project-state PATH"
          )
        end
        service.prepare_workload(operation_id, **options)
      when "plan-local-capabilities"
        json = false
        parser = OptionParser.new { |opts| opts.on("--json") { json = true } }
        parser.parse!(argv)
        operation_id = argv.shift
        unless operation_id && argv.empty? && json
          raise CatalogIngest::Failure.new(
            "USAGE", "usage: bin/af-catalog plan-local-capabilities OPERATION_ID --json"
          )
        end
        service.plan_local_capabilities(operation_id)
      when "local-start"
        options = {}
        OptionParser.new do |opts|
          opts.on("--selected-by VALUE") { |value| options[:selected_by] = value }
        end.parse!(argv)
        operation_id = argv.shift
        unless operation_id && argv.empty? && options[:selected_by]
          raise CatalogIngest::Failure.new(
            "MISSING_CHOICE", "usage: bin/af-catalog local-start OPERATION_ID --selected-by VALUE"
          )
        end
        service.local_start(operation_id, **options)
      when "local-resume"
        options = {continue_operator_pause: false}
        OptionParser.new do |opts|
          opts.on("--continue-operator-pause") { options[:continue_operator_pause] = true }
        end.parse!(argv)
        operation_id = argv.shift
        unless operation_id && argv.empty?
          raise CatalogIngest::Failure.new(
            "INVALID_OPERATION_HANDLE",
            "usage: bin/af-catalog local-resume OPERATION_ID [--continue-operator-pause]"
          )
        end
        service.local_resume(operation_id, **options)
      when "local-status"
        operation_id = argv.shift
        unless operation_id && argv.empty?
          raise CatalogIngest::Failure.new(
            "INVALID_OPERATION_HANDLE", "usage: bin/af-catalog local-status OPERATION_ID"
          )
        end
        service.local_status(operation_id)
      when "bind-successor-version"
        options = {}
        parser = OptionParser.new do |opts|
          opts.on("--successor-version VERSION") { |value| options[:successor_version] = value }
          opts.on("--selected-by VALUE") { |value| options[:selected_by] = value }
        end
        parser.parse!(argv)
        operation_id = argv.shift
        unless operation_id && argv.empty? && options.keys.sort == %i[selected_by successor_version]
          raise CatalogIngest::Failure.new(
            "MISSING_CHOICE",
            "usage: bin/af-catalog bind-successor-version OPERATION_ID " \
            "--successor-version VERSION --selected-by VALUE"
          )
        end
        service.bind_successor_version(operation_id, **options)
      when "successor-version-authority"
        json = false
        parser = OptionParser.new { |opts| opts.on("--json") { json = true } }
        parser.parse!(argv)
        operation_id = argv.shift
        unless operation_id && argv.empty? && json
          raise CatalogIngest::Failure.new(
            "USAGE", "usage: bin/af-catalog successor-version-authority OPERATION_ID --json"
          )
        end
        service.successor_version_authority(operation_id)
      else
        raise CatalogIngest::Failure.new(
          "USAGE", "usage: bin/af-catalog {start | resume | bind-successor-version | " \
                   "successor-version-authority | prepare-workload | plan-local-capabilities | " \
                   "local-start | local-resume | local-status} ..."
        )
      end
    rescue OptionParser::ParseError => e
      err.puts "af-catalog: USAGE: #{e.message}"
      1
    rescue CatalogIngest::Failure => e
      err.puts "af-catalog: #{e.message}"
      e.status
    rescue Error => e
      err.puts "af-catalog: #{e.message}"
      1
    end

    def self.parse_policy_values(value)
      parsed = JSON.parse(value)
      raise CatalogIngest::Failure.new("MISSING_CHOICE", "policy values must be a non-empty JSON object") unless
        parsed.is_a?(Hash) && !parsed.empty?

      parsed
    rescue JSON::ParserError
      raise CatalogIngest::Failure.new("MISSING_CHOICE", "policy values must be valid JSON")
    end
    private_class_method :parse_policy_values

    def self.select_scoring_choice!(options, choice)
      if options.key?(:scoring_choice) && options[:scoring_choice] != choice
        raise CatalogIngest::Failure.new(
          "INVALID_SCORING_CHOICE", "choose exactly one staged-scoring disposition"
        )
      end
      options[:scoring_choice] = choice
    end
    private_class_method :select_scoring_choice!
  end
end
