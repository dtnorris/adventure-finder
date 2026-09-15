# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "pathname"
require "stringio"
require "tmpdir"
require "yaml"

require "adventure_finder_workspace"

class AdventureFinderWorkspaceTest < Minitest::Test
  FakeStatus = Struct.new(:successful) do
    def success?
      successful
    end
  end

  class ParallelTestRunner
    attr_reader :max_active

    def initialize(fail_names: [], delay: 0.05)
      @fail_names = fail_names
      @delay = delay
      @mutex = Mutex.new
      @active = 0
      @max_active = 0
    end

    def shell_capture(_command, chdir:, env: {})
      name = File.basename(chdir.to_s)
      @mutex.synchronize do
        @active += 1
        @max_active = [@max_active, @active].max
      end

      sleep @delay
      AdventureFinderWorkspace::CommandRunner::Result.new(
        stdout: "#{name} output\n",
        stderr: "",
        status: FakeStatus.new(!@fail_names.include?(name))
      )
    ensure
      @mutex.synchronize { @active -= 1 }
    end
  end

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
    assert_includes names, "runpod-ollama-fleet"
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
    assert_includes names, "af-inference-orchestrator"
    assert_includes names, "af-frontier-pack"
    refute_includes names, "runpod-ollama-fleet"
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

  def test_converter_setup_is_component_owned_and_tests_use_repo_local_virtualenv
    %w[pdf-to-llm-md-converter image-to-pdf-converter].each do |name|
      repo = manifest.repositories.find { |entry| entry["name"] == name }

      assert_equal "bin/setup", repo.fetch("setup")
      assert_includes repo.fetch("test"), 'PATH="$PWD/.venv/bin:$PATH"'
    end
  end

  def test_bootstrap_setup_is_repeatable_for_existing_converter_checkouts
    runner_class = Class.new do
      attr_reader :shell_calls, :system_calls

      def initialize
        @shell_calls = []
        @system_calls = []
      end

      def shell(command, chdir:, env: {})
        @shell_calls << {command: command, chdir: chdir.to_s, env: env}
        true
      end

      def system(*argv, chdir: nil, env: {})
        @system_calls << {argv: argv, chdir: chdir&.to_s, env: env}
        true
      end
    end

    converters = %w[pdf-to-llm-md-converter image-to-pdf-converter].map do |name|
      manifest.repositories.find { |entry| entry["name"] == name }
    end

    Dir.mktmpdir do |dir|
      converters.each do |repo|
        FileUtils.mkdir_p(File.join(dir, repo.fetch("name"), ".git"))
      end

      runner = runner_class.new
      workspace = AdventureFinderWorkspace::Workspace.new(
        manifest: manifest,
        root: dir,
        runner: runner,
        out: StringIO.new,
        err: StringIO.new
      )

      2.times do
        assert workspace.bootstrap(repos: converters, setup: true)
      end

      assert_empty runner.system_calls
      assert_equal 4, runner.shell_calls.length

      converters.each do |repo|
        name = repo.fetch("name")
        calls = runner.shell_calls.select do |call|
          call[:chdir] == File.join(dir, name)
        end

        assert_equal 2, calls.length
        calls.each do |call|
          assert_equal "bin/setup", call[:command]
          assert_equal({"AF_PROJECT_ROOT" => File.expand_path(dir)}, call[:env])
        end
      end
    end
  end

  def test_cross_repo_test_summary_includes_elapsed_seconds
    runner_class = Class.new do
      def shell(_command, chdir:, env: {})
        true
      end
    end

    repo = {"name" => "timed-suite", "test" => "bin/test"}

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "timed-suite", ".git"))

      out = StringIO.new
      workspace = AdventureFinderWorkspace::Workspace.new(
        manifest: manifest,
        root: dir,
        runner: runner_class.new,
        out: out,
        err: StringIO.new
      )

      assert workspace.test(repos: [repo])
      assert_match(/^timed-suite\s+PASS\s+\d+\.\d{2}s$/, out.string)
      assert_match(/^1\/1 suites passed\.$/, out.string)
      assert_match(/^Test jobs:\s+1$/, out.string)
      assert_match(/^Cumulative suite time:\s+\d+\.\d{2}s$/, out.string)
      assert_match(/^Workspace wall time:\s+\d+\.\d{2}s$/, out.string)
    end
  end

  def test_parallel_cross_repo_tests_respect_job_limit_and_buffer_output_in_repo_order
    repos = %w[suite-a suite-b suite-c suite-d suite-e].map do |name|
      {"name" => name, "test" => "bin/test"}
    end

    Dir.mktmpdir do |dir|
      repos.each do |repo|
        FileUtils.mkdir_p(File.join(dir, repo.fetch("name"), ".git"))
      end

      runner = ParallelTestRunner.new
      out = StringIO.new
      workspace = AdventureFinderWorkspace::Workspace.new(
        manifest: manifest,
        root: dir,
        runner: runner,
        out: out,
        err: StringIO.new
      )

      assert workspace.test(repos: repos, jobs: 3)
      assert_equal 3, runner.max_active

      start_lines = out.string.lines.grep(/^⠋ \[/)
      assert_equal repos.length, start_lines.length
      start_lines.each_with_index do |line, index|
        assert_match(/^⠋ \[#{index + 1}\/#{repos.length}\] /, line)
      end

      completion_lines = out.string.lines.grep(/^✓ \[/)
      assert_equal repos.length, completion_lines.length

      running_position = out.string.index("Running 5 repository test suites with 3 jobs...")
      first_start_position = out.string.index("⠋ [1/5]")
      first_completion_position = out.string.index("✓ [")
      first_header_position = out.string.index("=== suite-a: bin/test ===")
      assert_operator running_position, :<, first_start_position
      assert_operator first_start_position, :<, first_completion_position
      assert_operator first_start_position, :<, first_header_position

      header_positions = repos.map do |repo|
        out.string.index("=== #{repo.fetch('name')}: bin/test ===")
      end
      refute_includes header_positions, nil
      assert_equal header_positions.sort, header_positions
      assert_match(/^5\/5 suites passed\.$/, out.string)
      assert_match(/^Test jobs:\s+3$/, out.string)
    end
  end

  def test_parallel_cross_repo_tests_prioritize_longest_duration_hints_deterministically
    repos = [
      {"name" => "suite-a", "test" => "bin/test", "test_duration_hint_seconds" => 1.0},
      {"name" => "suite-b", "test" => "bin/test", "test_duration_hint_seconds" => 5.0},
      {"name" => "suite-c", "test" => "bin/test", "test_duration_hint_seconds" => 4.0},
      {"name" => "suite-d", "test" => "bin/test", "test_duration_hint_seconds" => 3.0},
      {"name" => "suite-e", "test" => "bin/test", "test_duration_hint_seconds" => 2.0}
    ]

    workspace = AdventureFinderWorkspace::Workspace.new(
      manifest: manifest,
      root: Dir.tmpdir,
      out: StringIO.new,
      err: StringIO.new
    )

    prioritized = workspace.send(:prioritized_testables, repos)

    assert_equal(
      %w[suite-b suite-c suite-d suite-e suite-a],
      prioritized.map { |repo, _index| repo.fetch("name") }
    )
    assert_equal [1, 2, 3, 4, 0], prioritized.map { |_repo, index| index }
  end

  def test_parallel_cross_repo_tests_aggregate_failures
    repos = %w[suite-a suite-b suite-c].map do |name|
      {"name" => name, "test" => "bin/test"}
    end

    Dir.mktmpdir do |dir|
      repos.each do |repo|
        FileUtils.mkdir_p(File.join(dir, repo.fetch("name"), ".git"))
      end

      out = StringIO.new
      workspace = AdventureFinderWorkspace::Workspace.new(
        manifest: manifest,
        root: dir,
        runner: ParallelTestRunner.new(fail_names: ["suite-b"], delay: 0.01),
        out: out,
        err: StringIO.new
      )

      refute workspace.test(repos: repos, jobs: 2)
      assert_match(/^suite-a\s+PASS\s+\d+\.\d{2}s$/, out.string)
      assert_match(/^suite-b\s+FAIL\s+\d+\.\d{2}s$/, out.string)
      assert_match(/^suite-c\s+PASS\s+\d+\.\d{2}s$/, out.string)
      assert_match(/^2\/3 suites passed\.$/, out.string)
      assert_match(/^✗ \[\d+\/3\] suite-b\s+\d+\.\d{2}s$/, out.string)
    end
  end

  def test_parallel_cross_repo_tests_report_missing_repositories
    repos = [
      {"name" => "present-suite", "test" => "bin/test"},
      {"name" => "missing-suite", "test" => "bin/test"}
    ]

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "present-suite", ".git"))

      out = StringIO.new
      workspace = AdventureFinderWorkspace::Workspace.new(
        manifest: manifest,
        root: dir,
        runner: ParallelTestRunner.new(delay: 0.01),
        out: out,
        err: StringIO.new
      )

      refute workspace.test(repos: repos, jobs: 2)
      assert_match(/^missing-suite\s+MISSING\s+-$/, out.string)
      assert_match(/^1\/2 suites passed\.$/, out.string)
    end
  end

  def test_parallel_cross_repo_test_validation_rejects_invalid_job_settings
    workspace = AdventureFinderWorkspace::Workspace.new(
      manifest: manifest,
      root: Dir.tmpdir,
      out: StringIO.new,
      err: StringIO.new
    )

    assert_raises(AdventureFinderWorkspace::Error) do
      workspace.test(repos: [], jobs: 0)
    end
    assert_raises(AdventureFinderWorkspace::Error) do
      workspace.test(repos: [], jobs: 2, fail_fast: true)
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
