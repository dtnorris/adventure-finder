# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "timeout"

# Keep cross-owner imports and the strict guard out of the unit-test process.
class Fo24cReleaseAcceptanceTest < Minitest::Test
  def test_composed_release_in_an_isolated_offline_process
    workspace = ENV["AF_FO24C_WORKSPACE_ROOT"]
    skip "set AF_FO24C_WORKSPACE_ROOT to exact sibling checkouts" if workspace.to_s.empty?

    root = File.expand_path("../..", __dir__)
    env = { "AF_FO24C_WORKSPACE_ROOT" => File.expand_path(workspace),
            "PATH" => ENV.fetch("PATH"), "MT_NO_PLUGINS" => "1" }
    stdout, stderr, status = Timeout.timeout(120) do
      Open3.capture3(env, RbConfig.ruby, File.join(root, "test/support/fo24c/release.rb"),
                     "--seed", "2403", chdir: root, unsetenv_others: true)
    end
    assert status.success?, "FO-24C failed:\n#{stdout}\n#{stderr}"
    assert_match(/0 failures, 0 errors, 0 skips/, stdout)
    assert_includes stdout, "FO-24C composed green path: pending human review; verified provider absence"
  end
end
