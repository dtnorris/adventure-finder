# frozen_string_literal: true

require_relative "adventure_finder_state_paths"

require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "securerandom"
require "tempfile"
require_relative "adventure_finder_ingest_operation_store"
require_relative "adventure_finder_ingest_routing"

module AdventureFinderWorkspace
  # Drives only the deterministic source-side continuation published by
  # af-data-pipeline. It binds validated component outputs into the existing
  # operation and stops at the boundary-editorial review workspace.
  class IngestSourceDriver
    VERSION = "adventurefinder-ingest-source-driver/v0.1"
    RESULT_VERSION = "af-source-progression-result/v0.1"
    ERROR_VERSION = "af-source-progression-error/v0.1"
    MAX_TRANSITIONS = 3
    TERMINAL_STATE = "BOUNDARY_EDITORIAL_REVIEW"
    ALLOWED_ROUTES = {
      "conversion_receipt" => %w[NEEDS_CANONICAL_MARKDOWN_PLACEMENT],
      "source_intake" => %w[READY_FOR_SOURCE_REGISTRATION READY_FOR_BOUNDARY_DOSSIER],
      "boundary_dossier" => %w[READY_FOR_EDITORIAL_HANDOFF NEEDS_EDITORIAL_SPECIFICATIONS]
    }.freeze
    EXPECTED_PASS = {
      "conversion_receipt" => {
        "state" => "SOURCE_INTAKE_READY",
        "transition" => "accepted_conversion_to_source_intake",
        "artifacts" => %w[source_intake],
        "roles" => %w[operation_artifact canonical_source companion_evidence]
      },
      "source_intake" => {
        "state" => "BOUNDARY_DOSSIER_READY",
        "transition" => "source_intake_to_boundary_dossier",
        "artifacts" => %w[boundary_dossier],
        "roles" => %w[operation_artifact companion_evidence]
      },
      "boundary_dossier" => {
        "state" => "BOUNDARY_EDITORIAL_HANDOFF_READY",
        "transition" => "boundary_dossier_to_editorial_handoff",
        "artifacts" => %w[editorial_context editorial_decisions],
        "roles" => %w[operation_artifact operation_artifact companion_evidence]
      }
    }.freeze
    EXPECTED_CONTRACT = {
      "one_transition_maximum" => true,
      "operation_lifecycle_mutated" => false,
      "semantic_choices_created" => false,
      "catalog_roles_mutated" => false,
      "inference_or_scoring_executed" => false
    }.freeze

    class CommandRunner
      Result = Struct.new(:stdout, :stderr, :status, keyword_init: true)

      def capture(environment, *argv)
        stdout, stderr, status = Open3.capture3(environment, *argv)
        Result.new(stdout:, stderr:, status:)
      end
    end

    attr_reader :store, :routing, :project_root, :front_door_root,
                :pipeline_root, :source_root, :catalog_root, :runner

    def initialize(store:, routing:, project_root:, front_door_root:, pipeline_root:,
                   source_root:, catalog_root:, runner: CommandRunner.new, env: ENV)
      @store = store
      @routing = routing
      @project_root = Pathname(project_root).expand_path
      @front_door_root = Pathname(front_door_root).expand_path
      @pipeline_root = Pathname(pipeline_root).expand_path
      @source_root = Pathname(source_root).expand_path
      @catalog_root = Pathname(catalog_root).expand_path
      @runner = runner
      @env = env
    end

    def drive(operation_id, canonical_destination:)
      MAX_TRANSITIONS.times do
        operation = store.validate!(operation_id)
        routing.validate_editorial_specifications!(operation)
        return boundary_handoff(operation) if editorial_handoff?(operation)

        route = routing.compose(operation_id)
        return route unless route["status"] == "ROUTED"

        kind = route.dig("artifact", "kind")
        allowed = ALLOWED_ROUTES[kind]
        return route unless allowed&.include?(route.dig("gate", "state"))

        prepared = routing.source_continuation_input(operation_id)
        return prepared if prepared.is_a?(Hash)
        unless IngestOperation.digest(prepared.operation) == route.dig("operation", "document_sha256")
          return diagnostic(prepared.operation, "OPERATION_CHANGED",
                            "operation changed between source routing and continuation")
        end

        payload = invoke(prepared, canonical_destination: kind == "conversion_receipt" ? canonical_destination : nil)
        return payload if payload["contract_version"] == VERSION

        if payload.fetch("status") == "GATE"
          return gate_result(prepared.operation, kind, payload)
        end

        operation = bind_pass(prepared, payload)
        return boundary_handoff(operation) if editorial_handoff?(operation)
      end

      operation = store.validate!(operation_id)
      diagnostic(operation, "SOURCE_PROGRESSION_LIMIT",
                 "source progression exceeded its fixed three-transition boundary")
    rescue IngestOperationStore::Failure => e
      diagnostic(operation, e.code, e.message.sub(/\A[^:]+: /, ""))
    rescue SystemCallError => e
      diagnostic(operation, "PIPELINE_UNAVAILABLE", "source progression invocation failed: #{e.class}")
    end

    private

    def invoke(prepared, canonical_destination:)
      executable = pipeline_root.join("bin", "af-source-progress")
      unless executable.file? && executable.executable?
        return diagnostic(prepared.operation, "PIPELINE_UNAVAILABLE",
                          "public source progression executable is unavailable: #{executable}",
                          owner: "af-data-pipeline")
      end

      Tempfile.create(["af-source-progression-", ".json"]) do |file|
        file.binmode
        file.write(JSON.pretty_generate(canonical(prepared.projection)) + "\n")
        file.flush
        file.fsync
        argv = [
          executable.to_s,
          prepared.target.fetch("path"),
          "--operation-input", file.path,
          "--source-root", source_root.to_s,
          "--catalog-root", catalog_root.to_s,
          "--pipeline-root", store.roots.fetch("pipeline").to_s
        ]
        argv.concat(["--canonical-destination", canonical_destination.to_s]) if canonical_destination
        specifications = prepared.operation["editorial_specifications"]
        argv.concat(["--spec-root", specifications.fetch("root")]) if specifications
        argv << "--json"
        response = runner.capture(
          {"AF_PROJECT_ROOT" => project_root.to_s, "AF_ADVENTURE_FINDER_ROOT" => front_door_root.to_s},
          *argv
        )
        parsed = parse_json(response.stdout)
        if response.status.success?
          return protocol_error(prepared.operation, "source progression returned invalid JSON") unless parsed

          error = validate_payload(parsed, prepared, canonical_destination:)
          return error if error

          return parsed
        end

        failure = parse_json(response.stderr)
        if failure.is_a?(Hash) && failure["schema_version"] == ERROR_VERSION &&
           failure["error"].is_a?(Hash)
          return diagnostic(
            prepared.operation,
            failure.dig("error", "code") || "SOURCE_PROGRESSION_FAILED",
            failure.dig("error", "message") || "source progression failed",
            owner: "af-data-pipeline"
          )
        end
        detail = response.stderr.to_s.strip
        detail = "source progression exited #{response.status.exitstatus} without a versioned error" if detail.empty?
        diagnostic(prepared.operation, "SOURCE_PROGRESSION_FAILED", detail, owner: "af-data-pipeline")
      end
    end

    def validate_payload(payload, prepared, canonical_destination:)
      expected_keys = %w[contract evidence human_review input operation outputs reused
                         schema_version state status transition]
      return protocol_error(prepared.operation, "source progression returned an incompatible result contract") unless
        payload.is_a?(Hash) && payload.keys.sort == expected_keys.sort &&
        payload["schema_version"] == RESULT_VERSION &&
        %w[PASS GATE].include?(payload["status"]) &&
        payload["evidence"].is_a?(Array) && payload["evidence"].all? { |item| item.is_a?(String) } &&
        payload["human_review"].is_a?(Array) && payload["human_review"].all? { |item| item.is_a?(String) } &&
        payload["reused"].is_a?(Array) && payload["reused"].all? { |item| item.is_a?(String) } &&
        payload["contract"] == EXPECTED_CONTRACT

      expected_operation = prepared.projection.fetch("operation").except("contract_version").merge(
        "routing_input_sha256" => Digest::SHA256.hexdigest(JSON.generate(canonical(prepared.projection)))
      )
      expected_input = {
        "artifact_type" => prepared.target.fetch("kind"),
        "binding" => prepared.projection.fetch("artifact"),
        "validated" => true
      }
      return protocol_error(prepared.operation, "source progression operation identity mismatch") unless
        payload["operation"] == expected_operation && payload["input"] == expected_input

      if payload["status"] == "GATE"
        return protocol_error(prepared.operation, "source progression gate unexpectedly published outputs") unless
          payload["transition"].nil? && payload["outputs"] == [] &&
          payload["state"].is_a?(String) && !payload["state"].empty?
        return nil
      end

      expected = EXPECTED_PASS.fetch(prepared.target.fetch("kind"))
      outputs = payload["outputs"]
      return protocol_error(prepared.operation, "source progression PASS has the wrong transition") unless
        payload["state"] == expected.fetch("state") &&
        payload["transition"] == expected.fetch("transition") &&
        outputs.is_a?(Array) &&
        outputs.map { |item| item.is_a?(Hash) && item["role"] } == expected.fetch("roles")

      artifacts = outputs.select { |item| item["role"] == "operation_artifact" }
      return protocol_error(prepared.operation, "source progression PASS has the wrong operation artifacts") unless
        artifacts.map { |item| item["kind"] } == expected.fetch("artifacts")

      if prepared.target.fetch("kind") == "conversion_receipt"
        canonical_source = outputs.find { |item| item["role"] == "canonical_source" }
        expected_locator = Pathname(canonical_destination).expand_path
                                                        .relative_path_from(source_root).to_s
        unless canonical_source&.dig("content", "locator") ==
               {"root" => "source", "path" => expected_locator}
          return protocol_error(
            prepared.operation,
            "source progression canonical output does not match the operation-bound destination"
          )
        end
      end

      outputs.each do |output|
        error = validate_output(output, prepared.operation)
        return error if error
      end
      nil
    end

    def validate_output(output, operation)
      role = output["role"]
      content = output["content"]
      exact_keys = case role
                   when "operation_artifact" then %w[content contract_version kind owner role]
                   when "canonical_source", "companion_evidence" then %w[content role]
                   else return protocol_error(operation, "source progression published an unsupported output role")
                   end
      return protocol_error(operation, "source progression output has an incompatible shape") unless
        output.keys.sort == exact_keys.sort && valid_content?(content)

      if role == "operation_artifact"
        spec = IngestOperation::ARTIFACTS[output["kind"]]
        return protocol_error(operation, "source progression published an unsupported operation artifact") unless
          output["owner"] == "af-data-pipeline" && spec &&
          spec[0] == output["owner"] && spec[1].include?(output["contract_version"]) &&
          content.dig("locator", "root") == "pipeline"
      elsif role == "canonical_source"
        return protocol_error(operation, "canonical source output has the wrong root") unless
          content.dig("locator", "root") == "source"
      elsif content.dig("locator", "root") != "pipeline"
        return protocol_error(operation, "companion output has the wrong root")
      end

      root = store.roots[content.dig("locator", "root")]
      return protocol_error(operation, "source progression output root is unavailable") unless root&.directory?

      path = root.join(content.dig("locator", "path")).cleanpath
      return protocol_error(operation, "source progression output is missing") unless path.file?
      root_real = root.realpath
      path_real = path.realpath
      return protocol_error(operation, "source progression output escapes its declared root") unless
        descendant?(path_real, root_real)
      return protocol_error(operation, "source progression output content mismatch") unless
        File.size(path) == content["bytes"] && Digest::SHA256.file(path).hexdigest == content["sha256"]

      nil
    rescue SystemCallError
      protocol_error(operation, "source progression output could not be validated")
    end

    def valid_content?(content)
      content.is_a?(Hash) && content.keys.sort == %w[bytes locator sha256] &&
        content["bytes"].is_a?(Integer) && content["bytes"].positive? &&
        content["sha256"].is_a?(String) && content["sha256"].match?(/\A[0-9a-f]{64}\z/) &&
        content["locator"].is_a?(Hash) && content["locator"].keys.sort == %w[path root] &&
        safe_relative?(content.dig("locator", "path"))
    end

    def bind_pass(prepared, payload)
      previous = prepared.operation
      updated = deep_copy(previous)
      updated["revision"] += 1
      updated["previous_revision_sha256"] = IngestOperation.digest(previous)
      outputs = payload.fetch("outputs").select { |item| item.fetch("role") == "operation_artifact" }
      new_ids = []
      outputs.each do |output|
        kind = output.fetch("kind")
        digest = output.dig("content", "sha256")
        artifact_id = "#{kind}-#{digest[0, 16]}"
        latest = updated.fetch("artifacts").reverse.find { |item| item["kind"] == kind }
        inputs = if kind == "editorial_decisions"
                   [new_ids.fetch(-1)]
                 else
                   prepared.target.fetch("artifact_ids") + (kind == "source_intake" ? ["input"] : ["base_catalog"])
                 end
        updated["artifacts"] << {
          "artifact_id" => artifact_id,
          "kind" => kind,
          "owner" => output.fetch("owner"),
          "contract_version" => output.fetch("contract_version"),
          "content" => deep_copy(output.fetch("content")),
          "inputs" => inputs.uniq,
          "supersedes" => latest && latest.fetch("artifact_id")
        }
        new_ids << artifact_id
      end
      updated["coordination"]["status"] = "open"
      updated["coordination"]["route_observation"] = nil
      store.persist!(
        updated,
        expected_revision: previous.fetch("revision"),
        expected_sha256: IngestOperation.digest(previous)
      )
    end

    def editorial_handoff?(operation)
      operation.fetch("artifacts").last&.fetch("kind") == "editorial_decisions"
    end

    def boundary_handoff(operation)
      decisions = operation.fetch("artifacts").last
      context = operation.fetch("artifacts").reverse.find do |item|
        item["kind"] == "editorial_context" && decisions.fetch("inputs").include?(item.fetch("artifact_id"))
      end
      return diagnostic(operation, "INCOMPLETE_EDITORIAL_BUNDLE",
                        "editorial decisions are not linked to their context") unless context

      context_path = store.binding_path(operation.fetch("operation_id"), context.fetch("artifact_id"))
      decisions_path = store.binding_path(operation.fetch("operation_id"), decisions.fetch("artifact_id"))
      return diagnostic(operation, "INCOMPLETE_EDITORIAL_BUNDLE",
                        "editorial review artifacts are not in one authoritative workspace") unless
        context_path.dirname == decisions_path.dirname

      selected = operation["editorial_specifications"]
      if selected && JSON.parse(File.binread(context_path))["public_specifications"] != selected
        return diagnostic(operation, "EDITORIAL_SPECIFICATIONS_REFUSED", "editorial bundle differs from operation-bound specifications")
      end
      review_workspace = editable_review_workspace(operation, context_path.dirname)
      return review_workspace if review_workspace.is_a?(Hash)

      {
        "contract_version" => VERSION,
        "status" => "WAITING",
        "operation" => operation_summary(operation),
        "artifact" => {
          "artifact_ids" => [context.fetch("artifact_id"), decisions.fetch("artifact_id")],
          "kind" => "editorial_bundle"
        },
        "pipeline" => nil,
        "gate" => {"state" => TERMINAL_STATE, "kind" => "HUMAN_REVIEW"},
        "route" => {
          "state" => TERMINAL_STATE,
          "artifact_type" => "editorial_bundle",
          "evidence" => ["Validated boundary-editorial context and decisions ledger are bound to this operation."],
          "human_review" => ["Complete Phase 1, Phase 1b, Phase 2, and David approval in the authoritative review workspace."],
          "commands" => [],
          "warnings" => []
        },
        "diagnostic" => nil,
        "review_workspace" => review_workspace.to_s
      }
    end

    # The pipeline's editorial ledger is edited in place. The operation's
    # append-only reference must continue to bind the empty handoff ledger,
    # so publish a separate editable workspace for the human review.
    def editable_review_workspace(operation, bound_dir)
      names = %w[editorial_context.json editorial_decisions.yml editorial_review.md]
      destination = StatePaths.root(front_door_root:, project_root:, owner_roots: [source_root, catalog_root, pipeline_root], env: @env).join("output", "ingest-editorial-workspaces", "v0.1",
                                        operation.fetch("operation_id"))
      names.each do |name|
        source = bound_dir.join(name)
        return diagnostic(operation, "INCOMPLETE_EDITORIAL_BUNDLE",
                          "editorial review workspace lacks #{name}") unless source.file?
      end
      if destination.exist? || destination.symlink?
        unless !destination.symlink? && destination.directory? &&
               names.all? { |name| destination.join(name).file? && !destination.join(name).symlink? } &&
               %w[editorial_context.json editorial_review.md].all? do |name|
                 File.binread(destination.join(name)) == File.binread(bound_dir.join(name))
               end
          return diagnostic(operation, "EDITORIAL_WORKSPACE_CONFLICT",
                            "existing editable review workspace conflicts with the bound handoff")
        end
        return destination
      end

      FileUtils.mkdir_p(destination.dirname)
      temporary = destination.dirname.join(".#{destination.basename}.tmp-#{Process.pid}-#{SecureRandom.hex(6)}")
      begin
        FileUtils.mkdir(temporary)
        names.each { |name| File.binwrite(temporary.join(name), File.binread(bound_dir.join(name))) }
        File.rename(temporary, destination)
      ensure
        FileUtils.remove_entry(temporary) if temporary.exist?
      end
      destination
    end

    def gate_result(operation, kind, payload)
      {
        "contract_version" => VERSION,
        "status" => "WAITING",
        "operation" => operation_summary(operation),
        "artifact" => {"artifact_ids" => [], "kind" => kind},
        "pipeline" => payload.fetch("operation"),
        "gate" => {"state" => payload.fetch("state"), "kind" => "HUMAN_REVIEW"},
        "route" => {
          "state" => payload.fetch("state"),
          "artifact_type" => kind,
          "evidence" => payload.fetch("evidence"),
          "human_review" => payload.fetch("human_review"),
          "commands" => [],
          "warnings" => []
        },
        "diagnostic" => nil
      }
    end

    def protocol_error(operation, message)
      diagnostic(operation, "SOURCE_PROGRESSION_PROTOCOL_ERROR", message, owner: "af-data-pipeline")
    end

    def diagnostic(operation, code, message, owner: "adventure-finder")
      {
        "contract_version" => VERSION,
        "status" => "REJECTED",
        "operation" => operation ? operation_summary(operation) : {
          "operation_id" => nil, "revision" => nil, "document_sha256" => nil
        },
        "artifact" => nil,
        "pipeline" => nil,
        "gate" => {"state" => code, "kind" => "BLOCKED"},
        "route" => nil,
        "diagnostic" => {
          "owner" => owner,
          "code" => code,
          "message" => message,
          "next_action" => IngestOperationRouting.recovery_action(code, owner:)
        }
      }
    end

    def operation_summary(operation)
      {
        "operation_id" => operation.fetch("operation_id"),
        "revision" => operation.fetch("revision"),
        "document_sha256" => IngestOperation.digest(operation)
      }
    end

    def parse_json(value)
      JSON.parse(value) unless value.to_s.strip.empty?
    rescue JSON::ParserError
      nil
    end

    def canonical(value)
      IngestOperation.canonical(value)
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end

    def safe_relative?(value)
      value.is_a?(String) && !value.empty? && !value.start_with?("/") &&
        !value.include?("\\") && !value.include?(":") &&
        value.split("/", -1).none? { |part| ["", ".", ".."].include?(part) }
    end

    def descendant?(path, ancestor)
      path.to_s == ancestor.to_s || path.to_s.start_with?(ancestor.to_s + File::SEPARATOR)
    end
  end
end
