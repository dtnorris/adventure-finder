# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "pathname"
require "thread"
require "time"
require "yaml"

module AdventureFinderWorkspace
  SCHEMA_VERSION = "adventurefinder-workspace/v0.1"
  TEST_TIMING_HISTORY_SCHEMA_VERSION = "adventurefinder-test-timings/v0.1"
  TEST_TIMING_HISTORY_LIMIT = 3

  class Error < StandardError; end

  class Manifest
    attr_reader :path, :data

    def initialize(path)
      @path = Pathname(path).expand_path
      @data = YAML.safe_load(@path.read, permitted_classes: [], aliases: false)
      validate!
    rescue Psych::SyntaxError => e
      raise Error, "invalid YAML in #{@path}: #{e.message}"
    end

    def workspace_root_default
      data.fetch("workspace_root_default")
    end

    def repositories
      data.fetch("repositories")
    end

    def selected(all: false, core: false)
      repos =
        if all
          repositories
        elsif core
          repositories.select { |repo| Array(repo["groups"]).include?("core") }
        else
          repositories.select { |repo| repo["default"] == true }
        end
      repos.sort_by { |repo| repo.fetch("name") }
    end

    private

    def validate!
      raise Error, "manifest must be a mapping" unless data.is_a?(Hash)
      unless data["schema_version"] == SCHEMA_VERSION
        raise Error, "unsupported schema_version #{data['schema_version'].inspect}; expected #{SCHEMA_VERSION}"
      end
      raise Error, "workspace_root_default is required" if data["workspace_root_default"].to_s.empty?
      raise Error, "repositories must be an array" unless data["repositories"].is_a?(Array)

      names = {}
      data["repositories"].each_with_index do |repo, index|
        raise Error, "repository entry #{index + 1} must be a mapping" unless repo.is_a?(Hash)
        %w[name github role lifecycle default].each do |key|
          raise Error, "repository entry #{index + 1} missing #{key}" unless repo.key?(key)
        end
        name = repo["name"]
        raise Error, "duplicate repository #{name}" if names[name]

        names[name] = true
        unless repo["github"].to_s.match?(%r{\A[^/]+/[^/]+\z})
          raise Error, "#{name}: github must be owner/repo"
        end
        if repo.key?("clone_depth") && (!repo["clone_depth"].is_a?(Integer) || repo["clone_depth"] < 1)
          raise Error, "#{name}: clone_depth must be a positive integer"
        end
      end
    end
  end

  class CommandRunner
    Result = Struct.new(:stdout, :stderr, :status, keyword_init: true) do
      def success?
        status.success?
      end
    end

    def capture(*argv, chdir: nil)
      options = {}
      options[:chdir] = chdir.to_s if chdir
      stdout, stderr, status = Open3.capture3(*argv, **options)
      Result.new(stdout: stdout, stderr: stderr, status: status)
    end

    def system(*argv, chdir: nil, env: {})
      options = {}
      options[:chdir] = chdir.to_s if chdir
      Kernel.system(env, *argv, **options)
    end

    def shell(command, chdir:, env: {})
      # Deliberately use a non-login shell. A login shell may rebuild PATH from
      # profile files and silently replace the caller's mise/asdf/Homebrew
      # runtimes with macOS system Ruby/Python. Workspace commands should run
      # in the environment the operator actually invoked AdventureFinder from.
      system("/bin/sh", "-c", command, chdir: chdir, env: env)
    end

    def shell_capture(command, chdir:, env: {})
      options = {}
      options[:chdir] = chdir.to_s if chdir
      output, status = Open3.capture2e(env, "/bin/sh", "-c", command, **options)
      Result.new(stdout: output, stderr: "", status: status)
    end
  end

  class Workspace
    TestResult = Struct.new(:name, :command, :result, :elapsed, :output, keyword_init: true)

    attr_reader :manifest, :root, :runner, :out, :err

    def initialize(manifest:, root:, runner: CommandRunner.new, out: $stdout, err: $stderr)
      @manifest = manifest
      @root = Pathname(root).expand_path
      @runner = runner
      @out = out
      @err = err
    end

    def bootstrap(repos:, protocol: "ssh", setup: false)
      FileUtils.mkdir_p(root)
      failures = []

      repos.each do |repo|
        name = repo.fetch("name")
        path = repo_path(repo)

        if path.directory? && (path / ".git").directory?
          out.puts format("%-30s already present", name)
        elsif path.exist?
          err.puts format("%-30s ERROR: path exists but is not a Git checkout: %s", name, path)
          failures << name
          next
        else
          argv = ["git", "clone"]
          depth = repo["clone_depth"]
          argv.concat(["--depth", depth.to_s]) if depth
          argv.concat([clone_url(repo, protocol), path.to_s])

          out.puts format("%-30s cloning%s", name, depth ? " (depth #{depth})" : "")
          unless runner.system(*argv, chdir: root)
            failures << name
            next
          end
        end

        next unless setup && repo["setup"]

        out.puts format("%-30s setup: %s", name, repo["setup"])
        unless runner.shell(repo["setup"], chdir: path, env: {"AF_PROJECT_ROOT" => root.to_s})
          failures << "#{name}:setup"
        end
      end

      failures.empty?
    end

    def statuses(repos:)
      repos.map do |repo|
        path = repo_path(repo)
        unless git_checkout?(path)
          next {
            "name" => repo["name"],
            "lifecycle" => repo["lifecycle"],
            "present" => false
          }
        end

        branch_result = runner.capture("git", "symbolic-ref", "--short", "-q", "HEAD", chdir: path)
        branch = branch_result.success? ? branch_result.stdout.strip : "DETACHED"

        sha_result = runner.capture("git", "rev-parse", "--short", "HEAD", chdir: path)
        dirty_result = runner.capture("git", "status", "--porcelain", chdir: path)
        upstream_result = runner.capture("git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}", chdir: path)

        ahead = behind = nil
        upstream = nil
        if upstream_result.success?
          upstream = upstream_result.stdout.strip
          counts = runner.capture("git", "rev-list", "--left-right", "--count", "HEAD...@{u}", chdir: path)
          if counts.success?
            ahead, behind = counts.stdout.split.map(&:to_i)
          end
        end

        {
          "name" => repo["name"],
          "lifecycle" => repo["lifecycle"],
          "present" => true,
          "branch" => branch,
          "sha" => sha_result.success? ? sha_result.stdout.strip : "?",
          "dirty" => !dirty_result.stdout.empty?,
          "upstream" => upstream,
          "ahead" => ahead,
          "behind" => behind
        }
      end
    end

    def print_status(repos:)
      rows = statuses(repos: repos)
      out.puts format("%-30s %-10s %-18s %-9s %-8s %s", "REPOSITORY", "STATE", "BRANCH", "WORKTREE", "A/B", "HEAD")
      rows.each do |row|
        unless row["present"]
          out.puts format("%-30s %-10s %-18s %-9s %-8s %s",
                          row["name"], "missing", "-", "-", "-", "-")
          next
        end
        ab =
          if row["ahead"].nil?
            "-"
          else
            "#{row['ahead']}/#{row['behind']}"
          end
        out.puts format("%-30s %-10s %-18s %-9s %-8s %s",
                        row["name"], row["lifecycle"], row["branch"],
                        row["dirty"] ? "dirty" : "clean", ab, row["sha"])
      end
      true
    end

    def sync(repos:)
      failures = []

      repos.each do |repo|
        name = repo.fetch("name")
        path = repo_path(repo)

        unless git_checkout?(path)
          out.puts format("%-30s missing; skipped", name)
          next
        end

        out.puts format("%-30s fetch --prune", name)
        unless runner.system("git", "fetch", "--prune", chdir: path)
          failures << "#{name}:fetch"
          next
        end

        dirty = !runner.capture("git", "status", "--porcelain", chdir: path).stdout.empty?
        if dirty
          out.puts format("%-30s dirty; fetched but did not pull", name)
          next
        end

        branch = runner.capture("git", "symbolic-ref", "--short", "-q", "HEAD", chdir: path)
        unless branch.success?
          out.puts format("%-30s detached HEAD; fetched but did not pull", name)
          next
        end

        upstream = runner.capture("git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}", chdir: path)
        unless upstream.success?
          out.puts format("%-30s no upstream; fetched but did not pull", name)
          next
        end

        out.puts format("%-30s pull --ff-only", name)
        failures << "#{name}:pull" unless runner.system("git", "pull", "--ff-only", chdir: path)
      end

      failures.empty?
    end

    def test(repos:, fail_fast: false, jobs: 1)
      unless jobs.is_a?(Integer) && jobs >= 1
        raise Error, "jobs must be an integer >= 1"
      end
      raise Error, "fail_fast requires jobs: 1" if fail_fast && jobs != 1

      testable = repos.select { |repo| repo["test"] }
      @test_duration_history = load_test_duration_history
      workspace_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      results = if jobs == 1
                  run_tests_serial(testable, fail_fast: fail_fast)
                else
                  run_tests_parallel(testable, jobs: jobs)
                end
      workspace_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - workspace_started_at

      print_test_summary(results, workspace_elapsed: workspace_elapsed, jobs: jobs)
      record_test_timing_history(results, workspace_elapsed: workspace_elapsed, jobs: jobs)
      results.all? { |result| result.result == :pass }
    end

    def doctor(repos:, strict: false)
      errors = []
      warnings = []

      required = repos.flat_map { |repo| Array(repo["requires"]) }.uniq.sort
      optional = repos.flat_map { |repo| Array(repo["optional_runtime_requires"]) }.uniq.sort

      out.puts "Workspace root: #{root}"
      out.puts
      out.puts "Required commands:"
      required.each do |command|
        if (path = command_path(command))
          out.puts "  PASS #{command} (#{path})#{version_suffix(command)}"
        else
          out.puts "  FAIL #{command}"
          errors << "missing required command: #{command}"
        end
      end

      unless optional.empty?
        out.puts
        out.puts "Optional/runtime-specific commands:"
        optional.each do |command|
          if (path = command_path(command))
            out.puts "  PASS #{command} (#{path})#{version_suffix(command)}"
          else
            out.puts "  WARN #{command}"
            warnings << "missing optional runtime command: #{command}"
          end
        end
      end

      out.puts
      out.puts "Repository checkouts:"
      repos.each do |repo|
        path = repo_path(repo)
        if git_checkout?(path)
          out.puts "  PASS #{repo['name']}"
        else
          out.puts "  WARN #{repo['name']} (missing)"
          warnings << "missing repository: #{repo['name']}"
        end
      end

      validate_project_state(errors, warnings)
      validate_source_registry(warnings)

      out.puts
      out.puts "Doctor summary: #{errors.length} error(s), #{warnings.length} warning(s)."
      warnings.each { |warning| out.puts "  WARN #{warning}" } unless warnings.empty?
      errors.each { |error| out.puts "  FAIL #{error}" } unless errors.empty?

      errors.empty? && (!strict || warnings.empty?)
    end

    def snapshot(repos:, output_path:)
      snapshot = {
        "schema_version" => "adventurefinder-workspace-snapshot/v0.1",
        "created_at" => Time.now.utc.iso8601,
        "workspace_root" => root.to_s,
        "repositories" => {}
      }

      statuses(repos: repos).each do |row|
        snapshot["repositories"][row["name"]] =
          if row["present"]
            {
              "sha" => full_sha(repo_path_by_name(row["name"])),
              "branch" => row["branch"],
              "dirty" => row["dirty"]
            }
          else
            {"present" => false}
          end
      end

      path = Pathname(output_path).expand_path
      FileUtils.mkdir_p(path.dirname)
      path.write(snapshot.to_yaml)
      out.puts path
      true
    end

    def clone_url(repo, protocol)
      github = repo.fetch("github")
      case protocol
      when "ssh"
        "git@github.com:#{github}.git"
      when "https"
        "https://github.com/#{github}.git"
      else
        raise Error, "unsupported Git protocol #{protocol.inspect}; use ssh or https"
      end
    end

    private

    def run_tests_serial(testable, fail_fast:)
      results = []

      testable.each do |repo|
        result = run_test_repo(repo, capture: false)
        results << result
        break if fail_fast && result.result != :pass
      end

      results
    end

    def run_tests_parallel(testable, jobs:)
      results = []
      queue = Queue.new
      progress_mutex = Mutex.new
      started_count = 0
      total_count = testable.length
      # Recent timing history (with manifest fallback) only sets scheduling priority. Result collection
      # happens under the same mutex as completion reporting so buffered output
      # and the final summary follow the visible completion order.
      prioritized_testables(testable).each do |repo, index|
        queue << [index, repo]
      end

      worker_count = [jobs, testable.length].min
      worker_count.times { queue << nil }
      out.puts "Running #{total_count} repository test suites with #{worker_count} jobs..."
      out.flush if out.respond_to?(:flush)

      workers = Array.new(worker_count) do
        Thread.new do
          loop do
            item = queue.pop
            break if item.nil?

            _index, repo = item
            start_number = nil
            progress_mutex.synchronize do
              started_count += 1
              start_number = started_count
              print_test_start(repo, started: start_number, total: total_count)
            end

            result = run_test_repo(repo, capture: true)

            progress_mutex.synchronize do
              print_test_completion(result, started: start_number, total: total_count)
              results << result
            end
          end
        end
      end
      workers.each(&:join)

      results.each { |result| print_buffered_test_output(result) }
      results
    end

    def run_test_repo(repo, capture:)
      name = repo.fetch("name")
      command = repo.fetch("test")
      path = repo_path(repo)

      unless git_checkout?(path)
        return TestResult.new(
          name: name,
          command: command,
          result: :missing,
          elapsed: nil,
          output: nil
        )
      end

      unless capture
        out.puts
        out.puts "=== #{name}: #{command} ==="
      end

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      output = nil
      ok = if capture
             execution = runner.shell_capture(
               command,
               chdir: path,
               env: {"AF_PROJECT_ROOT" => root.to_s}
             )
             output = execution.stdout
             execution.success?
           else
             runner.shell(command, chdir: path, env: {"AF_PROJECT_ROOT" => root.to_s})
           end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      TestResult.new(
        name: name,
        command: command,
        result: ok ? :pass : :fail,
        elapsed: elapsed,
        output: output
      )
    end

    def print_buffered_test_output(result)
      return if result.result == :missing

      out.puts
      out.puts "=== #{result.name}: #{result.command} ==="
      return if result.output.to_s.empty?

      out.print(result.output)
      out.puts unless result.output.end_with?("\n")
    end

    def print_test_summary(results, workspace_elapsed:, jobs:)
      out.puts
      out.puts "=== AdventureFinder cross-repo test summary ==="
      results.each do |result|
        duration = result.elapsed ? format("%.2fs", result.elapsed) : "-"
        out.puts format("%-30s %-7s %8s", result.name, result.result.to_s.upcase, duration)
      end

      failures = results.reject { |result| result.result == :pass }
      passed = results.length - failures.length
      cumulative_elapsed = results.sum { |result| result.elapsed || 0.0 }

      out.puts "#{passed}/#{results.length} suites passed."
      out.puts format("%-30s %8d", "Test jobs:", jobs)
      out.puts format("%-30s %8s", "Cumulative suite time:", format("%.2fs", cumulative_elapsed))
      out.puts format("%-30s %8s", "Workspace wall time:", format("%.2fs", workspace_elapsed))
    end

    def print_test_start(repo, started:, total:)
      hint = test_duration_hint_seconds(repo)
      hint_text = hint.positive? ? format("  ~%ds", [hint.round, 1].max) : ""

      out.puts format(
        "⠋ [%d/%d] %-30s%s",
        started, total, repo.fetch("name"), hint_text
      )
      out.flush if out.respond_to?(:flush)
    end

    def print_test_completion(result, started:, total:)
      marker = case result.result
               when :pass then "✓"
               when :fail then "✗"
               else "!"
               end
      duration = result.elapsed ? format("%.2fs", result.elapsed) : "-"

      out.puts format(
        "%s [%d/%d] %-30s %8s",
        marker, started, total, result.name, duration
      )
      out.flush if out.respond_to?(:flush)
    end

    def prioritized_testables(testable)
      testable.each_with_index.sort_by do |repo, index|
        [-test_duration_hint_seconds(repo), index]
      end
    end

    def test_duration_hint_seconds(repo)
      historical = @test_duration_history&.fetch(repo.fetch("name"), nil)
      return median(historical) if historical && !historical.empty?

      Float(repo.fetch("test_duration_hint_seconds", 0.0))
    end

    def load_test_duration_history
      history = Hash.new { |values, name| values[name] = [] }
      paths = Dir.glob((test_timing_history_dir / "run-*.yml").to_s).sort.last(TEST_TIMING_HISTORY_LIMIT)

      paths.each do |path|
        begin
          data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
        rescue Psych::Exception, SystemCallError
          next
        end
        next unless data.is_a?(Hash) && data["schema_version"] == TEST_TIMING_HISTORY_SCHEMA_VERSION

        repositories = data["repositories"]
        next unless repositories.is_a?(Hash)

        repositories.each do |name, row|
          next unless row.is_a?(Hash) && row["result"] == "pass"

          begin
            elapsed = Float(row["elapsed_seconds"])
          rescue ArgumentError, TypeError
            next
          end
          next unless elapsed.finite? && elapsed >= 0.0

          history[name] << elapsed
        end
      end

      history
    end

    def record_test_timing_history(results, workspace_elapsed:, jobs:)
      directory = test_timing_history_dir
      FileUtils.mkdir_p(directory)
      payload = {
        "schema_version" => TEST_TIMING_HISTORY_SCHEMA_VERSION,
        "created_at" => Time.now.utc.iso8601(6),
        "jobs" => jobs,
        "workspace_elapsed_seconds" => workspace_elapsed.round(6),
        "repositories" => results.each_with_object({}) do |result, repositories|
          repositories[result.name] = {
            "result" => result.result.to_s,
            "elapsed_seconds" => result.elapsed&.round(6)
          }
        end
      }
      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%S.%6NZ")
      (directory / "run-#{timestamp}.yml").write(payload.to_yaml)
    rescue SystemCallError => e
      err.puts "WARN: unable to record test timing history: #{e.message}"
    end

    def test_timing_history_dir
      root / "adventure-finder" / "output" / "af-test"
    end

    def median(values)
      sorted = values.sort
      middle = sorted.length / 2
      return sorted[middle] if sorted.length.odd?

      (sorted[middle - 1] + sorted[middle]) / 2.0
    end

    def repo_path(repo)
      root / repo.fetch("name")
    end

    def repo_path_by_name(name)
      root / name
    end

    def git_checkout?(path)
      path.directory? && (path / ".git").directory?
    end

    def full_sha(path)
      result = runner.capture("git", "rev-parse", "HEAD", chdir: path)
      result.success? ? result.stdout.strip : "?"
    end

    def command_available?(command)
      !command_path(command).nil?
    end

    def command_path(command)
      result = runner.capture("/bin/sh", "-c", "command -v #{shell_escape(command)}")
      return nil unless result.success?

      path = result.stdout.lines.first.to_s.strip
      path.empty? ? nil : path
    end

    def version_suffix(command)
      argv = case command
             when "ruby" then ["ruby", "--version"]
             when "bundle" then ["bundle", "--version"]
             when "git" then ["git", "--version"]
             when "python3" then ["python3", "--version"]
             end
      return "" unless argv

      result = runner.capture(*argv)
      text = [result.stdout, result.stderr].join("\n").lines.map(&:strip).find { |line| !line.empty? }
      text ? " — #{text}" : ""
    end

    def shell_escape(value)
      "'" + value.to_s.gsub("'", %q('"'"')) + "'"
    end

    def validate_project_state(errors, warnings)
      state_path = root / "af-xlsx-data-sources" / "PROJECT_STATE.yml"
      out.puts
      out.puts "Canonical project state:"

      unless state_path.file?
        out.puts "  WARN #{state_path} not found"
        warnings << "PROJECT_STATE.yml unavailable"
        return
      end

      state = YAML.safe_load(state_path.read, permitted_classes: [], aliases: false)
      head = state["catalog_head"]
      unless state["schema_version"].to_s.start_with?("adventurefinder-project-state/")
        out.puts "  FAIL unsupported PROJECT_STATE.yml schema"
        errors << "unsupported PROJECT_STATE.yml schema"
        return
      end
      unless head.is_a?(Hash) && head["filename"] && head["sha256"] && head["bytes"]
        out.puts "  FAIL catalog_head is incomplete"
        errors << "catalog_head is incomplete"
        return
      end

      workbook = state_path.dirname / head["filename"]
      out.puts "  INFO catalog_head #{head['version']} -> #{head['filename']}"
      unless workbook.file?
        out.puts "  FAIL catalog_head workbook missing"
        errors << "catalog_head workbook missing: #{workbook}"
        return
      end

      actual_bytes = workbook.size
      actual_sha = Digest::SHA256.file(workbook).hexdigest
      if actual_bytes == Integer(head["bytes"]) && actual_sha == head["sha256"]
        out.puts "  PASS catalog_head byte size and SHA-256 match PROJECT_STATE.yml"
      else
        out.puts "  FAIL catalog_head integrity mismatch"
        errors << "catalog_head integrity mismatch"
      end
    rescue Psych::SyntaxError, ArgumentError => e
      out.puts "  FAIL unable to validate PROJECT_STATE.yml: #{e.message}"
      errors << "invalid PROJECT_STATE.yml"
    end

    def validate_source_registry(warnings)
      registry = root / "md-for-llm-book-content" / "source_registry.yml"
      out.puts
      out.puts "Canonical source registry:"
      if registry.file?
        out.puts "  PASS #{registry}"
      else
        out.puts "  WARN #{registry} not found"
        warnings << "canonical source registry unavailable"
      end
    end
  end
end
