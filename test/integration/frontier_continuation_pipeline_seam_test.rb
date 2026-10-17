# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "stringio"
require_relative "../../lib/adventure_finder_final_promotion"
require_relative "../support/ig19_git_fixture"

# Exercise the displayed handoff with real public AFDP validators and prebuilt
# synthetic Git bytes. No producer success or package validation is stubbed.
class FrontierContinuationPipelineSeamTest < Minitest::Test
  # Reflect the exit code returned by the real public CLI entrypoint.
  Status = Struct.new(:exitstatus) do
    def success? = exitstatus.zero?
  end

  # Keep semantic proofs in one process while exercising the real public CLI
  # contract. Existing process seams remain covered by the promotion suite.
  class PublicPipelineRunner < AdventureFinderWorkspace::FinalPromotion::ComponentRunner
    # Dispatch package/adoption arguments to their public entrypoints and return
    # their actual stdout, stderr and exit code. Unexpected commands raise.
    def capture(argv, chdir:)
      command = File.basename(argv.fetch(1))
      return super if command == "af-project-state"
      owner = {"af-final-release-package" => AfDataPipeline::FinalReleasePackage,
               "af-final-release-adoption" => AfDataPipeline::FinalReleaseAdoption}.fetch(command)
      out = StringIO.new
      err = StringIO.new
      code = owner.run(argv.drop(2), out:, err:)
      self.class::Result.new(stdout: out.string, stderr: err.string, status: Status.new(code))
    end
  end

  # Load the selected component contract; an unavailable checkout is a skip.
  def setup
    @pipeline = ENV.fetch("AF_DATA_PIPELINE_ROOT", "/Users/davidnorris/code/adventure-finder-components/af-data-pipeline")
    skip "composed pipeline checkout is unavailable" unless File.file?(File.join(@pipeline, "lib/af_data_pipeline.rb"))
    $LOAD_PATH.unshift(File.join(@pipeline, "lib")) unless $LOAD_PATH.include?(File.join(@pipeline, "lib"))
    require "af_data_pipeline"
    require File.join(@pipeline, "test/support/standing_bulk_score_release_fixture")
  end

  # A requested residual branch stops before adoption; invalid/stale public
  # requests and package inputs yield structured refusals without changing bytes.
  def test_requested_branch_and_invalid_inputs_preserve_original_authority
    with_package do |root, owner, inputs, package, request, catalog|
      before = protected_bytes(owner, catalog)
      code, output = review(root, inputs, package, "FRONTIER\n")
      assert_equal 3, code
      assert_includes output, "leave this promotion unapproved"
      assert_includes output, "prepare --request REQUEST.json --output PACKET_DIR"
      assert_equal before, protected_bytes(owner, catalog)
      refute File.exist?(File.join(root, "promotion/adoption-decision.json"))

      original_request = File.binread(request)
      original_inputs = File.binread(inputs)
      original_package = File.binread(package)
      mutations = [
        -> { rewrite(request) { |doc| doc.delete("successor_version") } },
        -> { rewrite(request) { |doc| doc["rubric"]["sha256"] = "0" * 64 } },
        -> { rewrite(request) { |doc| doc["successor_version"] = "0.1" } },
        -> { rewrite(inputs) { |doc| doc["release_manifest_path"] += ".missing" } },
        -> { rewrite(package) { |doc| doc["package_id"] = "0" * 64 } },
        -> { rewrite(inputs) { |doc| doc["frontier_result_path"] = "/unvalidated-result.json" } }
      ]
      mutations.each do |mutation|
        mutation.call
        all_bytes = Ig19GitFixture.inventory(root)
        out = StringIO.new
        err = StringIO.new
        assert_equal 2, AfDataPipeline::FrontierResidualScoring.run(
          ["prepare", "--request", request, "--output", File.join(root, "invalid-packet")], out:, err:)
        refusal = JSON.parse(err.string)
        assert_equal "BLOCKED", refusal.fetch("status")
        refute_empty refusal.fetch("reason")
        assert_empty out.string
        assert_equal all_bytes, Ig19GitFixture.inventory(root)
        File.binwrite(request, original_request)
        File.binwrite(inputs, original_inputs)
        File.binwrite(package, original_package)
      end

      # The front door must respect the actual owner validator's stale refusal.
      rewrite(inputs) { |doc| doc["release_manifest_path"] += ".missing" }
      all_bytes = Ig19GitFixture.inventory(root)
      assert_raises(AdventureFinderWorkspace::Error) { review(root, inputs, package, "APPROVE\n") }
      assert_equal all_bytes, Ig19GitFixture.inventory(root)
      File.binwrite(inputs, original_inputs)
      code, output = review(root, inputs, package, "APPROVE\n")
      assert_equal 0, code
      assert_includes output, "Final promotion: PROMOTED."
    end
  end

  # Real prepare/apply/verify produces a separately attributed candidate. An
  # exact approval for the original cannot authorize it; one new approval can.
  def test_applied_branch_needs_new_package_and_exact_final_approval
    with_package do |root, owner, inputs, package, request, catalog|
      original_request = File.join(root, "original-adoption-request.json")
      approval = File.join(root, "original-approval.json")
      AfDataPipeline::FinalReleaseAdoption.prepare!(inputs_path: inputs, package_path: package, output_path: original_request)
      AfDataPipeline::FinalReleaseAdoption.decide!(inputs_path: inputs, package_path: package,
        request_path: original_request, output_path: approval, decision: "APPROVE", decided_by: "Fixture Operator")
      before = protected_bytes(owner, catalog)
      packet = File.join(root, "packet")
      result = File.join(root, "result")
      service = AfDataPipeline::FrontierResidualScoring
      assert_equal "READY", service.prepare!(request_path: request, output_dir: packet).status
      assert_equal 2, JSON.parse(File.binread(File.join(packet, "handoff.json"))).fetch("targets").length
      returned = JSON.parse(File.binread(File.join(packet, "return-template.json")))
      returned.fetch("records").each do |row|
        row.merge!("proposed_value" => 4, "reason" => "Synthetic structural evidence, fixture section 1.",
          "source_references" => ["authority:source:fixture.md"])
      end
      returned["return_id"] = AfDataPipeline::StandingBulkScorePolicy.digest(returned.except("return_id"))
      return_path = File.join(root, "return.json")
      write(return_path, returned)
      assert_equal "APPLIED", service.apply!(request_path: request, packet_dir: packet, return_path:, output_dir: result).status
      assert_equal "APPLIED", service.verify!(request_path: request, packet_dir: packet, output_dir: result).status
      assert_equal before, protected_bytes(owner, catalog), "residual branch silently promoted or changed original evidence"

      derived_inputs = File.join(result, "package-inputs.json")
      derived_package = File.join(root, "derived-package.json")
      derived = AfDataPipeline::FinalReleasePackage.prepare!(inputs_path: derived_inputs, output_path: derived_package).package
      assert_equal "ig17f_derived", derived.dig("candidate", "selection")
      assert_equal "frontier_manual", derived.dig("candidate", "frontier", "authority")
      original = JSON.parse(File.binread(package))
      refute_equal original.dig("candidate", "selected"), derived.dig("candidate", "selected")
      refute_equal original.fetch("package_id"), derived.fetch("package_id")
      assert_equal original.dig("release", "counts"), derived.dig("release", "counts")
      assert_equal 3, review(root, derived_inputs, derived_package, "").first
      adopted_request = File.join(root, "promotion/adoption-request.json")
      all_bytes = Ig19GitFixture.inventory(root)
      assert_raises(AfDataPipeline::ValidationError) do
        AfDataPipeline::FinalReleaseAdoption.adopt!(inputs_path: derived_inputs, package_path: derived_package,
          request_path: adopted_request, approval_path: approval, result_path: File.join(root, "forbidden-result.json"))
      end
      assert_equal all_bytes, Ig19GitFixture.inventory(root)
      assert_equal before, protected_bytes(owner, catalog)
      code, output = review(root, derived_inputs, derived_package, "APPROVE\n")
      assert_equal 0, code
      assert_includes output, "authority=frontier_manual"
      refute_includes output, "prepare --request REQUEST.json"
      decision = JSON.parse(File.binread(File.join(root, "promotion/adoption-decision.json")))
      assert_equal derived.fetch("package_id"), decision.fetch("package_id")
      assert_equal 1, output.scan("Type APPROVE").length
    end
  end

  # Invalid returns write nothing; an explicit decline keeps the original
  # candidate and gap authority. A validated disposition cannot be chained.
  def test_invalid_return_and_decline_do_not_become_local_values_or_chain
    with_package do |root, owner, inputs, package, request, catalog|
      service = AfDataPipeline::FrontierResidualScoring
      packet = File.join(root, "packet")
      result = File.join(root, "declined")
      service.prepare!(request_path: request, output_dir: packet)
      returned = File.join(root, "invalid-return.json")
      write(returned, {"schema_version" => "unsupported"})
      all_bytes = Ig19GitFixture.inventory(root)
      assert_raises(AfDataPipeline::ValidationError) do
        service.apply!(request_path: request, packet_dir: packet, return_path: returned, output_dir: result)
      end
      assert_equal all_bytes, Ig19GitFixture.inventory(root)
      before = protected_bytes(owner, catalog)
      assert_equal "DECLINED", service.decline!(request_path: request, packet_dir: packet, output_dir: result).status
      assert_equal "DECLINED", service.verify!(request_path: request, packet_dir: packet, output_dir: result).status
      declined_inputs = File.join(result, "package-inputs.json")
      declined_package = File.join(root, "declined-package.json")
      declined = AfDataPipeline::FinalReleasePackage.prepare!(inputs_path: declined_inputs, output_path: declined_package).package
      original = JSON.parse(File.binread(package))
      assert_equal original.dig("candidate", "selected"), declined.dig("candidate", "selected")
      assert_equal original.dig("release", "counts"), declined.dig("release", "counts")
      assert_equal 0, declined.dig("candidate", "frontier", "writes")
      code, output = review(root, declined_inputs, declined_package, "")
      assert_equal 3, code
      assert_includes output, "Optional frontier result: DECLINED"
      assert_includes output, "Frontier supplements cannot chain"
      refute_includes output, "prepare --request REQUEST.json"
      rewrite(request) { |doc| doc["original_package_inputs_path"] = declined_inputs; doc["original_package_path"] = declined_package }
      all_bytes = Ig19GitFixture.inventory(root)
      error = assert_raises(AfDataPipeline::ValidationError) { service.prepare!(request_path: request, output_dir: File.join(root, "chained")) }
      assert_includes error.message, "cannot chain"
      assert_equal all_bytes, Ig19GitFixture.inventory(root)
      assert_equal before, protected_bytes(owner, catalog)
    end
  end

  private

  # Build the unchanged owner recipe cold at its fixed ZIP time and qualify its
  # catalog against F2's sealed standing fixture. Yield public paths; errors propagate.
  def with_package
    Dir.mktmpdir("frontier-seam-") do |root|
      caches = [CompatibilityAmcFixture::WORKBOOK_BYTES_CACHE, StagedScoringFixture::TEMPLATE_CACHE,
        StandingBulkScoreReleaseFixture::FIXTURE_CACHE, StandingBulkScoreReleaseFixture::ISSUED_AUTHORITY_CACHE]
      previous = caches.map(&:dup)
      caches.each(&:clear)
      owner = Ig19GitFixture.with_fixed_zip_time { StandingBulkScoreReleaseFixture.new(root: File.join(root, "owner")) }
      catalog = Ig19GitFixture.load("standing", File.join(root, "catalog"))
      catalog.specification.fetch("files").each_key do |name|
        next if name.start_with?(".git/")
        assert_equal File.binread(File.join(owner.root, name)), File.binread(File.join(catalog.root, name)), name
      end
      owner.mutate_policy { |policy| policy.fetch("scope")["dimensions"] = ["Seriousness"] }
      owner.release
      inputs = File.join(root, "package-inputs.json")
      write(inputs, {"schema_version" => AfDataPipeline::FinalReleasePackage::INPUT_SCHEMA,
        "release_inputs_path" => owner.inputs_path, "release_manifest_path" => File.join(owner.output_dir, "release-accounting.json"),
        "catalog_repository_root" => catalog.root, "current_project_state_path" => File.join(catalog.root, "PROJECT_STATE.yml"),
        "frontier_result_path" => nil})
      package = File.join(root, "package.json")
      prepared = AfDataPipeline::FinalReleasePackage.prepare!(inputs_path: inputs, output_path: package).package
      assert prepared.dig("readiness", "ready")
      assert_equal 4, prepared.dig("release", "population", "residual_gap_metrics")
      rubric = File.join(root, "rubric.txt")
      File.binwrite(rubric, "Synthetic structural test rubric.\n")
      request = File.join(root, "request.json")
      write(request, {"schema_version" => AfDataPipeline::FrontierResidualScoring::REQUEST_SCHEMA,
        "original_package_inputs_path" => inputs, "original_package_path" => package,
        "rubric" => {"id" => "Synthetic rubric", "path" => rubric, **AfDataPipeline::StandingBulkScorePolicy.file_binding(rubric)},
        "successor_version" => "0.3"})
      yield root, owner, inputs, package, request, catalog
    ensure
      catalog&.close
      caches&.zip(previous)&.each { |cache, saved| cache.replace(saved) }
    end
  end

  # Run the real public CLIs at the front door; no fake validation result is used.
  # Return exit code/output, propagating the front door's classified refusals.
  def review(root, inputs, package, answer)
    output = StringIO.new
    door = AdventureFinderWorkspace::FinalPromotion.new(front_door_root: File.join(root, "front"),
      project_root: root, pipeline_root: @pipeline, component_runner: PublicPipelineRunner.new,
      input: StringIO.new(answer), out: output)
    [door.run(inputs_path: inputs, package_path: package, approver: "Fixture Operator",
      operation_dir: File.join(root, "promotion")), output.string]
  end

  # Return exact protected owner/catalog identities, including Git metadata.
  def protected_bytes(owner, catalog)
    [Ig19GitFixture.inventory(owner.root), Ig19GitFixture.inventory(catalog.root)]
  end

  # Write canonical fixture JSON; filesystem errors propagate.
  def write(path, document)
    File.binwrite(path, AfDataPipeline::StagedScoringAuthority.document_bytes(document))
  end

  # Mutate only caller-selected disposable JSON for a negative control.
  def rewrite(path)
    document = JSON.parse(File.binread(path))
    yield document
    write(path, document)
  end
end
