# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/adventure_finder_pipeline_data_paths"

# Exercises storage selection/refusal without starting owner implementations.
class PipelineDataPathsTest < Minitest::Test
  Paths = AdventureFinderWorkspace::PipelineDataPaths

  # Builds isolated code/private directories; no owner implementation is run.
  def setup
    @temporary = File.realpath(Dir.mktmpdir("pipeline-data-paths"))
    @code = File.join(@temporary, "af-pipeline")
    @data = File.join(@temporary, "af-pipeline-data")
    FileUtils.mkdir_p([File.join(@code, "bin"), @data])
    File.binwrite(File.join(@code, "bin/af-data"), "fixture command\n")
    File.chmod(0o755, File.join(@code, "bin/af-data"))
  end

  # Removes only this test's disposable files; filesystem errors propagate.
  def teardown
    FileUtils.remove_entry(@temporary)
  end

  # The configured private root is independent from both legacy destinations.
  # Without a selector, each caller retains its historical ownership layout.
  def test_explicit_storage_and_unset_compatibility
    legacy = File.join(@temporary, "front")
    assert_equal Pathname(legacy), Paths.root(code_root: @code, legacy_root: legacy, env: {})
    assert_equal Pathname(@data), Paths.root(code_root: @code, legacy_root: legacy,
      env: {"AF_DATA_PIPELINE_DATA_ROOT" => @data})
    assert_empty Dir.children(@data)
  end

  # Bad selectors fail before creating any output, including overlapping roots,
  # symlink ancestors and a disagreement with retained executable provenance.
  def test_invalid_selectors_refuse_without_writes
    linked = File.join(@temporary, "linked")
    File.symlink(@data, linked)
    ["", "relative", File.join(@temporary, "missing"), @code, @temporary,
     linked, File.join(@data, "..", "af-pipeline-data")].each do |selected|
      assert_raises(AdventureFinderWorkspace::Error) do
        Paths.root(code_root: @code, legacy_root: @code,
          env: {"AF_DATA_PIPELINE_DATA_ROOT" => selected})
      end
      assert_empty Dir.children(@data)
    end
    assert_raises(AdventureFinderWorkspace::Error) do
      Paths.root(code_root: @code, legacy_root: @code,
        env: {"AF_DATA_PIPELINE_DATA_ROOT" => @data, "AF_DATA_PIPELINE_ROOT" => @data})
    end
    File.chmod(0o644, File.join(@code, "bin/af-data"))
    assert_raises(AdventureFinderWorkspace::Error) do
      Paths.root(code_root: @code, legacy_root: @code, env: {"AF_DATA_PIPELINE_DATA_ROOT" => @data})
    end
  end
end
