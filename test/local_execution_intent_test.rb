# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"
require "adventure_finder_local_execution_intent"

class LocalExecutionIntentTest < Minitest::Test
  ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  NOW = Time.iso8601("2026-10-09T10:00:00Z")

  def setup
    @root = Dir.mktmpdir("local-execution-intent-")
    @store = AdventureFinderWorkspace::LocalExecutionIntentStore.new(
      root: @root, clock: -> { NOW }
    )
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_capture_is_replay_safe_and_binds_only_local_ordinary_execution
    first = capture
    second = capture

    assert_equal first, second
    assert_equal "local_only", first.dig("authority", "mode")
    assert_equal true, first.dig("authority", "ordinary_execution")
    %w[retry recovery breaker_acknowledgement remote_capacity paid_resources catalog_adoption].each do |key|
      assert_equal false, first.dig("authority", key)
    end
    assert_equal AdventureFinderWorkspace::LocalExecutionIntentStore.digest(first.except("intent_id")),
                 first.fetch("intent_id")
    assert_equal first, @store.load!(ID)
  end

  def test_changed_operator_plan_sequence_or_execution_locator_is_refused
    capture
    assert_code("LOCAL_EXECUTION_INTENT_CONFLICT") { capture(selected_by: "Someone else") }

    changed = plan
    changed.fetch("sequence").first["job_ids"] = ["different"]
    assert_code("LOCAL_EXECUTION_INTENT_CONFLICT") { capture(capability_plan: changed) }
    assert_code("LOCAL_EXECUTION_INTENT_CONFLICT") { capture(output: File.join(@root, "elsewhere")) }
  end

  def test_corruption_missing_intent_and_invalid_handle_fail_closed
    assert_code("MISSING_LOCAL_EXECUTION_INTENT") { @store.load!(ID) }
    assert_code("INVALID_OPERATION_HANDLE") { @store.load!("not-an-operation") }

    capture
    path = @store.intent_path(ID)
    document = JSON.parse(File.binread(path))
    document.fetch("authority")["remote_capacity"] = true
    File.write(path, JSON.generate(document))
    assert_code("CORRUPT_LOCAL_EXECUTION_INTENT") { @store.load!(ID) }
  end

  private

  def capture(selected_by: "David", capability_plan: plan, output: File.join(@root, "wlo"))
    @store.capture!(
      operation_id: ID, selected_by:, capability_plan:,
      components: {"afw" => File.join(@root, "afw"), "low" => File.join(@root, "low"),
                   "wlo" => File.join(@root, "wlo-repo")},
      workdir: File.join(@root, "afw"), output:
    )
  end

  def plan
    {
      "workload" => {"workload_id" => "operation-a", "plan_id" => "operation-a",
                     "plan_sha256" => "a" * 64},
      "capabilities" => [{"capability_fingerprint" => "b" * 64}],
      "sequence" => [{"step" => 1, "capability_fingerprint" => "b" * 64,
                      "pool_ids" => ["pool"], "job_ids" => ["job"]}]
    }
  end

  def assert_code(code)
    error = assert_raises(AdventureFinderWorkspace::LocalExecutionIntentStore::Failure) { yield }
    assert_equal code, error.code
  end
end
