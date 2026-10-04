# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"

class Fo21dDeadlineAdmissionCompositionTest < Minitest::Test
  def test_real_owner_admission_and_falsification_matrix_in_an_isolated_process
    workspace = ENV["AF_FO21_WORKSPACE_ROOT"]
    skip "set AF_FO21_WORKSPACE_ROOT to the sibling-repository workspace" if workspace.to_s.empty?

    # Loading the real RPOF owner belongs only in this composed proof, not in
    # the process running AdventureFinder's dependency-independence checks.
    root = File.expand_path("../..", __dir__)
    stdout, stderr, status = Open3.capture3(
      { "AF_FO21_WORKSPACE_ROOT" => File.expand_path(workspace) }, RbConfig.ruby,
      "-w", "-I", File.join(root, "lib"), File.join(root, "test/support/fo21d_deadline_admission.rb"),
      "--seed", "2104", chdir: root
    )
    assert status.success?, "FO-21D composed acceptance failed:\n#{stdout}\n#{stderr}"
    assert_match(/22 runs, \d+ assertions, 0 failures, 0 errors, 0 skips/, stdout)
    assert_empty stderr
  end
end
