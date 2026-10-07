# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "pathname"
require "tempfile"
require_relative "adventure_finder_ingest_operation_store"

module AdventureFinderWorkspace
  # Read-only composition of one durable ingest operation with the pipeline's
  # public af-ingest-next --operation-input seam.
  class IngestOperationRouting
    VERSION = "adventurefinder-ingest-operation-routing/v0.1"
    PIPELINE_INPUT_VERSION = "af-ingest-routing-input/v0.1"
    PIPELINE_RESULT_VERSION = "af-ingest-routing-result/v0.1"
    PIPELINE_ERROR_VERSION = "af-ingest-routing-error/v0.1"

    class CommandRunner
      Result = Struct.new(:stdout, :stderr, :status, keyword_init: true)

      def capture(environment, *argv)
        stdout, stderr, status = Open3.capture3(environment, *argv)
        Result.new(stdout:, stderr:, status:)
      end
    end

    attr_reader :store, :project_root, :front_door_root, :pipeline_root,
                :source_root, :catalog_root, :runner

    def initialize(
      store:,
      project_root: ENV.fetch("AF_PROJECT_ROOT", "/Users/davidnorris/code/adventure-finder-components"),
      front_door_root: ENV.fetch("AF_ADVENTURE_FINDER_ROOT", File.expand_path("..", __dir__)),
      pipeline_root: nil,
      source_root: nil,
      catalog_root: nil,
      runner: CommandRunner.new
    )
      @store = store
      @project_root = Pathname(project_root).expand_path
      @front_door_root = Pathname(front_door_root).expand_path
      @pipeline_root = Pathname(
        pipeline_root || ENV["AF_DATA_PIPELINE_ROOT"] || @project_root.join("af-data-pipeline")
      ).expand_path
      @source_root = Pathname(source_root || @project_root.join("md-for-llm-book-content")).expand_path
      @catalog_root = Pathname(catalog_root || @project_root.join("af-xlsx-data-sources")).expand_path
      @runner = runner
    end

    def compose(operation_id)
      stored = store.inspect(operation_id)
      return operation_diagnostic(stored) unless stored["operation_status"] == "VALID"

      operation = stored.fetch("operation")
      operation_sha = IngestOperation.digest(operation)
      return waiting_for_artifact(operation) if operation.fetch("artifacts").empty?

      target = target_for(operation)
      return target if target["contract_version"] == VERSION

      projection = projection_for(operation, target)
      result = invoke_pipeline(projection, target.fetch("path"))
      current = store.validate!(operation_id)
      unless IngestOperation.digest(current) == operation_sha
        return diagnostic(operation, "OPERATION_CHANGED",
                          "operation advanced while pipeline routing was being inspected")
      end
      return result if result["contract_version"] == VERSION

      compose_result(operation, target, result.fetch("operation"), result.fetch("route"))
    rescue IngestOperationStore::Failure => e
      diagnostic(operation, e.code, e.message.sub(/\A[^:]+: /, ""), operation_id:)
    rescue SystemCallError => e
      diagnostic(operation, "PIPELINE_UNAVAILABLE", "pipeline invocation failed: #{e.class}", operation_id:)
    end

    def render(result, out: $stdout)
      operation = result.fetch("operation")
      out.puts "Ingest operation: #{operation.fetch('operation_id')}"
      out.puts "Revision: #{operation['revision']}" if operation["revision"]
      out.puts "Gate: #{result.dig('gate', 'state')}"
      out.puts "Gate kind: #{result.dig('gate', 'kind')}"
      if (diagnostic = result["diagnostic"])
        out.puts "Diagnostic: #{diagnostic.fetch('code')}: #{diagnostic.fetch('message')}"
        return result
      end

      route = result["route"]
      return result unless route

      render_lines(out, "Evidence", route.fetch("evidence"))
      render_lines(out, "Human review", route.fetch("human_review"))
      render_lines(out, "Warnings", route.fetch("warnings"))
      unless route.fetch("commands").empty?
        out.puts "Next commands (inspection only; nothing was executed):"
        route.fetch("commands").each { |command| out.puts "  - #{command.fetch('command')}" }
      end
      result
    end

    private

    def target_for(operation)
      artifacts = operation.fetch("artifacts")
      selected = artifacts.last
      if selected.fetch("kind") == "editorial_context"
        return waiting(operation, "NEEDS_EDITORIAL_DECISIONS_ARTIFACT",
                       "the latest bound editorial context has no later decisions artifact")
      end

      if selected.fetch("kind") == "editorial_decisions"
        context = artifacts.reverse.find do |candidate|
          candidate["kind"] == "editorial_context" && selected.fetch("inputs").include?(candidate["artifact_id"])
        end
        return diagnostic(operation, "INCOMPLETE_EDITORIAL_BUNDLE",
                          "editorial decisions do not reference a bound editorial context") unless context

        context_path = store.binding_path(operation.fetch("operation_id"), context.fetch("artifact_id"))
        decisions_path = store.binding_path(operation.fetch("operation_id"), selected.fetch("artifact_id"))
        unless context_path.dirname == decisions_path.dirname &&
               context_path.basename.to_s == "editorial_context.json" &&
               decisions_path.basename.to_s == "editorial_decisions.yml"
          return diagnostic(operation, "INCOMPLETE_EDITORIAL_BUNDLE",
                            "editorial bundle members are not the canonical pair in one directory")
        end
        return {
          "kind" => "editorial_bundle",
          "path" => context_path.dirname.to_s,
          "artifact_ids" => [context.fetch("artifact_id"), selected.fetch("artifact_id")],
          "binding" => {
            "kind" => "editorial_bundle",
            "members" => [
              member_binding(context, "editorial_context.json"),
              member_binding(selected, "editorial_decisions.yml")
            ]
          }
        }
      end

      {
        "kind" => selected.fetch("kind"),
        "path" => store.binding_path(operation.fetch("operation_id"), selected.fetch("artifact_id")).to_s,
        "artifact_ids" => [selected.fetch("artifact_id")],
        "binding" => {
          "kind" => "file",
          "sha256" => selected.dig("content", "sha256"),
          "bytes" => selected.dig("content", "bytes")
        }
      }
    end

    def member_binding(artifact, filename)
      {
        "filename" => filename,
        "sha256" => artifact.dig("content", "sha256"),
        "bytes" => artifact.dig("content", "bytes")
      }
    end

    def projection_for(operation, target)
      base = operation.fetch("base_catalog")
      locator = base.dig("content", "locator")
      unless locator["root"] == "catalog"
        raise IngestOperationStore::Failure.new(
          "INCOMPATIBLE_BASE_LOCATOR", "pipeline routing requires the frozen base beneath the catalog root"
        )
      end
      selection = base.fetch("selection")
      {
        "schema_version" => PIPELINE_INPUT_VERSION,
        "operation" => operation_summary(operation),
        "artifact" => target.fetch("binding"),
        "source" => {
          "source_id" => choice_value(operation, "source_id"),
          "canonical_markdown" => nil,
          "edition" => choice_value(operation, "edition"),
          "pagination_authority" => choice_value(operation, "pagination_authority"),
          "publisher" => choice_value(operation, "publisher")
        },
        "base_catalog" => {
          "filename" => locator.fetch("path"),
          "sha256" => base.dig("content", "sha256"),
          "bytes" => base.dig("content", "bytes"),
          "selection_method" => selection.fetch("method"),
          "project_state_sha256" => selection["project_state"]&.dig("content", "sha256")
        },
        "policy" => operation["policy"]&.slice(
          "policy_id", "policy_version", "definition_sha256", "selected_values"
        )
      }
    end

    def choice_value(operation, key)
      operation.dig("source_declaration", key, "value")
    end

    def operation_summary(operation)
      {
        "contract_version" => operation.fetch("contract_version"),
        "operation_id" => operation.fetch("operation_id"),
        "revision" => operation.fetch("revision"),
        "document_sha256" => IngestOperation.digest(operation)
      }
    end

    def invoke_pipeline(projection, artifact_path)
      executable = pipeline_root.join("bin", "af-ingest-next")
      unless executable.file? && executable.executable?
        return diagnostic_from_projection(projection, "PIPELINE_UNAVAILABLE",
                                          "public pipeline executable is unavailable: #{executable}")
      end

      Tempfile.create(["af-ingest-routing-", ".json"]) do |file|
        file.binmode
        file.write(JSON.pretty_generate(canonical(projection)) + "\n")
        file.flush
        file.fsync
        argv = [
          executable.to_s,
          artifact_path,
          "--source-root", source_root.to_s,
          "--catalog-root", catalog_root.to_s,
          "--operation-input", file.path,
          "--json"
        ]
        response = runner.capture(
          {"AF_PROJECT_ROOT" => project_root.to_s, "AF_ADVENTURE_FINDER_ROOT" => front_door_root.to_s},
          *argv
        )
        parsed = parse_json(response.stdout)
        if parsed
          validation = validate_pipeline_result(parsed, projection, response.status.exitstatus)
          return validation if validation["contract_version"] == VERSION

          return sanitize_ephemeral(validation, file.path)
        end

        error = parse_json(response.stderr)
        if error.is_a?(Hash) && error["schema_version"] == PIPELINE_ERROR_VERSION && error["error"].is_a?(Hash)
          return sanitize_ephemeral(
            diagnostic_from_projection(
              projection,
              error.dig("error", "code") || "PIPELINE_REJECTED",
              error.dig("error", "message") || "pipeline rejected the operation input"
            ),
            file.path
          )
        end
        message = response.stderr.to_s.strip
        message = "pipeline exited #{response.status.exitstatus} without a versioned response" if message.empty?
        sanitize_ephemeral(diagnostic_from_projection(projection, "PIPELINE_FAILURE", message), file.path)
      end
    end

    def validate_pipeline_result(result, projection, exit_status)
      expected_keys = %w[operation route schema_version]
      unless result.is_a?(Hash) && result.keys.sort == expected_keys &&
             result["schema_version"] == PIPELINE_RESULT_VERSION
        return diagnostic_from_projection(projection, "PIPELINE_PROTOCOL_ERROR",
                                          "pipeline returned an incompatible result contract")
      end
      summary = result["operation"]
      expected_summary = projection.fetch("operation").merge(
        "routing_input_sha256" => Digest::SHA256.hexdigest(JSON.generate(canonical(projection)))
      ).except("contract_version")
      unless summary == expected_summary
        return diagnostic_from_projection(projection, "PIPELINE_PROTOCOL_ERROR",
                                          "pipeline result does not match the operation projection")
      end
      route = result["route"]
      unless valid_route?(route)
        return diagnostic_from_projection(projection, "PIPELINE_PROTOCOL_ERROR",
                                          "pipeline returned a malformed route")
      end
      allowed_exit = exit_status.zero? || (exit_status == 2 && route["state"].start_with?("BLOCKED"))
      unless allowed_exit
        return diagnostic_from_projection(projection, "PIPELINE_FAILURE",
                                          "pipeline exited #{exit_status} for route #{route['state']}")
      end
      result
    end

    def valid_route?(route)
      return false unless route.is_a?(Hash) && route.keys.sort ==
                          %w[artifact_type commands evidence human_review state warnings]
      return false unless route["state"].is_a?(String) && !route["state"].empty?
      return false unless route["artifact_type"].is_a?(String) && !route["artifact_type"].empty?

      lines_valid = %w[evidence human_review warnings].all? do |key|
        route[key].is_a?(Array) && route[key].all? { |value| value.is_a?(String) }
      end
      commands_valid = route["commands"].is_a?(Array) && route["commands"].all? do |command|
        command.is_a?(Hash) && command.keys.sort == %w[command cwd] &&
          command.values.all? { |value| value.is_a?(String) }
      end
      lines_valid && commands_valid
    end

    def compose_result(operation, target, pipeline_operation, route)
      {
        "contract_version" => VERSION,
        "status" => "ROUTED",
        "operation" => operation_summary(operation).except("contract_version"),
        "artifact" => {"artifact_ids" => target.fetch("artifact_ids"), "kind" => target.fetch("kind")},
        "pipeline" => pipeline_operation,
        "gate" => gate_for(route.fetch("state")),
        "route" => route,
        "diagnostic" => nil
      }
    end

    def gate_for(state)
      kind = if state.start_with?("BLOCKED")
               "BLOCKED"
             elsif state.start_with?("NEEDS")
               "HUMAN_REVIEW"
             elsif state.start_with?("READY")
               "OPERATOR_ACTION"
             else
               "OBSERVED"
             end
      {"state" => state, "kind" => kind}
    end

    def waiting_for_artifact(operation)
      waiting(operation, "NEEDS_FIRST_COMPONENT_ARTIFACT",
              "the operation is valid and intentionally has no bound component artifact")
    end

    def waiting(operation, state, message)
      {
        "contract_version" => VERSION,
        "status" => "WAITING",
        "operation" => operation_summary(operation).except("contract_version"),
        "artifact" => nil,
        "pipeline" => nil,
        "gate" => {"state" => state, "kind" => "WAITING_FOR_ARTIFACT"},
        "route" => nil,
        "diagnostic" => {"owner" => "adventure-finder", "code" => state, "message" => message}
      }
    end

    def operation_diagnostic(inspection)
      if inspection["operation_status"] == "ABSENT"
        return diagnostic(nil, "OPERATION_ABSENT", "ingest operation does not exist",
                          operation_id: inspection.fetch("operation_id"))
      end
      finding = inspection.fetch("findings").first
      diagnostic(inspection["operation"], finding.fetch("code"), finding.fetch("message"),
                 operation_id: inspection.fetch("operation_id"))
    end

    def diagnostic_from_projection(projection, code, message)
      operation = projection.fetch("operation")
      diagnostic(nil, code, message, operation_id: operation.fetch("operation_id"),
                 operation_summary: operation.except("contract_version"), owner: "af-data-pipeline")
    end

    def diagnostic(operation, code, message, operation_id: nil, operation_summary: nil,
                   owner: "adventure-finder")
      summary = operation_summary || if operation
                                       self.operation_summary(operation).except("contract_version")
                                     else
                                       {"operation_id" => operation_id, "revision" => nil,
                                        "document_sha256" => nil}
                                     end
      {
        "contract_version" => VERSION,
        "status" => "REJECTED",
        "operation" => summary,
        "artifact" => nil,
        "pipeline" => nil,
        "gate" => {"state" => code, "kind" => "BLOCKED"},
        "route" => nil,
        "diagnostic" => {"owner" => owner, "code" => code, "message" => message}
      }
    end

    def sanitize_ephemeral(value, path)
      case value
      when Hash then value.to_h { |key, item| [key, sanitize_ephemeral(item, path)] }
      when Array then value.map { |item| sanitize_ephemeral(item, path) }
      when String then value.gsub(path, "<operation-input>")
      else value
      end
    end

    def parse_json(value)
      JSON.parse(value) unless value.to_s.strip.empty?
    rescue JSON::ParserError
      nil
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end

    def render_lines(out, label, lines)
      return if lines.empty?

      out.puts "#{label}:"
      lines.each { |line| out.puts "  - #{line}" }
    end
  end
end
