# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "pathname"
require "time"
require "yaml"

module AdventureFinderWorkspace
  SCHEMA_VERSION = "adventurefinder-workspace/v0.1"

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
  end

  class Workspace
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

    def test(repos:, fail_fast: false)
      testable = repos.select { |repo| repo["test"] }
      results = []

      testable.each do |repo|
        name = repo.fetch("name")
        path = repo_path(repo)

        unless git_checkout?(path)
          results << [name, :missing, nil]
          break if fail_fast
          next
        end

        out.puts
        out.puts "=== #{name}: #{repo['test']} ==="
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        ok = runner.shell(repo["test"], chdir: path, env: {"AF_PROJECT_ROOT" => root.to_s})
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        results << [name, ok ? :pass : :fail, elapsed]
        break if fail_fast && !ok
      end

      out.puts
      out.puts "=== AdventureFinder cross-repo test summary ==="
      results.each do |name, result, elapsed|
        duration = elapsed ? format("%.2fs", elapsed) : "-"
        out.puts format("%-30s %-7s %8s", name, result.to_s.upcase, duration)
      end

      failures = results.select { |_name, result, _elapsed| result != :pass }
      passed = results.length - failures.length
      total_elapsed = results.sum { |_name, _result, elapsed| elapsed || 0.0 }
      summary = "#{passed}/#{results.length} suites passed."
      out.puts format("%-38s %8s", summary, format("%.2fs", total_elapsed))
      failures.empty?
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
