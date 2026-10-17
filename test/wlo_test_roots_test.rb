# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

class WloTestRootsTest < Minitest::Test
  def test_detached_front_door_uses_manifest_component_root_by_default
    with_fixture do |front, components, _dir|
      wlo = create_contract(File.join(components, "workload-orchestrator"))
      assert_loaded(front, {}, wlo)
    end
  end

  def test_explicit_component_root_supports_flat_and_component_layouts
    with_fixture do |front, _components, dir|
      [dir, File.join(dir, "alternate components")].each do |root|
        wlo = create_contract(File.join(root, "workload-orchestrator"))
        assert_loaded(front, {"AF_PROJECT_ROOT" => root}, wlo)
      end
    end
  end

  def test_explicit_wlo_root_takes_precedence_over_component_root_and_manifest
    with_fixture do |front, _components, dir|
      wlo = create_contract(File.join(dir, "selected wlo"))
      assert_loaded(front, {"WLO_REPOSITORY_ROOT" => wlo,
                            "AF_PROJECT_ROOT" => File.join(dir, "unused")}, wlo)
    end
  end

  def test_missing_selected_contract_does_not_fall_back_to_ambient_load_path
    with_fixture do |front, components, dir|
      fallback = create_contract(File.join(components, "workload-orchestrator"))
      missing = File.join(dir, "missing wlo")
      _stdout, stderr, status = run_loader(front, {
        "WLO_REPOSITORY_ROOT" => missing, "RUBYLIB" => File.join(fallback, "lib")
      })
      refute status.success?
      assert_includes stderr, "WLO capability contract not found: #{missing}/lib/"
      assert_includes stderr, "set WLO_REPOSITORY_ROOT or AF_PROJECT_ROOT"
    end
  end

  private

  def with_fixture
    Dir.mktmpdir("wlo test roots") do |dir|
      front = File.join(dir, "detached-front-door")
      components = File.join(dir, "adventure-finder-components")
      FileUtils.mkdir_p(File.join(front, "test/support"))
      FileUtils.cp(File.join(__dir__, "support/wlo_contract.rb"), File.join(front, "test/support"))
      File.write(File.join(front, "repos.yml"), {"workspace_root_default" => components}.to_yaml)
      yield front, components, dir
    end
  end

  # Marker only for isolated path-resolution tests. The existing capability,
  # preflight and capacity tests still load the actual external WLO contract.
  def create_contract(root)
    path = File.join(root, "lib/workload_orchestrator/ollama_capability_request.rb")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "WLO_ROOT_TEST_LOADED_FROM = __FILE__\n")
    root
  end

  def assert_loaded(front, overrides, root)
    stdout, stderr, status = run_loader(front, overrides)
    assert status.success?, stderr
    assert_equal [root, File.join(root, "lib/workload_orchestrator/ollama_capability_request.rb")],
                 JSON.parse(stdout)
  end

  def run_loader(front, overrides)
    env = {"AF_PROJECT_ROOT" => nil, "WLO_REPOSITORY_ROOT" => nil, "WLO_REPO_ROOT" => nil, "RUBYLIB" => nil, "RUBYOPT" => nil}
    Open3.capture3(env.merge(overrides), RbConfig.ruby, "-rjson", "-e",
                  "require './test/support/wlo_contract'; " \
                  "puts JSON.generate([WLO_ROOT, WLO_ROOT_TEST_LOADED_FROM])", chdir: front)
  end
end
