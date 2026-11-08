# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "support/fixture_artifact_mutation"

# Exercises the actual mutation helper on independent read-only binary bytes.
class FixtureArtifactMutationTest < Minitest::Test
  include FixtureArtifactMutation
  attr_reader :root

  # Checks the actual helper on a fresh 0444 fixture; assertion failures raise.
  def test_read_only_tamper_removal_and_failure_restore_exact_bytes_and_mode
    Dir.mktmpdir("read-only-artifact-") do |directory|
      @root = directory
      path = File.join(root, "candidate.xlsx")
      original = "fixture\x00\xff\n".b
      File.binwrite(path, original)
      File.chmod(0o444, path)
      [false, true].each do |fail_control|
        action = lambda do
          with_changed_artifact(path, original + "changed") do
            assert_equal original + "changed", File.binread(path)
            assert_equal 0o444, File.stat(path).mode & 0o7777
            raise "intentional control failure" if fail_control
          end
        end
        fail_control ? assert_raises(RuntimeError, &action) : action.call
        assert_equal original, File.binread(path)
        assert_equal 0o444, File.stat(path).mode & 0o7777
      end
      assert_raises(RuntimeError) do
        with_changed_artifact(path, nil) do
          refute File.exist?(path)
          raise "intentional withheld control failure"
        end
      end
      assert_equal original, File.binread(path)
      assert_equal 0o444, File.stat(path).mode & 0o7777
      link = File.join(root, "linked")
      File.symlink(path, link)
      assert_raises(RuntimeError) { with_changed_artifact(link, "forbidden") { flunk } }
      assert_equal original, File.binread(path)
      assert_equal 0o444, File.stat(path).mode & 0o7777
    end
  end
end
