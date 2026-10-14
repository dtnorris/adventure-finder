# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "rbconfig"
require "shellwords"
require "tempfile"
require "time"
require_relative "adventure_finder_workspace"

module AdventureFinderWorkspace
  # Presents one validated final-release package and delegates its exact human
  # decision and catalog mutation to the pipeline-owned adoption transaction.
  class FinalPromotion
    PACKAGE_SCHEMA = "af-final-release-package/v0.1"
    REQUEST_SCHEMA = "af-final-release-adoption-request/v0.1"
    DECISION_SCHEMA = "af-final-release-adoption-decision/v0.1"
    RESULT_SCHEMA = "af-final-release-adoption-result/v0.1"
    COORDINATION_SCHEMA = "adventurefinder-final-promotion-decision/v0.1"
    SHA256 = /\A[0-9a-f]{64}\z/

    class ComponentRunner
      Result = Data.define(:stdout, :stderr, :status)

      def capture(argv, chdir:)
        stdout, stderr, status = Open3.capture3(*argv, chdir:)
        Result.new(stdout:, stderr:, status:)
      end
    end

    def initialize(front_door_root:, project_root:, pipeline_root: nil,
                   component_runner: ComponentRunner.new, input: $stdin,
                   out: $stdout, err: $stderr, clock: -> { Time.now.utc })
      @front_door_root = Pathname(front_door_root).expand_path.cleanpath
      @project_root = Pathname(project_root).expand_path.cleanpath
      @pipeline_root = Pathname(
        pipeline_root || ENV.fetch("AF_DATA_PIPELINE_ROOT", @project_root.join("af-data-pipeline").to_s)
      ).expand_path.cleanpath
      @runner = component_runner
      @input = input
      @out = out
      @err = err
      @clock = clock
    end

    def run(inputs_path:, package_path:, approver:, operation_dir: nil, preview: false)
      approver = approver.to_s.strip
      raise Error, "--approver must identify the human decision owner" if approver.empty?

      inputs_path = File.expand_path(inputs_path)
      package_path = File.expand_path(package_path)
      package, package_status = validate_package(inputs_path, package_path)
      validate_package_shape!(package)

      unless package.dig("readiness", "ready")
        render_review(package)
        @out.puts "Final promotion: BLOCKED by pipeline readiness."
        return 2
      end
      unless package_status.zero?
        raise Error, "pipeline validator returned #{package_status} for a promotion-ready package"
      end

      operation_dir ||= @front_door_root.join("operations", "final-promotions", package.fetch("package_id")).to_s
      operation_dir = Pathname(operation_dir).expand_path.cleanpath
      FileUtils.mkdir_p(operation_dir)
      paths = operation_paths(operation_dir)
      request = if File.file?(paths.fetch(:request))
                  read_json(paths.fetch(:request), "pipeline adoption request")
                else
                  prepare_request(inputs_path, package_path, paths.fetch(:request))
                end
      validate_request_shape!(request, package)

      render_review(package, request:)
      render_preview(package) if preview
      render_frontier_status(package)

      if File.file?(paths.fetch(:decision))
        validate_coordination!(paths, package, request, approver)
      else
        disposition = request_decision(request)
        return awaiting_decision(paths) unless disposition

        decision = create_decision(inputs_path, package_path, paths.fetch(:request), paths.fetch(:decision),
                                   approver, disposition)
        write_coordination(paths.fetch(:coordination), package, request, decision, paths.fetch(:decision), approver)
      end

      result = adopt(inputs_path, package_path, paths)
      case result.fetch("status")
      when "DECLINED"
        @out.puts "Final promotion: DECLINED. Catalog state is unchanged."
        print_operation_persistence(paths)
        3
      when "PROMOTED", "ALREADY_PROMOTED"
        verify_public_result!(result, request)
        @out.puts "Final promotion: #{result.fetch('status')}."
        print_persistence(result, paths)
        0
      when "NO_APPROVAL"
        @out.puts "Final promotion: NO_APPROVAL. Catalog state is unchanged."
        3
      else
        raise Error, "pipeline returned unrecognized final-promotion status #{result['status'].inspect}"
      end
    end

    private

    def pipeline_command(name)
      path = @pipeline_root.join("bin", name)
      raise Error, "pipeline command is missing: #{path}" unless path.file?

      [RbConfig.ruby, path.to_s]
    end

    def validate_package(inputs_path, package_path)
      result = @runner.capture(
        [*pipeline_command("af-final-release-package"), "validate", "--inputs", inputs_path, "--package", package_path],
        chdir: @pipeline_root.to_s
      )
      document = parse_json(result.stdout, "pipeline final-release package")
      if !result.status.success? && document.nil?
        component_failure!("pipeline final-release validation", result)
      end
      [document, result.status.exitstatus]
    end

    def prepare_request(inputs_path, package_path, request_path)
      result = @runner.capture(
        [*pipeline_command("af-final-release-adoption"), "prepare", "--inputs", inputs_path,
         "--package", package_path, "--output", request_path], chdir: @pipeline_root.to_s
      )
      component_failure!("pipeline adoption-request preparation", result) unless result.status.success?
      parse_json!(result.stdout, "pipeline adoption request")
    end

    def create_decision(inputs_path, package_path, request_path, decision_path, approver, disposition)
      action = disposition == "APPROVE" ? "approve" : "decline"
      result = @runner.capture(
        [*pipeline_command("af-final-release-adoption"), action, "--inputs", inputs_path,
         "--package", package_path, "--request", request_path, "--decided-by", approver,
         "--output", decision_path], chdir: @pipeline_root.to_s
      )
      decision = parse_json!(result.stdout, "pipeline adoption decision")
      expected_exit = disposition == "DECLINE" ? 3 : 0
      component_failure!("pipeline final-promotion decision", result) unless result.status.exitstatus == expected_exit
      unless decision["schema_version"] == DECISION_SCHEMA && decision["decision"] == disposition &&
             decision["decided_by"] == approver
        raise Error, "pipeline decision does not preserve the exact operator disposition and identity"
      end
      decision
    end

    def adopt(inputs_path, package_path, paths)
      result = @runner.capture(
        [*pipeline_command("af-final-release-adoption"), "adopt", "--inputs", inputs_path,
         "--package", package_path, "--request", paths.fetch(:request),
         "--approval", paths.fetch(:decision), "--result", paths.fetch(:result)],
        chdir: @pipeline_root.to_s
      )
      document = parse_json!(result.stdout, "pipeline adoption result")
      status = document["status"]
      accepted_exit = result.status.success? || (%w[DECLINED NO_APPROVAL].include?(status) && result.status.exitstatus == 3)
      component_failure!("pipeline final-release adoption", result) unless accepted_exit
      raise Error, "pipeline adoption result uses an unsupported schema" unless document["schema_version"] == RESULT_SCHEMA

      document
    end

    def validate_package_shape!(package)
      unless package.is_a?(Hash) && package["schema_version"] == PACKAGE_SCHEMA &&
             package["package_id"].to_s.match?(SHA256)
        raise Error, "pipeline validator did not return an exact final-release package"
      end
      %w[readiness candidate release transition compatibility scoring_concurrency provenance].each do |key|
        raise Error, "final-release package is missing #{key}" unless package[key].is_a?(Hash)
      end
    end

    def validate_request_shape!(request, package)
      unless request["schema_version"] == REQUEST_SCHEMA && request["request_id"].to_s.match?(SHA256) &&
             request.dig("package", "package_id") == package["package_id"] &&
             request.dig("candidate", "sha256") == package.dig("candidate", "selected", "sha256")
        raise Error, "pipeline adoption request does not bind the displayed package and candidate"
      end
    end

    def render_review(package, request: nil)
      release = package.fetch("release")
      counts = release.fetch("counts")
      population = release.fetch("population")
      transition = package.fetch("transition")
      delta = transition.fetch("delta")
      base = transition.fetch("original_frozen_base")
      roles = transition.fetch("current_roles")
      candidate = package.dig("candidate", "selected").merge(
        "version" => package.dig("candidate", "version"),
        "filename" => transition.dig("proposed_catalog_head", "filename")
      )
      changed_ids = delta.fetch("changed_cells").map { |row| row.fetch("adventure_id") }.uniq.sort
      gaps = population.fetch("gaps")

      @out.puts "AdventureFinder final-promotion review"
      @out.puts "Package: #{package.fetch('package_id')}"
      @out.puts "Request: #{request.fetch('request_id')}" if request
      @out.puts "Pipeline readiness: #{package.dig('readiness', 'ready') ? 'READY' : 'BLOCKED'}"
      @out.puts "Scoring completeness: #{package.dig('readiness', 'full_scoring') ? 'FULL' : 'AUTHORIZED RELEASE WITH GAPS'}"
      @out.puts "Original frozen base: #{artifact_identity(base)}"
      @out.puts "Current catalog_head: #{identity(roles.fetch('catalog_head'))}"
      @out.puts "Finalized candidate: #{identity(candidate)}"
      @out.puts "Catalog delta: +#{delta.fetch('added_ids').length} / -#{delta.fetch('removed_ids').length} IDs; " \
                "#{changed_ids.length} existing IDs (#{delta.fetch('changed_cells').length} cells) changed"
      @out.puts "  Added: #{list(delta.fetch('added_ids'))}"
      @out.puts "  Removed: #{list(delta.fetch('removed_ids'))}"
      @out.puts "  Changed existing: #{list(changed_ids)}"
      @out.puts "Coverage: #{population.fetch('intended_cases')} cases; " \
                "#{population.fetch('present_metrics')}/#{population.fetch('intended_metrics')} metrics present; " \
                "#{population.fetch('remaining_blank_metrics')} blanks"
      @out.puts "Accepted values: standing directive #{counts.fetch('standing_directive_accepted')}/#{population.fetch('intended_metrics')}; " \
                "individual human #{counts.fetch('individual_human_accepted')}/#{population.fetch('intended_metrics')}; " \
                "IG-16B machine #{counts.fetch('ig16b_machine_accepted')}/#{population.fetch('intended_metrics')}; " \
                "historical V1 mechanical #{counts.fetch('historical_mechanical_accepted')}/#{population.fetch('intended_metrics')}"
      @out.puts "Gaps/exceptions: #{population.fetch('terminal_gap_metrics')}/#{population.fetch('intended_metrics')} terminal gaps; " \
                "#{population.fetch('hard_exceptions')} hard exceptions; " \
                "human HOLD #{counts.fetch('human_hold')}; human REJECT #{counts.fetch('human_reject')}; " \
                "source holds #{counts.fetch('source_holds')}; " \
                "#{counts.fetch('deferred_or_unsupported')}/#{population.fetch('intended_metrics')} deferred/unsupported; " \
                "#{counts.fetch('unscored_or_unresolved')}/#{population.fetch('intended_metrics')} unscored/unresolved; " \
                "#{population.fetch('unresolved_execution_cases')}/#{population.fetch('intended_cases')} unresolved execution cases; " \
                "#{population.fetch('conflicting_targets')} conflicting targets"
      gaps.each { |gap| @out.puts "  #{gap.fetch('candidate_key')}: #{gap.fetch('category')} — #{gap.fetch('reason')}" }
      compatibility = package.fetch("compatibility")
      @out.puts "Compatibility: #{compatibility.fetch('status')} " \
                "(static workbook gate; AFW execution #{compatibility.fetch('afw_execution_compatibility', 'not reported')})"
      @out.puts "  Scope: #{Array(compatibility['consumer_contracts']).join('; ')}; " \
                "canonical IDs=#{compatibility.fetch('canonical_adventure_count', 'not reported')}; " \
                "layout=#{compatibility.fetch('mirror_mode', 'not reported')}"
      concurrency = package.fetch("scoring_concurrency")
      @out.puts "Stale-state classification: #{concurrency.fetch('decision')} (#{concurrency.fetch('reason')})"
      @out.puts "Role change: catalog_head only"
      %w[matcher_authorized_baseline production_dependency_floor].each do |role|
        @out.puts "  #{role}: unchanged (#{identity(roles.fetch(role))})"
      end
      @out.puts "Red-cell preview: optional; use --preview to display its verified locator. It grants no authority."
    end

    def render_preview(package)
      preview = package.dig("release", "preview")
      @out.puts "Verified red-cell preview: #{preview['available'] ? 'available' : 'unavailable'}; authority effect=#{preview.fetch('authority_effect')}"
      manifest_ref = package.dig("provenance", "nodes", "release_manifest")
      return unless preview["available"] && manifest_ref

      manifest = read_json(manifest_ref.fetch("path"), "release manifest")
      binding = manifest.dig("artifacts", "explicit_red_cell_preview")
      raise Error, "release package reports a preview without an owner artifact binding" unless binding

      path = File.join(File.dirname(manifest_ref.fetch("path")), binding.fetch("filename"))
      unless file_binding(path) == binding.slice("sha256", "bytes")
        raise Error, "verified red-cell preview changed after package validation"
      end
      @out.puts "  #{path} (sha256 #{binding.fetch('sha256')}, #{binding.fetch('bytes')} bytes)"
    end

    def render_frontier_status(package)
      frontier = package.dig("candidate", "frontier")
      residual = package.dig("release", "population", "residual_gap_metrics")
      if frontier
        @out.puts "Optional frontier result: #{frontier.fetch('disposition')} #{frontier.fetch('result_id')}; " \
                  "#{frontier.fetch('writes')} writes, #{frontier.fetch('no_writes')} no-writes; authority=#{frontier.fetch('authority')}"
        @out.puts "This candidate was independently revalidated in this new package; no earlier approval transfers."
      elsif residual.positive?
        @out.puts "Optional IG-17F continuation: unavailable because no pipeline-owned packet producer is installed."
        @out.puts "Promotion may continue under the package's independently validated terminal-gap authority."
      end
    end

    def request_decision(request)
      @out.puts
      @out.puts "Type APPROVE to promote the exact package/request above, or DECLINE to record refusal."
      @out.print "> "
      answer = @input.gets&.strip&.upcase
      return answer if %w[APPROVE DECLINE].include?(answer)

      @out.puts "No approval recorded."
      nil
    end

    def awaiting_decision(paths)
      @out.puts "Catalog state is unchanged. Resume with the same command and exact package."
      @out.puts "Prepared request: #{paths.fetch(:request)}"
      print_operation_persistence(paths)
      3
    end

    def write_coordination(path, package, request, decision, decision_path, approver)
      document = {
        "schema_version" => COORDINATION_SCHEMA,
        "package_id" => package.fetch("package_id"),
        "request_id" => request.fetch("request_id"),
        "candidate" => request.fetch("candidate").slice("version", "filename", "sha256", "bytes"),
        "decision" => decision.fetch("decision"),
        "decided_by" => approver,
        "decided_at_utc" => @clock.call.utc.iso8601(6),
        "pipeline_decision" => {"decision_id" => decision.fetch("decision_id"), "path" => File.expand_path(decision_path),
                                **file_binding(decision_path)}
      }
      document["coordination_id"] = digest(document)
      write_once(path, JSON.pretty_generate(document) + "\n", "coordination decision")
    end

    def validate_coordination!(paths, package, request, approver)
      decision = read_json(paths.fetch(:decision), "pipeline adoption decision")
      coordination = read_json(paths.fetch(:coordination), "AdventureFinder coordination decision")
      unless decision["schema_version"] == DECISION_SCHEMA && coordination["schema_version"] == COORDINATION_SCHEMA &&
             coordination["package_id"] == package["package_id"] && coordination["request_id"] == request["request_id"] &&
             coordination["decided_by"] == approver && coordination.dig("pipeline_decision", "decision_id") == decision["decision_id"] &&
             coordination.dig("pipeline_decision").slice("sha256", "bytes") == file_binding(paths.fetch(:decision)) &&
             coordination["coordination_id"] == digest(coordination.except("coordination_id"))
        raise Error, "durable final-promotion decision does not bind this exact package, request and approver"
      end
    end

    def verify_public_result!(result, request)
      expected = request.fetch("candidate").slice("version", "filename", "sha256", "bytes")
      unless result.fetch("candidate") == expected && result.dig("catalog", "catalog_head") == expected &&
             result.dig("catalog", "independent_roles") == request.dig("catalog", "roles").except("catalog_head")
        raise Error, "pipeline result does not prove the reviewed candidate and independent-role invariants"
      end
      manifest = request.dig("catalog", "project_state", "path")
      validation = @runner.capture(
        [*pipeline_command("af-project-state"), "validate", "--manifest", manifest], chdir: @pipeline_root.to_s
      )
      component_failure!("post-adoption project-state observation", validation) unless validation.status.success?
      line = validation.stdout.lines.find { |entry| entry.start_with?("catalog_head: ") }
      unless line&.include?(expected.fetch("version")) && line.include?(expected.fetch("filename")) && line.include?(expected.fetch("sha256"))
        raise Error, "public project-state observation does not match the promoted candidate"
      end
    end

    def print_operation_persistence(paths)
      @out.puts "AdventureFinder coordination persistence (explicit operator choice):"
      @out.puts "  cd #{Shellwords.escape(@front_door_root.to_s)}"
      @out.puts "  git add #{operation_relative_paths(paths).map { |path| Shellwords.escape(path) }.join(' ')}"
      @out.puts "  git commit -m #{Shellwords.escape('Record declined final catalog promotion')}"
      @out.puts "  # push remains an explicit operator choice"
    end

    def print_persistence(result, paths)
      catalog_root = result.dig("catalog", "repository_root")
      candidate = result.fetch("candidate")
      @out.puts "Catalog persistence (explicit operator choice):"
      @out.puts "  cd #{Shellwords.escape(catalog_root)}"
      @out.puts "  git add #{Shellwords.escape('PROJECT_STATE.yml')} #{Shellwords.escape(candidate.fetch('filename'))}"
      @out.puts "  git commit -m #{Shellwords.escape("Update catalog_head to AMC #{candidate.fetch('version')}")}"
      @out.puts "  # push remains an explicit operator choice"
      print_operation_persistence(paths)
    end

    def operation_relative_paths(paths)
      paths.values.select { |path| File.exist?(path) }.map do |path|
        pathname = Pathname(path).expand_path.cleanpath
        begin
          pathname.relative_path_from(@front_door_root).to_s
        rescue ArgumentError
          pathname.to_s
        end
      end
    end

    def operation_paths(root)
      {request: root.join("adoption-request.json").to_s,
       decision: root.join("adoption-decision.json").to_s,
       coordination: root.join("coordination-decision.json").to_s,
       result: root.join("adoption-result.json").to_s}
    end

    def component_failure!(label, result)
      detail = result.stderr.to_s.strip
      detail = result.stdout.to_s.strip if detail.empty?
      detail = "component exited without an error message" if detail.empty?
      raise Error, "#{label} failed: #{detail}"
    end

    def parse_json(output, label)
      JSON.parse(output) unless output.to_s.strip.empty?
    rescue JSON::ParserError => e
      raise Error, "#{label} returned invalid JSON: #{e.message}"
    end

    def parse_json!(output, label)
      parse_json(output, label) || raise(Error, "#{label} returned no JSON")
    end

    def read_json(path, label)
      value = JSON.parse(File.binread(path))
      raise Error, "#{label} must contain a JSON object" unless value.is_a?(Hash)

      value
    rescue SystemCallError, JSON::ParserError => e
      raise Error, "invalid #{label}: #{e.message}"
    end

    # Formats a versioned role or candidate Hash for review; returns a String
    # and raises KeyError when any required identity field is missing.
    def identity(value)
      "#{value.fetch('version')} #{artifact_identity(value)}"
    end

    # Formats an artifact reference Hash, including AFDP's versionless frozen
    # base; returns a String and raises KeyError for missing artifact fields.
    def artifact_identity(value)
      "#{value.fetch('filename')} sha256=#{value.fetch('sha256')} bytes=#{value.fetch('bytes')}"
    end

    def list(values)
      values.empty? ? "none" : values.join(", ")
    end

    def file_binding(path)
      {"sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => File.size(path)}
    end

    def digest(value)
      Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
      when Array then value.map { |entry| canonical(entry) }
      else value
      end
    end

    def write_once(path, bytes, label)
      if File.exist?(path)
        raise Error, "existing #{label} differs" unless File.binread(path) == bytes
        return
      end
      FileUtils.mkdir_p(File.dirname(path))
      Tempfile.create([".final-promotion-", ".json"], File.dirname(path)) do |temp|
        temp.write(bytes)
        temp.flush
        temp.fsync
        File.link(temp.path, path)
      end
    rescue Errno::EEXIST
      raise Error, "#{label} was created concurrently with different bytes" unless File.binread(path) == bytes
    end
  end
end
