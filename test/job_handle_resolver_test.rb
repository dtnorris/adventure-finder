# frozen_string_literal: true

require "minitest/autorun"
require "adventure_finder_job_handle_resolver"

class JobHandleResolverTest < Minitest::Test
  def test_resolves_compact_dimension_and_exact_canonical_handles
    resolver = resolver_for(
      "production-batch-039-adv0946-structural-openness",
      "production-batch-039-adv0946-ee"
    )

    assert_equal "production-batch-039-adv0946-structural-openness", resolver.resolve("0946-openness")
    assert_equal "production-batch-039-adv0946-structural-openness", resolver.resolve("0946-structural-openness")
    assert_equal "production-batch-039-adv0946-ee", resolver.resolve("ADV-0946-ee")
    assert_equal "production-batch-039-adv0946-ee",
                 resolver.resolve("production-batch-039-adv0946-ee")
  end

  def test_ambiguous_adventure_and_compact_handles_fail_closed
    resolver = resolver_for(
      "first-adv0946-structural-openness",
      "second-adv0946-visual-openness"
    )

    error = assert_raises(AdventureFinderWorkspace::Error) { resolver.resolve("0946-openness") }
    assert_includes error.message, "ambiguous"
    error = assert_raises(AdventureFinderWorkspace::Error) { resolver.resolve("ADV-0946") }
    assert_includes error.message, "ambiguous"
  end

  def test_unknown_handle_fails_closed
    error = assert_raises(AdventureFinderWorkspace::Error) do
      resolver_for("opaque-job").resolve("0946-openness")
    end
    assert_includes error.message, "unknown AdventureFinder job handle"
  end

  private

  def resolver_for(*ids)
    jobs = ids.map { |id| { "job_id" => id, "group_id" => "ADV-0946" } }
    AdventureFinderWorkspace::JobHandleResolver.new("jobs" => jobs)
  end
end
