# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "pathname"
require "stringio"
require "tmpdir"
require "timeout"
require "yaml"

require "adventure_finder_workspace"

class AdventureFinderWorkspaceTest < Minitest::Test
  # Returns a captured AFDP worker block with reconciled aggregate accounting.
  # Inputs select the public suite and counts; no command or fixture is executed.
  def self.worker_output(suite, runs:, assertions:)
    "Running #{runs} tests in 1 isolated Ruby workers (seed 1)\n" \
      "Suite: #{suite}\nWorker 1:\n" \
      "#{runs} runs, #{assertions} assertions, 0 failures, 0 errors, 0 skips\n" \
      "Finished in 0.010000s across all workers.\n" \
      "#{runs} runs, #{assertions} assertions, 0 failures, 0 errors, 0 skips\n"
  end

  # Models the public integration output, including independent dependency work
  # and full coverage, so the fake runner cannot pass on exit status alone.
  def self.integration_output
    worker_output("integration (functional)", runs: 1, assertions: 3) +
      "test:integration:functional:deps:\n2 runs, 3 assertions, 0 failures, 0 errors, 0 skips\n" +
      "test:coverage:full:\n" + worker_output("all (coverage)", runs: 3, assertions: 5) +
      "Integration validation finished in 0.030s.\n"
  end

  # Writes structured outcomes for the fake command's observed invocations:
  # functional 1/3, dependency fixture 2/3, and full coverage 3/5. The unchanged
  # text above is presentation; it never supplies authoritative evidence.
  def self.publish_result(environment, passed: true)
    path = environment["AFDP_TEST_RESULT_PATH"]
    return unless path

    integration = environment.fetch("TEST_FIXTURE_SUITE", "") == "integration"
    counts = integration ? [[1, 3], [2, 3], [3, 5]].transpose.map(&:sum) : [2, 3]
    record = {"schema" => "afdp-suite-result/v1", "run_id" => environment.fetch("AFDP_TEST_RESULT_RUN_ID"),
      "suite" => integration ? "integration" : "fast", "status" => passed ? "passed" : "failed",
      "tests" => counts[0], "assertions" => counts[1], "failures" => 0, "errors" => 0, "skips" => 0}
    File.write(path, JSON.generate(record))
  end

  FakeStatus = Struct.new(:successful) do
    def success?
      successful
    end
  end

  class ParallelTestRunner
    attr_reader :max_active, :envs, :calls

    def initialize(fail_names: [], delay: 0.05)
      @fail_names = fail_names
      @delay = delay
      @envs = []
      @calls = []
      @mutex = Mutex.new
      @active = 0
      @max_active = 0
    end

    def shell_capture(_command, chdir:, env: {})
      name = File.basename(chdir.to_s)
      @mutex.synchronize do
        @active += 1
        @envs << env.dup
        @calls << [name, env.dup]
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

  class RecordingRunner
    attr_reader :calls

    def initialize(fail_command: nil, integration_output: AdventureFinderWorkspaceTest.integration_output)
      @calls = []
      @fail_command = fail_command
      @integration_output = integration_output
    end

    def shell_capture(command, chdir:, env: {})
      @calls << [command, chdir.to_s, env]
      fixture_environment = env.merge("TEST_FIXTURE_SUITE" => command.end_with?("test:integration") ? "integration" : "fast")
      AdventureFinderWorkspaceTest.publish_result(fixture_environment, passed: command != @fail_command)
      AdventureFinderWorkspace::CommandRunner::Result.new(
        stdout: command == "bundle exec rake test:integration" ? @integration_output : "2 runs, 3 assertions, 0 failures, 0 errors, 0 skips\n",
        stderr: "", status: FakeStatus.new(command != @fail_command)
      )
    end
  end

  # Synchronizes the two AFDP calls without sleep-based timings and records
  # concurrency by command, including calls sharing one physical checkout.
  class PipelineParallelRunner < RecordingRunner
    attr_reader :max_active, :overlapping_paths, :events

    def initialize
      super
      @mutex = Mutex.new
      @fast_started = Queue.new
      @integration_started = Queue.new
      @active = []
      @max_active = 0
      @overlapping_paths = []
      @events = []
    end

    # Returns normal fake output after a bounded fast/integration handshake.
    # Timeout::Error exposes scheduling regressions instead of hanging the suite.
    def shell_capture(command, chdir:, env: {})
      path = chdir.to_s
      @mutex.synchronize do
        @overlapping_paths << path if @active.any? { |active_path, _command| active_path == path }
        @active << [path, command]
        @max_active = [@max_active, @active.length].max
        @events << [:start, path, command]
      end
      Timeout.timeout(2) do
        if File.basename(path) == "af-data-pipeline" && command == "bundle exec rake"
          @fast_started << true
          @integration_started.pop
        elsif File.basename(path) == "af-data-pipeline" && command == "bundle exec rake test:integration"
          @fast_started.pop
          @integration_started << true
        end
      end
      @mutex.synchronize { super }
    ensure
      @mutex.synchronize do
        @events << [:finish, path, command]
        @active.delete([path, command])
      end
    end
  end

  # Yields one disposable canonical pipeline checkout, an unrelated checkout,
  # and a detached front door with injected commands; it never uses live roots.
  def with_pipeline_workspace(runner: RecordingRunner.new, missing: false)
    Dir.mktmpdir do |directory|
      components = File.join(directory, "components")
      front = File.join(directory, "front")
      FileUtils.mkdir_p(File.join(components, "af-data-pipeline", ".git")) unless missing
      FileUtils.mkdir_p(File.join(components, "other", ".git"))
      FileUtils.mkdir_p(File.join(front, "lib"))
      FileUtils.mkdir_p(File.join(front, "bin"))
      File.write(File.join(front, "Rakefile"), "")
      File.write(File.join(front, "lib/adventure_finder_workspace.rb"), "")
      File.write(File.join(front, "bin/af-operator-acceptance"), "")
      out, err = StringIO.new, StringIO.new
      workspace = AdventureFinderWorkspace::Workspace.new(manifest: manifest, root: components,
        front_door_root: front, runner: runner, out: out, err: err)
      pipeline = manifest.repositories.find { |repo| repo["name"] == "af-data-pipeline" }
      yield workspace, pipeline, runner, out, err, front
    end
  end

  # Confirms both normal selections expand only the canonical physical checkout.
  def test_pipeline_default_and_core_selection_run_both_gates_once
    [manifest.selected, manifest.selected(core: true)].each do |selection|
      with_pipeline_workspace do |workspace, pipeline, runner, out, err, front|
        # Populate only selected testable fixtures. Archived and production roots
        # deliberately exist as sentinels but must receive no command or write.
        selection.select { |repo| repo["test"] }.each do |repo|
          FileUtils.mkdir_p(workspace.root / repo.fetch("name") / ".git")
        end
        sentinels = %w[af-data-pipeline-production af-corpus-ingester-basics af-matcher-cli]
        sentinels.each do |name|
          FileUtils.mkdir_p(workspace.root / name / ".git")
          File.write(workspace.root / name / "sentinel", "unchanged")
        end
        assert workspace.test(repos: selection)
        calls = runner.calls.select { |_command, path, _env| path == (workspace.root / pipeline["name"]).to_s }
        assert_equal ["bundle exec rake", "bundle exec rake test:integration"], calls.map(&:first)
        assert_match(/^af-data-pipeline \/ fast\s+PASS\s+\d+\.\d{2}s$/, out.string)
        assert_match(/^af-data-pipeline \/ integration\s+PASS\s+\d+\.\d{2}s$/, out.string)
        assert_includes out.string, "Physical repositories: #{selection.count { |repo| repo['test'] } + 1}"
        sentinels.each do |name|
          refute runner.calls.any? { |_command, path, _env| path == (workspace.root / name).to_s }
          assert_equal "unchanged", File.read(workspace.root / name / "sentinel")
        end
        history = YAML.safe_load(File.read(Dir.glob("#{front}/output/af-test/run-*.yml").last))
        assert_equal "pass", history.dig("repositories", "af-data-pipeline", "result")
        assert_equal selection.count { |repo| repo["test"] } + 1, history.fetch("repositories").length
        assert_empty err.string
      end
    end
  end

  # Omitting AFDP executes neither command and never invents a pipeline result.
  def test_omitted_pipeline_has_no_suites
    with_pipeline_workspace do |workspace, _pipeline, runner, out|
      assert workspace.test(repos: [], jobs: 2, include_front_door: false)
      assert_empty runner.calls
      refute_includes out.string, "af-data-pipeline"
    end
  end

  # Either public command failure fails the component while ordinary execution
  # still attempts the other command and prints captured stdout/stderr diagnostics.
  def test_pipeline_failures_do_not_suppress_the_other_gate_or_comprehensive
    ["bundle exec rake", "bundle exec rake test:integration"].each do |command|
      runner = RecordingRunner.new(fail_command: command)
      with_pipeline_workspace(runner: runner) do |workspace, pipeline, _runner, out|
        refute workspace.test(repos: [pipeline], comprehensive: true)
        assert_equal ["bundle exec rake", "bundle exec rake test:integration", "rake"], runner.calls.first(3).map(&:first)
        assert_equal 4, runner.calls.length
        phase = command.end_with?("test:integration") ? "integration" : "fast"
        assert_match(/^af-data-pipeline \/ #{phase}\s+FAIL/, out.string)
        assert_includes out.string, "Component phase: 0/1 passed"
        assert_includes out.string, "Operator acceptance phase: PASS"
        assert_match(/^Total runs:\s+10$/, out.string)
      end
    end
  end

  # Closed-schema documents, fresh binding and independent exits control both
  # scheduler modes. A passing peer and misleading output cannot repair evidence.
  def test_pipeline_requires_fresh_complete_public_results
    mutations = [
      ->(record) { nil }, ->(record) { "{" }, ->(record) { record + record },
      ->(record) { record.sub('"tests":6', '"tests":0,"tests":6') },
      ->(record) { JSON.generate(JSON.parse(record).merge("run_id" => "0" * 32)) },
      ->(record) { JSON.generate(JSON.parse(record).merge("suite" => "fast")) },
      ->(record) { JSON.generate(JSON.parse(record).merge("status" => "incomplete")) },
      ->(record) { JSON.generate(JSON.parse(record).merge("failures" => 1)) },
      ->(record) { JSON.generate(JSON.parse(record).reject { |key, _| key == "assertions" }) }
    ]
    [1, 2].each do |jobs|
      mutations.each do |mutate|
        runner = RecordingRunner.new
        runner.define_singleton_method(:shell_capture) do |command, chdir:, env: {}|
          result = super(command, chdir: chdir, env: env)
          if command.end_with?("test:integration")
            path = env.fetch("AFDP_TEST_RESULT_PATH")
            bytes = mutate.call(File.read(path))
            bytes ? File.write(path, bytes) : File.unlink(path)
            result.stdout = AdventureFinderWorkspaceTest.integration_output
          end
          result
        end
        with_pipeline_workspace(runner: runner) do |workspace, pipeline, _runner, out|
          refute workspace.test(repos: [pipeline], jobs: jobs, include_front_door: false)
          assert_match(/^af-data-pipeline \/ fast\s+PASS/, out.string)
          assert_match(/^af-data-pipeline \/ integration\s+FAIL/, out.string)
          assert_includes out.string, "accounting evidence missing or invalid"
          assert_match(/^Total runs:\s+2$/, out.string)
        end
      end
    end
  end

  # Exit failures retain their own suite attribution even with a valid passing
  # document. Missing fast evidence cannot borrow the integration peer's counts.
  def test_parallel_pipeline_failures_and_missing_fast_evidence_fail_closed
    ["bundle exec rake", "bundle exec rake test:integration"].each do |command|
      with_pipeline_workspace(runner: RecordingRunner.new(fail_command: command)) do |workspace, pipeline, runner, out|
        refute workspace.test(repos: [pipeline], jobs: 2, include_front_door: false)
        assert_equal ["bundle exec rake", "bundle exec rake test:integration"], runner.calls.map(&:first).sort
        assert_includes out.string, "Component phase: 0/1 passed"
      end
    end
    runner = RecordingRunner.new
    runner.define_singleton_method(:shell_capture) do |command, chdir:, env: {}|
      result = super(command, chdir: chdir, env: env)
      File.unlink(env.fetch("AFDP_TEST_RESULT_PATH")) if command == "bundle exec rake"
      result
    end
    with_pipeline_workspace(runner: runner) do |workspace, pipeline, _runner, out|
      refute workspace.test(repos: [pipeline], jobs: 2, include_front_door: false)
      assert_includes out.string, "required AFDP fast accounting evidence missing or invalid"
      assert_match(/^af-data-pipeline \/ integration\s+PASS/, out.string)
    end
  end

  # Changing or omitting all presentation leaves validated counters and suite
  # status unchanged, with no heading, summary or completion-sentence dependency.
  def test_pipeline_cosmetic_output_cannot_change_accounting
    [1, 2].each do |jobs|
      ["", "renamed headings and summary\n", "999 runs, 0 assertions, 99 failures, 0 errors, 0 skips\n"].each do |text|
        runner = RecordingRunner.new
        runner.define_singleton_method(:shell_capture) do |command, chdir:, env: {}|
          result = super(command, chdir: chdir, env: env)
          result.stdout = text
          result
        end
        with_pipeline_workspace(runner: runner) do |workspace, pipeline, _runner, out, err|
          assert workspace.test(repos: [pipeline], jobs: jobs, include_front_door: false)
          assert_match(/^Total runs:\s+8$/, out.string)
          assert_match(/^Total assertions:\s+14$/, out.string)
          assert_empty err.string
        end
      end
    end
  end


  # A fully valid passing document cannot repair a nonzero process exit. A
  # valid failed document retains its own error/skip counters despite nice text.
  def test_pipeline_status_and_failed_counters_are_independent_of_text
    runner = RecordingRunner.new
    runner.define_singleton_method(:shell_capture) do |command, chdir:, env: {}|
      result = super(command, chdir: chdir, env: env)
      path = env.fetch("AFDP_TEST_RESULT_PATH")
      if command == "bundle exec rake"
        result.status = FakeStatus.new(false)
      else
        record = JSON.parse(File.read(path)).merge("status" => "failed", "tests" => 2,
          "assertions" => 0, "errors" => 1, "skips" => 1)
        File.write(path, JSON.generate(record))
      end
      result
    end
    with_pipeline_workspace(runner: runner) do |workspace, pipeline, _runner, out|
      refute workspace.test(repos: [pipeline], jobs: 2, include_front_door: false)
      assert_match(/^af-data-pipeline \/ fast\s+FAIL/, out.string)
      assert_match(/^af-data-pipeline \/ integration\s+FAIL/, out.string)
      assert_match(/^Total runs:\s+4$/, out.string)
      assert_match(/^Total assertions:\s+3$/, out.string)
      assert_match(/^Total errors:\s+1$/, out.string)
      assert_match(/^Total skips:\s+1$/, out.string)
    end
  end

  # Missing checkouts report two MISSING gates with no commands or fake counts.
  def test_missing_pipeline_checkout_is_missing_for_both_suites
    with_pipeline_workspace(missing: true) do |workspace, pipeline, runner, out, err|
      refute workspace.test(repos: [pipeline], include_front_door: false)
      assert_empty runner.calls
      assert_match(/^af-data-pipeline \/ fast\s+MISSING\s+-$/, out.string)
      assert_match(/^af-data-pipeline \/ integration\s+MISSING\s+-$/, out.string)
      assert_match(/^Total runs:\s+0$/, out.string)
      assert_includes err.string, "invalid or missing suite root"
      refute_includes err.string, "test counts unknown"
    end
  end

  # Serial fail-fast preserves rows for the second AFDP suite and later repos;
  # a later front-door or acceptance phase cannot turn that work into PASS.
  def test_pipeline_fail_fast_reports_every_unexecuted_suite
    ["bundle exec rake", "bundle exec rake test:integration"].each do |command|
      runner = RecordingRunner.new(fail_command: command)
      with_pipeline_workspace(runner: runner) do |workspace, pipeline, _runner, out, err|
        other = {"name" => "other", "test" => "other-command"}
        refute workspace.test(repos: [pipeline, other], fail_fast: true, comprehensive: true)
        assert_equal(command.end_with?("test:integration") ? 2 : 1, runner.calls.length)
        assert_match(/^other\s+NOT RUN\s+-$/, out.string)
        assert_match(/^adventure-finder\s+NOT RUN\s+-$/, out.string)
        assert_includes out.string, "Operator acceptance phase: NOT RUN (fail-fast)"
        assert_match(/^af-data-pipeline \/ integration\s+NOT RUN\s+-$/, out.string) if command == "bundle exec rake"
        refute_includes err.string, "test counts unknown"
      end
    end
    with_pipeline_workspace do |workspace, pipeline, runner, out|
      refute workspace.test(repos: [{"name" => "absent", "test" => "missing"}, pipeline], fail_fast: true)
      assert_empty runner.calls
      assert_match(/^af-data-pipeline \/ fast\s+NOT RUN\s+-$/, out.string)
      assert_match(/^af-data-pipeline \/ integration\s+NOT RUN\s+-$/, out.string)
    end
  end

  # Both AFDP gates occupy bounded slots before lower-priority unrelated work.
  def test_parallel_pipeline_suites_overlap_within_the_global_limit
    runner = PipelineParallelRunner.new
    with_pipeline_workspace(runner: runner) do |workspace, pipeline, _runner, out, err, front|
      assert workspace.test(repos: [pipeline, {"name" => "other", "test" => "other-command"}],
        jobs: 2, include_front_door: false)
      assert_equal 2, runner.max_active
      path = (workspace.root / "af-data-pipeline").to_s
      assert_equal [path, path], runner.events.select { |event| event.first == :start }.first(2).map { |event| event[1] }
      assert_includes runner.overlapping_paths, path
      fast_end = runner.events.index([:finish, path, "bundle exec rake"])
      integration_start = runner.events.index([:start, path, "bundle exec rake test:integration"])
      assert_operator integration_start, :<, fast_end
      assert_equal 3, runner.calls.length
      assert runner.calls.all? { |_command, _path, env| env["AF_TEST_CONTENDED"] == "1" }
      assert_includes out.string, "3/3 suites passed."
      assert_includes out.string, "Component phase: 2/2 passed"
      assert_includes out.string, "Physical repositories: 2"
      assert_match(/^Total runs:\s+10$/, out.string)
      assert_match(/^Total assertions:\s+17$/, out.string)
      history = YAML.safe_load(File.read(Dir.glob("#{front}/output/af-test/run-*.yml").last))
      assert_equal %w[af-data-pipeline other], history.fetch("repositories").keys.sort
      assert_operator history.dig("repositories", "af-data-pipeline", "elapsed_seconds"), :>=, 0.0
      assert_empty err.string
    end
  end

  # A single selected physical checkout can use both available logical slots.
  # With one job its same commands still execute in their original serial order.
  def test_pipeline_alone_uses_two_slots_but_one_job_remains_serial
    with_pipeline_workspace(runner: PipelineParallelRunner.new) do |workspace, pipeline, runner, out|
      assert workspace.test(repos: [pipeline], jobs: 2, include_front_door: false)
      assert_equal 2, runner.max_active
      assert_equal ["bundle exec rake", "bundle exec rake test:integration"], runner.calls.map(&:first).sort
      assert_includes out.string, "Running 2 repository test suites with 2 jobs"
      starts = out.string.lines.grep(/^⠋ /)
      assert starts.any? { |line| line.include?("af-data-pipeline / fast") }
      assert starts.any? { |line| line.include?("af-data-pipeline / integration") }
      refute starts.any? { |line| line.include?("~") }
      assert_includes out.string, "Physical repositories: 1"
    end
    with_pipeline_workspace do |workspace, pipeline, runner|
      assert workspace.test(repos: [pipeline], jobs: 1, include_front_door: false)
      assert_equal ["bundle exec rake", "bundle exec rake test:integration"], runner.calls.map(&:first)
      assert runner.calls.all? { |_command, _path, env| env["AF_TEST_CONTENDED"].nil? }
    end
  end

  # Uses actual child processes with a bounded file handshake. The first child
  # cannot pass until its peer has started; no network/socket support is needed.
  def test_parallel_pipeline_overlaps_real_subprocesses_and_keeps_their_output
    with_pipeline_workspace do |workspace, pipeline, _runner, out, err, front|
      tools = File.join(front, "tools")
      FileUtils.mkdir_p(tools)
      File.write(File.join(tools, "bundle"), <<~RUBY)
        #!#{RbConfig.ruby}
        integration = ARGV == ["exec", "rake", "test:integration"]
        abort "unexpected command" unless integration || ARGV == ["exec", "rake"]
        phase = integration ? "integration" : "fast"
        peer = integration ? "fast" : "integration"
        root = ENV.fetch("SUITE_BARRIER")
        File.write(File.join(root, phase), Process.pid.to_s)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
        until File.file?(File.join(root, peer))
          abort "incomplete overlap" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep 0.005
        end
        require "json"
        record = {schema: "afdp-suite-result/v1", run_id: ENV.fetch("AFDP_TEST_RESULT_RUN_ID"),
          suite: phase, status: "passed", tests: integration ? 1 : 2, assertions: 3, failures: 0, errors: 0, skips: 0}
        File.write(ENV.fetch("AFDP_TEST_RESULT_PATH"), JSON.generate(record))
        puts "cosmetic output only"
        warn(integration ? "integration diagnostic" : "fast diagnostic")
      RUBY
      FileUtils.chmod(0o755, File.join(tools, "bundle"))
      runner = AdventureFinderWorkspace::CommandRunner.new
      runner.define_singleton_method(:shell_capture) do |command, chdir:, env: {}|
        super(command, chdir: chdir, env: env.merge("PATH" => "#{tools}:#{ENV.fetch('PATH')}", "SUITE_BARRIER" => front))
      end
      actual = AdventureFinderWorkspace::Workspace.new(manifest: manifest, root: workspace.root,
        front_door_root: front, runner: runner, out: out, err: err)
      assert actual.test(repos: [pipeline], jobs: 2, include_front_door: false)
      identities = %w[fast integration].map { |phase| File.read(File.join(front, phase)) }
      assert_equal 2, identities.uniq.length
      assert_includes out.string, "fast diagnostic"
      assert_includes out.string, "integration diagnostic"
      assert_match(/^Total runs:\s+3$/, out.string)
      assert_match(/^Total assertions:\s+6$/, out.string)
      assert_empty err.string
    end
  end

  # Verifies cumulative scheduling history uses one physical AFDP entry and the
  # sum of both suite durations, including failure and NOT RUN outcomes.
  def test_pipeline_history_and_summary_preserve_cumulative_repository_time
    with_pipeline_workspace do |workspace, _pipeline, _runner, out, _err, front|
      results = [
        AdventureFinderWorkspace::Workspace::TestResult.new(name: "af-data-pipeline",
          suite: "fast", command: "bundle exec rake", result: :pass, elapsed: 1.25),
        AdventureFinderWorkspace::Workspace::TestResult.new(name: "af-data-pipeline",
          suite: "integration", command: "bundle exec rake test:integration", result: :fail, elapsed: 2.5)
      ]
      workspace.send(:record_test_timing_history, results, workspace_elapsed: 3.8, jobs: 2)
      history = YAML.safe_load(File.read(Dir.glob("#{front}/output/af-test/run-*.yml").last))
      assert_equal ["af-data-pipeline"], history.fetch("repositories").keys
      assert_equal "fail", history.dig("repositories", "af-data-pipeline", "result")
      assert_in_delta 3.75, history.dig("repositories", "af-data-pipeline", "elapsed_seconds"), 0.000001
      workspace.send(:print_test_summary, results, workspace_elapsed: 3.8, jobs: 2)
      assert_includes out.string, "Repository cumulative time: af-data-pipeline 3.75s"
      assert_match(/^Workspace wall time:\s+3.80s$/, out.string)
      results.last.result = :not_run
      results.last.elapsed = nil
      workspace.send(:record_test_timing_history, results, workspace_elapsed: 1.3, jobs: 1)
      history = YAML.safe_load(File.read(Dir.glob("#{front}/output/af-test/run-*.yml").sort.last))
      assert_equal "not_run", history.dig("repositories", "af-data-pipeline", "result")
      assert_in_delta 1.25, history.dig("repositories", "af-data-pipeline", "elapsed_seconds"), 0.000001
    end
  end

  # Controlled result durations exercise persistence and the next parallel run's
  # start hints without using wall-clock delays or changing completion accounting.
  def test_pipeline_history_records_independent_durations_and_start_estimates
    with_pipeline_workspace(runner: PipelineParallelRunner.new) do |workspace, pipeline, runner, out, err, front|
      workspace.define_singleton_method(:run_test_repo) do |repo, **options|
        super(repo, **options).tap { |result| result.elapsed = repo["suite"] == "fast" ? 12.5 : 87.5 }
      end
      assert workspace.test(repos: [pipeline], jobs: 2, include_front_door: false)
      refute out.string.lines.grep(/^⠋ /).any? { |line| line.include?("~") }
      history = YAML.safe_load(File.read(Dir.glob("#{front}/output/af-test/run-*.yml").last))
      row = history.fetch("repositories").fetch("af-data-pipeline")
      assert_equal "pass", row.fetch("result")
      assert_equal 100.0, row.fetch("elapsed_seconds")
      assert_equal({"fast" => {"result" => "pass", "elapsed_seconds" => 12.5},
                    "integration" => {"result" => "pass", "elapsed_seconds" => 87.5}}, row.fetch("suites"))
      out.truncate(0)
      out.rewind
      assert workspace.test(repos: [pipeline], jobs: 2, include_front_door: false)
      assert_match(/^⠋ \[\d\/2\] af-data-pipeline \/ fast\s+~13s$/, out.string)
      assert_match(/^⠋ \[\d\/2\] af-data-pipeline \/ integration\s+~88s$/, out.string)
      assert_equal 2, runner.max_active
      assert_equal 4, runner.calls.length
      assert_includes out.string, "2/2 suites passed."
      assert_includes out.string, "Repository cumulative time: af-data-pipeline 100.00s"
      assert_match(/^Total runs:\s+8$/, out.string)
      assert_match(/^Total assertions:\s+14$/, out.string)
      assert_empty err.string
    end
  end

  # The existing window selects the latest three files, then takes the median
  # of eligible samples, independently for aggregate scheduling and each suite.
  def test_pipeline_estimates_use_median_of_latest_three_files
    with_pipeline_workspace do |workspace, pipeline, _runner, out, _err, front|
      [[1000, 2000], [10, 90], [30, 110], [20, 100]].each_with_index do |(fast, integration), index|
        write_pipeline_timing_fixture(front, index, {
          "result" => "pass", "elapsed_seconds" => fast + integration,
          "suites" => {"fast" => {"result" => "pass", "elapsed_seconds" => fast},
                       "integration" => {"result" => "pass", "elapsed_seconds" => integration}}
        })
      end
      workspace.instance_variable_set(:@test_duration_history, workspace.send(:load_test_duration_history))
      assert_equal 120.0, workspace.send(:test_duration_hint_seconds, pipeline)
      workspace.send(:test_suites, pipeline).each_with_index do |suite, index|
        assert_equal [20.0, 100.0][index], workspace.send(:test_duration_hint_seconds, suite)
        workspace.send(:print_test_start, suite, started: index + 1, total: 2)
      end
      assert_match(/^⠋ \[1\/2\] af-data-pipeline \/ fast\s+~20s$/, out.string)
      assert_match(/^⠋ \[2\/2\] af-data-pipeline \/ integration\s+~100s$/, out.string)
      other = {"name" => "other", "test_duration_hint_seconds" => 110.0}
      assert_equal [pipeline, other], workspace.send(:prioritized_testables, [other, pipeline]).map(&:first)
    end
  end

  # Legacy aggregates, malformed suite maps/rows, and unusable values must not
  # borrow repository estimates. A valid peer remains readable in every case.
  def test_pipeline_legacy_and_invalid_suite_history_has_no_fallback_estimate
    invalid_rows = [nil, [], "bad", {"result" => "fail", "elapsed_seconds" => 42}]
    [nil, "bad", [], {}, -1, Float::NAN, Float::INFINITY, -Float::INFINITY].each do |elapsed|
      invalid_rows << {"result" => "pass", "elapsed_seconds" => elapsed}
    end
    suite_maps = [nil, [], "bad", {}] + invalid_rows.map do |sample|
      {"fast" => sample, "integration" => {"result" => "pass", "elapsed_seconds" => "0.44"}}
    end
    suite_maps.each do |suites|
      with_pipeline_workspace do |workspace, pipeline, _runner, out, _err, front|
        row = {"result" => "pass", "elapsed_seconds" => 999.0}
        row["suites"] = suites unless suites.nil?
        write_pipeline_timing_fixture(front, 1, row)
        workspace.instance_variable_set(:@test_duration_history, workspace.send(:load_test_duration_history))
        assert_equal 999.0, workspace.send(:test_duration_hint_seconds, pipeline)
        descriptors = workspace.send(:test_suites, pipeline)
        assert_equal 0.0, workspace.send(:test_duration_hint_seconds, descriptors.first)
        descriptors.each_with_index { |suite, index| workspace.send(:print_test_start, suite, started: index + 1, total: 2) }
        refute out.string.lines.first.include?("~")
        if suites.is_a?(Hash) && suites.key?("integration")
          assert_match(/^⠋ \[2\/2\] af-data-pipeline \/ integration\s+~1s$/, out.string)
        else
          refute_includes out.string, "~"
        end
      end
    end
  end

  # Failed, missing and NOT RUN samples retain their actual accounting while
  # only successful samples contribute; either suite may be the failing peer.
  def test_pipeline_history_excludes_failed_and_unexecuted_suites_independently
    %w[fast integration].each do |unsuccessful|
      [:fail, :not_run, :missing].each do |status|
        with_pipeline_workspace do |workspace, pipeline, _runner, _out, _err, front|
          write_pipeline_timing_fixture(front, 0, {
            "result" => "pass", "elapsed_seconds" => 60.0,
            "suites" => {"fast" => {"result" => "pass", "elapsed_seconds" => 10.0},
                         "integration" => {"result" => "pass", "elapsed_seconds" => 50.0}}
          })
          results = %w[fast integration].map do |suite|
            failed = suite == unsuccessful
            elapsed = failed ? (status == :fail ? 200.0 : nil) : (suite == "fast" ? 30.0 : 70.0)
            AdventureFinderWorkspace::Workspace::TestResult.new(name: "af-data-pipeline",
              suite: suite, result: failed ? status : :pass, elapsed: elapsed)
          end
          workspace.send(:record_test_timing_history, results, workspace_elapsed: 1.0, jobs: 2)
          history = YAML.safe_load(File.read(Dir.glob("#{front}/output/af-test/run-*.yml").sort.last))
          row = history.fetch("repositories").fetch("af-data-pipeline")
          assert_equal status.to_s, row.fetch("result")
          assert_equal results.sum { |result| result.elapsed || 0.0 }, row.fetch("elapsed_seconds")
          results.each do |result|
            assert_equal({"result" => result.result.to_s, "elapsed_seconds" => result.elapsed}, row.fetch("suites").fetch(result.suite))
          end
          workspace.instance_variable_set(:@test_duration_history, workspace.send(:load_test_duration_history))
          assert_equal 60.0, workspace.send(:test_duration_hint_seconds, pipeline)
          hints = workspace.send(:test_suites, pipeline).map { |suite| workspace.send(:test_duration_hint_seconds, suite) }
          assert_equal unsuccessful == "fast" ? [10.0, 60.0] : [20.0, 50.0], hints
        end
      end
    end
  end

  # Writes one controlled history row under a sortable filename in a disposable
  # front door. Returns bytes written; filesystem errors propagate to the test.
  def write_pipeline_timing_fixture(front, index, row)
    directory = File.join(front, "output", "af-test")
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, "run-#{index}.yml"), {
      "schema_version" => AdventureFinderWorkspace::TEST_TIMING_HISTORY_SCHEMA_VERSION,
      "repositories" => {"af-data-pipeline" => row}
    }.to_yaml)
  end

  # Rejects a lying aggregate while keeping observed worker counts and separate
  # invocations. No captured output can substitute a stale on-disk report.
  def test_mismatched_worker_aggregate_does_not_replace_observed_subtotals
    with_pipeline_workspace do |workspace, _pipeline, _runner, _out, err|
      output = self.class.worker_output("integration (functional)", runs: 1, assertions: 3)
      output = output.sub("Finished in 0.010000s across all workers.\n1 runs",
        "Finished in 0.010000s across all workers.\n99 runs")
      output += "2 runs, 7 assertions, 0 failures, 0 errors, 0 skips\n"
      result = AdventureFinderWorkspace::Workspace::TestResult.new(name: "af-data-pipeline",
        suite: "integration", result: :fail, output: output)
      totals = workspace.send(:aggregate_minitest_totals, [result])
      assert_equal({runs: 0, assertions: 0, failures: 0, errors: 0, skips: 0}, totals)
      assert_includes err.string, "validated observed test counts unknown"
    end
  end

  # A runner may capture stderr separately; both streams must survive each gate
  # without turning independent dependency test summaries into worker subtotals.
  def test_pipeline_keeps_stderr_and_ignores_old_report_files
    runner_class = Class.new(RecordingRunner) do
      # Adds a diagnostic to the normal fake result without executing a command.
      def shell_capture(command, chdir:, env: {})
        result = super
        result.stderr = "diagnostic from #{command}\n"
        result
      end
    end
    with_pipeline_workspace(runner: runner_class.new) do |workspace, pipeline, _runner, out|
      report = workspace.root / "af-data-pipeline" / "coverage" / "full"
      FileUtils.mkdir_p(report)
      File.write(report / ".resultset.json", "999 runs, 999 assertions, 0 failures, 0 errors, 0 skips\n")
      assert workspace.test(repos: [pipeline], include_front_door: false)
      assert_includes out.string, "diagnostic from bundle exec rake\n"
      assert_includes out.string, "diagnostic from bundle exec rake test:integration\n"
      assert_match(/^Total runs:\s+8$/, out.string)
      assert_match(/^Total assertions:\s+14$/, out.string)
    end
  end

  # Exercises the repository aliases and an installed wrapper from a different
  # directory using a shell-only recorder; no component or Ruby command runs.
  def test_repository_aliases_and_installed_wrapper_keep_their_job_counts
    Dir.mktmpdir do |directory|
      bin = File.join(directory, "checkout", "bin")
      FileUtils.mkdir_p(bin)
      %w[af-test af-test-3 af-test-4 install-af-test-command].each do |name|
        FileUtils.cp(File.expand_path("../bin/#{name}", __dir__), bin)
      end
      File.write(File.join(bin, "af-workspace"), "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$@\"\n")
      File.chmod(0o755, File.join(bin, "af-workspace"))
      %w[af-test af-test-3 af-test-4].zip([[], ["-j", "3"], ["-j", "4"]]).each do |name, jobs|
        output, status = Open3.capture2e(File.join(bin, name), "--core", chdir: directory)
        assert status.success?, output
        assert_equal [File.realpath(directory), "test", *jobs, "--core"], output.lines.map(&:chomp)
      end
      installed = File.join(directory, "user-bin")
      output, status = Open3.capture2e({"AF_USER_BIN" => installed},
        File.join(bin, "install-af-test-command"), chdir: directory)
      assert status.success?, output
      output, status = Open3.capture2e(File.join(installed, "af-test"), "--comprehensive", chdir: directory)
      assert status.success?, output
      assert_equal [File.realpath(directory), "test", "-j", "3", "--comprehensive"], output.lines.map(&:chomp)
    end
  end

  def test_default_and_comprehensive_use_detached_front_door_and_truthful_counts
    Dir.mktmpdir do |dir|
      components = File.join(dir, "components")
      front = File.join(dir, "detached-front")
      FileUtils.mkdir_p(File.join(front, "lib"))
      FileUtils.mkdir_p(File.join(front, "bin"))
      File.write(File.join(front, "Rakefile"), "")
      File.write(File.join(front, "lib", "adventure_finder_workspace.rb"), "")
      File.write(File.join(front, "bin", "af-operator-acceptance"), "")
      configured = manifest.selected.select { |repo| repo["test"] }
      assert_equal 10, configured.length
      configured.each { |repo| FileUtils.mkdir_p(File.join(components, repo.fetch("name"), ".git")) }
      runner = RecordingRunner.new
      out = StringIO.new
      workspace = AdventureFinderWorkspace::Workspace.new(manifest: manifest, root: components,
        front_door_root: front, runner: runner, out: out, err: StringIO.new)
      Dir.chdir(dir) { assert workspace.test(repos: manifest.selected) }
      expected_commands = configured.flat_map do |repo|
        repo["name"] == "af-data-pipeline" ? ["bundle exec rake", "bundle exec rake test:integration"] : [repo.fetch("test")]
      end
      assert_equal expected_commands + ["rake"], runner.calls.map(&:first)
      assert_equal front, runner.calls.last[1]
      assert_equal components, runner.calls.last[2]["AF_PROJECT_ROOT"]
      assert_equal front, runner.calls.last[2]["AF_ADVENTURE_FINDER_ROOT"]
      assert_nil runner.calls.last[2]["BUNDLE_GEMFILE"]
      refute File.exist?(File.join(front, "Gemfile"))
      assert_includes out.string, "Unconfigured selected entries: 4"
      assert_includes out.string, "12/12 suites passed."
      assert_match(/^Total runs:\s+28$/, out.string)
      assert_includes out.string, "Operator acceptance phase: NOT RUN"
      assert workspace.test(repos: manifest.selected, comprehensive: true)
      assert_equal 25, runner.calls.length
      assert_equal "#{front}/bin/af-operator-acceptance --root #{components}", runner.calls.last.first
      assert_includes out.string, "Operator acceptance phase: PASS"
      assert_equal 2, out.string.scan(/^Total runs:\s+28$/).length
      # A runtime-gated component failure must not hide acceptance or become PASS.
      failed_component = RecordingRunner.new(fail_command: configured.first.fetch("test"))
      failed_out = StringIO.new
      failed_workspace = AdventureFinderWorkspace::Workspace.new(manifest: manifest, root: components,
        front_door_root: front, runner: failed_component, out: failed_out, err: StringIO.new)
      refute failed_workspace.test(repos: manifest.selected, comprehensive: true)
      assert_equal 13, failed_component.calls.length
      assert_includes failed_out.string, "Component phase: 8/10 passed"
      assert_includes failed_out.string, "Front-door phase: PASS"
      assert_includes failed_out.string, "Operator acceptance phase: PASS"
      FileUtils.rm_f(File.join(front, "bin", "af-operator-acceptance"))
      refute failed_workspace.test(repos: [], comprehensive: true)
      assert_includes failed_out.string, "Operator acceptance phase: MISSING"
      File.write(File.join(front, "bin", "af-operator-acceptance"), "")
      failing = RecordingRunner.new(fail_command: runner.calls.last.first)
      workspace = AdventureFinderWorkspace::Workspace.new(manifest: manifest, root: components,
        front_door_root: front, runner: failing, out: StringIO.new, err: StringIO.new)
      refute workspace.test(repos: [], comprehensive: true)
    end
  end

  def test_missing_front_door_and_serial_fail_fast_report_unexecuted_work
    Dir.mktmpdir do |dir|
      runner = RecordingRunner.new
      out = StringIO.new
      err = StringIO.new
      workspace = AdventureFinderWorkspace::Workspace.new(manifest: manifest, root: dir,
        front_door_root: File.join(dir, "absent"), runner: runner, out: out, err: err)
      refute workspace.test(repos: [])
      assert_empty runner.calls
      assert_includes out.string, "Front-door phase: MISSING"
      assert_includes err.string, "invalid or missing suite root"
      refute workspace.test(repos: [{"name" => "missing", "test" => "bin/test"}],
        fail_fast: true, comprehensive: true)
      assert_includes out.string, "Unexecuted suites: adventure-finder"
      assert_includes out.string, "Operator acceptance phase: NOT RUN (fail-fast)"
      assert_empty runner.calls
    end
  end

  def test_cli_front_door_environment_and_explicit_override_from_other_directory
    Dir.mktmpdir do |dir|
      front = File.join(dir, "front")
      tools = File.join(dir, "tools")
      FileUtils.mkdir_p(File.join(front, "lib"))
      FileUtils.mkdir_p(tools)
      File.write(File.join(front, "Rakefile"), "")
      File.write(File.join(front, "lib", "adventure_finder_workspace.rb"), "")
      fake_rake = File.join(tools, "rake")
      File.write(fake_rake, "#!/bin/sh\nprintf '2 runs, 3 assertions, 0 failures, 0 errors, 0 skips\\n'\n")
      File.chmod(0o755, fake_rake)
      cli = File.expand_path("../bin/af-test", __dir__)
      environment = {"AF_PROJECT_ROOT" => File.join(dir, "empty-components"),
        "AF_ADVENTURE_FINDER_ROOT" => front, "PATH" => "#{tools}:#{ENV.fetch('PATH')}"}
      output, status = Open3.capture2e(environment, cli, chdir: dir)
      refute status.success?, "missing configured components must fail"
      assert_includes output, "Front-door phase: PASS"
      assert_includes output, "Unconfigured selected entries: 4"
      output, status = Open3.capture2e(environment, cli, "--front-door-root", File.join(dir, "absent"), chdir: dir)
      refute status.success?
      assert_includes output, "Front-door phase: MISSING"
      refute_includes output, "Front-door phase: PASS"
    end
  end

  def test_manifest_schema_and_unique_repository_names
    assert_equal "adventurefinder-workspace/v0.1", manifest.data["schema_version"]
    names = manifest.repositories.map { |repo| repo.fetch("name") }
    assert_equal names.uniq.sort, names.sort
    refute_includes names, "af-inference-orchestrator"
  end

  def test_repository_owned_safety_sweeps_use_default_rake_task
    %w[
      af-data-pipeline
      af-workloads
      workload-orchestrator
      runpod-ollama-fleet
    ].each do |name|
      repo = manifest.repositories.find { |entry| entry.fetch("name") == name }

      assert_equal "bundle exec rake", repo.fetch("test"), name
    end
  end

  def test_default_selection_excludes_archived_and_experimental_repos
    names = manifest.selected.map { |repo| repo.fetch("name") }

    assert_includes names, "af-data-pipeline"
    assert_includes names, "llm-response-data"
    assert_includes names, "af-workloads"
    assert_includes names, "workload-orchestrator"
    assert_includes names, "runpod-ollama-fleet"
    refute_includes names, "af-inference-orchestrator"
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
    assert_includes names, "af-workloads"
    refute_includes names, "workload-orchestrator"
    assert_includes names, "af-frontier-pack"
    refute_includes names, "runpod-ollama-fleet"
    refute_includes names, "llm-response-data"
  end

  def test_afw_and_wlo_setup_is_current_without_stale_timing_hints
    %w[af-workloads workload-orchestrator].each do |name|
      repo = manifest.repositories.find { |entry| entry.fetch("name") == name }

      assert_equal "dtnorris/#{name}", repo.fetch("github")
      assert_equal "current", repo.fetch("lifecycle")
      assert_equal "bundle install", repo.fetch("setup")
      assert_equal %w[ruby bundle git], repo.fetch("requires")
      refute repo.key?("test_duration_hint_seconds"), name
    end
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
        front_door_root: File.join(dir, "adventure-finder"),
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
        front_door_root: File.join(dir, "adventure-finder"),
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
      attr_reader :env

      def shell_capture(_command, chdir:, env: {})
        @env = env
        AdventureFinderWorkspace::CommandRunner::Result.new(stdout: "", stderr: "", status: AdventureFinderWorkspaceTest::FakeStatus.new(true))
      end
    end

    repo = {"name" => "timed-suite", "test" => "bin/test"}

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "timed-suite", ".git"))

      runner = runner_class.new
      out = StringIO.new
      workspace = AdventureFinderWorkspace::Workspace.new(
        manifest: manifest,
        root: dir,
        front_door_root: File.join(dir, "adventure-finder"),
        runner: runner,
        out: out,
        err: StringIO.new
      )

      assert workspace.test(include_front_door: false, repos: [repo])
      assert_nil runner.env["AF_TEST_CONTENDED"]
      assert_match(/^timed-suite\s+PASS\s+\d+\.\d{2}s$/, out.string)
      assert_match(/^1\/1 suites passed\.$/, out.string)
      assert_match(/^Test jobs:\s+1$/, out.string)
      assert_match(/^Cumulative suite time:\s+\d+\.\d{2}s$/, out.string)
      assert_match(/^Workspace wall time:\s+\d+\.\d{2}s$/, out.string)

      history_files = Dir.glob(File.join(dir, "adventure-finder", "output", "af-test", "run-*.yml"))
      assert_equal 1, history_files.length
      history = YAML.safe_load(File.read(history_files.first), permitted_classes: [], aliases: false)
      assert_equal AdventureFinderWorkspace::TEST_TIMING_HISTORY_SCHEMA_VERSION, history["schema_version"]
      assert_equal 1, history["jobs"]
      assert_equal "pass", history.dig("repositories", "timed-suite", "result")
      assert_operator history.dig("repositories", "timed-suite", "elapsed_seconds"), :>=, 0.0
    end
  end

  def test_parallel_cross_repo_tests_respect_job_limit_and_buffer_output_in_completion_order
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
        front_door_root: File.join(dir, "adventure-finder"),
        runner: runner,
        out: out,
        err: StringIO.new
      )

      assert workspace.test(include_front_door: false, repos: repos, jobs: 3)
      assert_equal 3, runner.max_active
      assert runner.envs.all? { |env| env["AF_TEST_CONTENDED"] == "1" }

      start_lines = out.string.lines.grep(/^⠋ \[/)
      assert_equal repos.length, start_lines.length
      start_lines.each_with_index do |line, index|
        assert_match(/^⠋ \[#{index + 1}\/#{repos.length}\] /, line)
      end

      completion_lines = out.string.lines.grep(/^✓ \[/)
      assert_equal repos.length, completion_lines.length
      completion_names = completion_lines.map do |line|
        line[/^✓ \[\d+\/\d+\] (\S+)/, 1]
      end

      running_position = out.string.index("Running 5 repository test suites with 3 jobs...")
      first_start_position = out.string.index("⠋ [1/5]")
      first_completion_position = out.string.index("✓ [")
      first_header_position = out.string.index("=== #{completion_names.first}: bin/test ===")
      assert_operator running_position, :<, first_start_position
      assert_operator first_start_position, :<, first_completion_position
      assert_operator first_completion_position, :<, first_header_position

      header_names = out.string.lines.grep(/^=== suite-/).map do |line|
        line[/^=== ([^:]+): /, 1]
      end
      assert_equal completion_names, header_names

      summary = out.string.split("=== AdventureFinder cross-repo test summary ===\n", 2).last
      summary_names = summary.lines.filter_map do |line|
        line[/^(suite-\S+)\s+(?:PASS|FAIL|MISSING)\b/, 1]
      end
      assert_equal completion_names, summary_names
      assert_match(/^5\/5 suites passed\.$/, out.string)
      assert_match(/^Test jobs:\s+3$/, out.string)
    end
  end

  def test_wlo_contention_signal_is_scoped_to_parallel_repository_testing
    repos = %w[workload-orchestrator runpod-ollama-fleet af-workloads].map do |name|
      {"name" => name, "test" => "bundle exec rake"}
    end

    Dir.mktmpdir do |dir|
      repos.each { |repo| FileUtils.mkdir_p(File.join(dir, repo.fetch("name"), ".git")) }
      runner = ParallelTestRunner.new(fail_names: ["runpod-ollama-fleet"], delay: 0.01)
      out = StringIO.new
      workspace = AdventureFinderWorkspace::Workspace.new(
        manifest: manifest, root: dir, front_door_root: File.join(dir, "adventure-finder"),
        runner: runner, out: out, err: StringIO.new
      )

      refute workspace.test(include_front_door: false, repos: repos, jobs: 3)
      assert_equal 3, runner.max_active
      parallel_envs = runner.calls.to_h
      assert_equal "1", parallel_envs.fetch("workload-orchestrator")["WLO_TEST_CONTENDED"]
      parallel_envs.each_value { |env| assert_equal "1", env["AF_TEST_CONTENDED"] }
      assert_nil parallel_envs.fetch("runpod-ollama-fleet")["WLO_TEST_CONTENDED"]
      assert_nil parallel_envs.fetch("af-workloads")["WLO_TEST_CONTENDED"]
      assert_match(/^runpod-ollama-fleet\s+FAIL\s+\d+\.\d{2}s$/, out.string)
      assert_match(/^2\/3 suites passed\.$/, out.string)

      serial_runner = ParallelTestRunner.new(delay: 0)
      serial_workspace = AdventureFinderWorkspace::Workspace.new(
        manifest: manifest, root: dir, front_door_root: File.join(dir, "adventure-finder"),
        runner: serial_runner, out: StringIO.new, err: StringIO.new
      )
      assert serial_workspace.test(include_front_door: false, repos: repos, jobs: 1)
      serial_runner.calls.each do |_name, env|
        assert_nil env["AF_TEST_CONTENDED"]
        assert_nil env["WLO_TEST_CONTENDED"]
      end

      lone_runner = ParallelTestRunner.new(delay: 0)
      lone_workspace = AdventureFinderWorkspace::Workspace.new(
        manifest: manifest, root: dir, front_door_root: File.join(dir, "adventure-finder"),
        runner: lone_runner, out: StringIO.new, err: StringIO.new
      )
      assert lone_workspace.test(include_front_door: false, repos: [repos.first], jobs: 3)
      assert_nil lone_runner.calls.first.last["AF_TEST_CONTENDED"]
      assert_nil lone_runner.calls.first.last["WLO_TEST_CONTENDED"]
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

  def test_parallel_cross_repo_tests_use_median_of_latest_three_timing_records
    repos = [
      {"name" => "suite-a", "test" => "bin/test", "test_duration_hint_seconds" => 20.0},
      {"name" => "suite-b", "test" => "bin/test", "test_duration_hint_seconds" => 1.0}
    ]

    Dir.mktmpdir do |dir|
      history_dir = File.join(dir, "adventure-finder", "output", "af-test")
      FileUtils.mkdir_p(history_dir)
      records = [
        ["run-1.yml", {"suite-a" => 99.0, "suite-b" => 1.0}],
        ["run-2.yml", {"suite-a" => 2.0, "suite-b" => 8.0}],
        ["run-3.yml", {"suite-a" => 4.0, "suite-b" => 6.0}],
        ["run-4.yml", {"suite-a" => 3.0, "suite-b" => 7.0}]
      ]
      records.each do |filename, timings|
        payload = {
          "schema_version" => AdventureFinderWorkspace::TEST_TIMING_HISTORY_SCHEMA_VERSION,
          "repositories" => timings.transform_values do |elapsed|
            {"result" => "pass", "elapsed_seconds" => elapsed}
          end
        }
        File.write(File.join(history_dir, filename), payload.to_yaml)
      end

      out = StringIO.new
      workspace = AdventureFinderWorkspace::Workspace.new(
        manifest: manifest,
        root: dir,
        front_door_root: File.join(dir, "adventure-finder"),
        out: out,
        err: StringIO.new
      )
      history = workspace.send(:load_test_duration_history)
      workspace.instance_variable_set(:@test_duration_history, history)

      assert_in_delta 3.0, workspace.send(:test_duration_hint_seconds, repos[0]), 0.001
      assert_in_delta 7.0, workspace.send(:test_duration_hint_seconds, repos[1]), 0.001
      prioritized = workspace.send(:prioritized_testables, repos)
      assert_equal %w[suite-b suite-a], prioritized.map { |repo, _index| repo.fetch("name") }

      workspace.send(:print_test_start, repos[0], started: 1, total: 2)
      workspace.send(:print_test_start, repos[1], started: 2, total: 2)
      assert_match(/^⠋ \[1\/2\] suite-a\s+~3s$/, out.string)
      assert_match(/^⠋ \[2\/2\] suite-b\s+~7s$/, out.string)
    end
  end

  def test_parallel_test_start_renders_rounded_duration_hint
    out = StringIO.new
    workspace = AdventureFinderWorkspace::Workspace.new(
      manifest: manifest,
      root: Dir.tmpdir,
      out: out,
      err: StringIO.new
    )

    workspace.send(
      :print_test_start,
      {"name" => "suite-a", "test_duration_hint_seconds" => 9.15},
      started: 1,
      total: 2
    )
    workspace.send(
      :print_test_start,
      {"name" => "suite-b", "test_duration_hint_seconds" => 0.44},
      started: 2,
      total: 2
    )

    lines = out.string.lines
    assert_match(/^⠋ \[1\/2\] suite-a\s+~9s$/, lines[0])
    assert_match(/^⠋ \[2\/2\] suite-b\s+~1s$/, lines[1])
    refute_match(/hint|\.\d+s/, out.string)
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
        front_door_root: File.join(dir, "adventure-finder"),
        runner: ParallelTestRunner.new(fail_names: ["suite-b"], delay: 0.01),
        out: out,
        err: StringIO.new
      )

      refute workspace.test(include_front_door: false, repos: repos, jobs: 2)
      assert_match(/^suite-a\s+PASS\s+\d+\.\d{2}s$/, out.string)
      assert_match(/^suite-b\s+FAIL\s+\d+\.\d{2}s$/, out.string)
      assert_match(/^suite-c\s+PASS\s+\d+\.\d{2}s$/, out.string)
      assert_match(/^2\/3 suites passed\.$/, out.string)
      assert_match(/^✗ \[\d+\/3\] suite-b\s+\d+\.\d{2}s$/, out.string)
    end
  end

  def test_cross_repo_test_summary_rolls_up_minitest_counts
    result_class = AdventureFinderWorkspace::Workspace::TestResult
    results = [
      result_class.new(
        name: "suite-a",
        result: :pass,
        elapsed: 1.0,
        output: <<~OUTPUT
          10 runs, 20 assertions, 1 failures, 2 errors, 3 skips
          4 runs, 8 assertions, 0 failures, 0 errors, 1 skips
        OUTPUT
      ),
      result_class.new(
        name: "suite-b",
        result: :pass,
        elapsed: 2.0,
        output: "6 runs, 12 assertions, 2 failures, 1 errors, 0 skips\n"
      )
    ]
    out = StringIO.new
    workspace = AdventureFinderWorkspace::Workspace.new(
      manifest: manifest,
      root: Dir.tmpdir,
      out: out,
      err: StringIO.new
    )

    workspace.send(:print_test_summary, results, workspace_elapsed: 2.0, jobs: 2)

    assert_match(/^Total runs:\s+20$/, out.string)
    assert_match(/^Total assertions:\s+40$/, out.string)
    assert_match(/^Total failures:\s+3$/, out.string)
    assert_match(/^Total errors:\s+3$/, out.string)
    assert_match(/^Total skips:\s+4$/, out.string)
  end

  def test_worker_aggregate_replaces_twelve_subtotals_and_retains_independent_invocations
    workers = 12.times.map do |index|
      assertions = index == 11 ? 367 : 360
      "Worker #{index + 1}:\nFinished in 15.0s\n41 runs, #{assertions} assertions, 0 failures, 0 errors, 0 skips\n"
    end.join
    captured = "Running 492 tests in 12 isolated Ruby workers (seed 123)\n#{workers}" \
      "Finished in 15.000000s across all workers.\n492 runs, 4327 assertions, 0 failures, 0 errors, 0 skips\n"
    err = StringIO.new
    workspace = AdventureFinderWorkspace::Workspace.new(manifest: manifest, root: Dir.tmpdir,
      out: StringIO.new, err: err)
    result = AdventureFinderWorkspace::Workspace::TestResult.new(name: "other-component", result: :pass, output: captured)
    expected = {runs: 492, assertions: 4327, failures: 0, errors: 0, skips: 0}
    assert_equal expected, workspace.send(:aggregate_minitest_totals, [result])
    assert_empty err.string
    independent = "2 runs, 7 assertions, 1 failures, 0 errors, 1 skips\n"
    result.output = independent + captured + independent + captured
    assert_equal({runs: 988, assertions: 8668, failures: 2, errors: 0, skips: 2},
      workspace.send(:aggregate_minitest_totals, [result]))
  end

  def test_missing_or_unparseable_worker_aggregate_reports_observed_counts_and_warning
    err = StringIO.new
    workspace = AdventureFinderWorkspace::Workspace.new(manifest: manifest, root: Dir.tmpdir,
      out: StringIO.new, err: err)
    result = AdventureFinderWorkspace::Workspace::TestResult.new(name: "fixture", result: :fail,
      output: "Running 2 tests in 1 isolated Ruby workers (seed 1)\nWorker 1:\n" \
        "2 runs, 7 assertions, 0 failures, 0 errors, 0 skips\nFinished in 1.0s across all workers.\n" \
        "unparseable\nRun options: --seed 2\n3 runs, 8 assertions, 0 failures, 0 errors, 1 skips\n")
    assert_equal 5, workspace.send(:aggregate_minitest_totals, [result]).fetch(:runs)
    assert_includes err.string, "worker aggregate summary missing"
    result.output = "unparseable"
    assert_equal 0, workspace.send(:aggregate_minitest_totals, [result]).fetch(:runs)
    assert_includes err.string, "test counts unknown"
    assert_equal :fail, result.result
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
        front_door_root: File.join(dir, "adventure-finder"),
        runner: ParallelTestRunner.new(delay: 0.01),
        out: out,
        err: StringIO.new
      )

      refute workspace.test(include_front_door: false, repos: repos, jobs: 2)
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
      workspace.test(include_front_door: false, repos: [], jobs: 0)
    end
    assert_raises(AdventureFinderWorkspace::Error) do
      workspace.test(include_front_door: false, repos: [], jobs: 2, fail_fast: true)
    end
  end

  def test_unknown_clone_protocol_fails_closed
    Dir.mktmpdir do |dir|
      workspace = AdventureFinderWorkspace::Workspace.new(
        manifest: manifest,
        root: dir,
        front_door_root: File.join(dir, "adventure-finder"),
        out: StringIO.new,
        err: StringIO.new
      )
      assert_raises(AdventureFinderWorkspace::Error) do
        workspace.clone_url({"github" => "dtnorris/af-data-pipeline"}, "ftp")
      end
    end
  end
end
