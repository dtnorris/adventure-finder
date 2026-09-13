# frozen_string_literal: true

require "minitest/autorun"
require "pathname"
require "stringio"
require "tmpdir"
require "yaml"

require "adventure_finder_workspace"

class AdventureFinderWorkspaceTest < Minitest::Test
  def manifest
    @manifest ||= AdventureFinderWorkspace::Manifest.new(
      Pathname(__dir__).join("..", "repos.yml")
    )
  end

  def test_manifest_schema_and_unique_repository_names
    assert_equal "adventurefinder-workspace/v0.1", manifest.data["schema_version"]
    names = manifest.repositories.map { |repo| repo.fetch("name") }
    assert_equal names.uniq.sort, names.sort
  end

  def test_default_selection_excludes_archived_and_experimental_repos
    names = manifest.selected.map { |repo| repo.fetch("name") }

    assert_includes names, "af-data-pipeline"
    assert_includes names, "llm-response-data"
    refute_includes names, "af-corpus-ingester-basics"
    refute_includes names, "af-matcher-cli"
    refute_includes names, "5e-tools-corpus-converter"
  end

  def test_core_selection_contains_authorities_and_current_core_code
    names = manifest.selected(core: true).map { |repo| repo.fetch("name") }

    assert_includes names, "md-specification-files"
    assert_includes names, "af-xlsx-data-sources"
    assert_includes names, "md-for-llm-book-content"
    assert_includes names, "af-data-pipeline"
    assert_includes names, "af-cli-scoring-utility"
    assert_includes names, "local-model-eval"
    assert_includes names, "af-frontier-pack"
    refute_includes names, "llm-response-data"
  end

  def test_llm_response_data_is_shallow_by_default
    repo = manifest.repositories.find { |entry| entry["name"] == "llm-response-data" }
    assert_equal 1, repo["clone_depth"]
  end

  def test_clone_urls_support_ssh_and_https
    Dir.mktmpdir do |dir|
      workspace = AdventureFinderWorkspace::Workspace.new(
        manifest: manifest,
        root: dir,
        out: StringIO.new,
        err: StringIO.new
      )
      repo = {"github" => "dtnorris/af-data-pipeline"}

      assert_equal "git@github.com:dtnorris/af-data-pipeline.git", workspace.clone_url(repo, "ssh")
      assert_equal "https://github.com/dtnorris/af-data-pipeline.git", workspace.clone_url(repo, "https")
    end
  end

  def test_command_runner_uses_non_login_shell
    runner_class = Class.new(AdventureFinderWorkspace::CommandRunner) do
      attr_reader :invocation

      def system(*argv, chdir: nil, env: {})
        @invocation = {argv: argv, chdir: chdir, env: env}
        true
      end
    end

    runner = runner_class.new
    runner.shell("echo ok", chdir: "/tmp", env: {"SENTINEL" => "present"})

    assert_equal ["/bin/sh", "-c", "echo ok"], runner.invocation[:argv]
    assert_equal({"SENTINEL" => "present"}, runner.invocation[:env])
  end

  def test_converter_tests_prepend_repo_local_virtualenv
    %w[pdf-to-llm-md-converter image-to-pdf-converter].each do |name|
      repo = manifest.repositories.find { |entry| entry["name"] == name }
      assert_includes repo.fetch("test"), 'PATH="$PWD/.venv/bin:$PATH"'
    end
  end

  def test_unknown_clone_protocol_fails_closed
    Dir.mktmpdir do |dir|
      workspace = AdventureFinderWorkspace::Workspace.new(
        manifest: manifest,
        root: dir,
        out: StringIO.new,
        err: StringIO.new
      )
      assert_raises(AdventureFinderWorkspace::Error) do
        workspace.clone_url({"github" => "dtnorris/af-data-pipeline"}, "ftp")
      end
    end
  end
end
