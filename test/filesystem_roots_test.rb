# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "pathname"
require "adventure_finder_workspace"

class FilesystemRootsTest < Minitest::Test
  def test_components_outside_repositories_and_timing_have_distinct_roots
    manifest = AdventureFinderWorkspace::Manifest.new(File.expand_path("../repos.yml", __dir__))
    assert_equal "/Users/davidnorris/code/adventure-finder-components", manifest.workspace_root_default
    Dir.mktmpdir("filesystem roots") do |dir|
      %w[adventure-finder adventure-finder-production].each do |name|
        front_door = File.join(dir, name)
        components = File.join(dir, "adventure-finder-components")
        workspace = AdventureFinderWorkspace::Workspace.new(
          manifest: manifest, root: components, front_door_root: front_door
        )
        assert_equal Pathname(components).join("af-workloads"),
                     workspace.send(:repo_path_by_name, "af-workloads")
        assert_equal Pathname(front_door).join("output/af-test"),
                     workspace.send(:test_timing_history_dir)
        assert_equal Pathname(dir).join("af-matcher-cli"),
                     workspace.send(:repo_path_by_name, "af-matcher-cli")
        refute_includes manifest.selected.map { |repo| repo["name"] }, "af-matcher-cli"
        assert_includes manifest.selected(all: true).map { |repo| repo["name"] }, "af-matcher-cli"
      end
      workspace = AdventureFinderWorkspace::Workspace.new(
        manifest: manifest, root: dir, adjacent_root: File.join(dir, "outside")
      )
      assert_equal Pathname(dir).join("af-workloads"), workspace.send(:repo_path_by_name, "af-workloads")
      assert_equal Pathname(dir).join("outside/af-matcher-cli"), workspace.send(:repo_path_by_name, "af-matcher-cli")
    end
  end
end
