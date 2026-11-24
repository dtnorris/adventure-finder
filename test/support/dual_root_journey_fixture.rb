# frozen_string_literal: true

require_relative "ig07c_source_acceptance_fixture"
require_relative "fixture_artifact_mutation"
require_relative "../../lib/adventure_finder_operator_acceptance"

module Ig07cSourceAcceptance
  # Reuses the independently synthetic source/catalog inputs with real pipeline
  # commands in an independent code tree. Git metadata, when required by AFW,
  # is copied independently; no worktree pointers or alternate stores are used.
  class DualRootFixture < Fixture
    include FixtureArtifactMutation
    attr_reader :data_root

    # Captures exact public child output, invocation and outcome under the
    # retained fixture. Returns Open3's tuple; subprocess/IO errors propagate.
    def run_catalog(extra_env = {}, *arguments, chdir: @different_cwd, stdin_data: "")
      @invocation_count = (@invocation_count || 0) + 1
      evidence = directory("evidence/public-#{@invocation_count}")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stdout, stderr, status = super(extra_env, *arguments, chdir:, stdin_data:)
      File.binwrite(File.join(evidence, "stdout.bin"), stdout)
      File.binwrite(File.join(evidence, "stderr.bin"), stderr)
      File.binwrite(File.join(evidence, "invocation.json"), JSON.pretty_generate(
        command: [command, *arguments], cwd: chdir, environment: environment.merge(extra_env),
        stdin: stdin_data, exitstatus: status.exitstatus, signal: status.termsig,
        seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      ) + "\n")
      [stdout, stderr, status]
    end

    # Inventories regular files/directories including modes and rejects links.
    # Returns relative identity rows; missing roots or unsafe entries raise.
    def inventory(path)
      Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH).sort.reject { |entry| File.basename(entry) == "." }.to_h do |entry|
        stat = File.lstat(entry)
        raise "unsafe fixture entry: #{entry}" unless stat.directory? || (stat.file? && stat.nlink == 1)

        [entry.delete_prefix(path + "/"), {"mode" => stat.mode & 0o777, "sha256" => stat.file? ? Digest::SHA256.file(entry).hexdigest : nil}]
      end
    end

    # Seals activated synthetic code/configuration before public execution and
    # records the complete ownership map. Returns nil; unsafe entries raise.
    def seal_code
      @code_inventory = inventory(pipeline)
      File.binwrite(File.join(root, "root-map.json"), JSON.pretty_generate(
        front_executable: command, front_state: front, components: components,
        pipeline_code: pipeline, pipeline_library: File.join(pipeline, "lib"),
        pipeline_data: data_root, corpus: source, catalog: catalog, temporary: environment.fetch("TMPDIR"),
        code_inventory: @code_inventory
      ) + "\n")
      raise "legacy pipeline alias exists" if File.exist?(File.join(components, "af-data-pipeline"))
      nil
    end

    # Requires unchanged selected code and recorded execution of real owner
    # commands/libraries. Returns nil; missing or foreign provenance raises.
    def verify_code
      raise "pipeline code changed" unless inventory(pipeline) == @code_inventory

      observations = Dir.glob(File.join(root, "evidence/processes/*.json")).map { |path| JSON.parse(File.binread(path)) }
      commands = observations.select { |row| row.fetch("executable").start_with?(pipeline + "/bin/") }
      required = %w[af-source-progress af-source-intake af-source-register af-boundary-editorial
        af-data af-staged-scoring-authority af-standing-bulk-score-release af-final-release-package
        af-final-release-adoption af-project-state]
      missing = required - commands.map { |row| File.basename(row.fetch("executable")) }
      raise "missing real pipeline execution: #{missing.inspect}" unless missing.empty?
      raise "foreign pipeline executable observed" if observations.any? do |row|
        required.include?(File.basename(row.fetch("executable"))) && !row.fetch("executable").start_with?(pipeline + "/bin/")
      end
      raise "foreign pipeline library observed" if observations.any? do |row|
        row.fetch("libraries").keys.any? { |path| !path.start_with?(pipeline + "/lib/") }
      end
      raise "no selected owner library was loaded" unless commands.any? { |row| row.fetch("libraries").any? }
      raise "private state missing" unless File.directory?(File.join(data_root, "audits")) &&
        File.directory?(File.join(data_root, "output/staged-scoring-authority"))

      nil
    end

    # Exercises refused public transitions against completed, unapproved work.
    # Each independent corruption is restored byte-for-byte. Raises unless the
    # intended diagnostic occurs and catalog/private evidence remain unchanged.
    def verify_refusals(extra_env, candidate_path)
      operation_id = OPERATION_ID
      authority = File.join(data_root, "output/staged-scoring-authority/v0.1", operation_id, "authority.json")
      intake = File.join(data_root, "audits/pre-scoring/fixture-source-llm-edition-source-intake/source_intake.json")
      state = File.join(catalog, "PROJECT_STATE.yml")
      controls = [
        ["missing-handoff", intake, nil, /MISSING_BOUND_ARTIFACT/],
        ["tampered-handoff", intake, "changed", /STALE_INPUT/],
        ["missing-authority", authority, nil, /authority|publication/i],
        ["tampered-authority", authority, "changed", /authority|publication/i],
        ["stale-candidate", candidate_path, "changed", /candidate|release|sha256/i],
        ["stale-catalog", state, "\n", /catalog|project.state|STALE/i]
      ]
      controls.each do |name, path, suffix, diagnostic|
        original = File.binread(path)
        with_changed_artifact(path, suffix && original + suffix) do
          before = [inventory(catalog), inventory(data_root), inventory(pipeline), inventory(source)]
          stdout, stderr, status = run_catalog(extra_env, "resume", operation_id,
            "--approve-final-by", "Fixture Operator", stdin_data: "APPROVE\n")
          raise "#{name} did not refuse for its invariant: #{stdout}\n#{stderr}" unless
            !status.success? && diagnostic.match?(stdout + stderr)
          raise "#{name} performed unauthorized writes" unless before == [inventory(catalog), inventory(data_root), inventory(pipeline), inventory(source)]
          puts "NEGATIVE_CONTROL=#{name} verified"
        end
      end
      escaped = directory("escaped-output")
      link = File.join(data_root, "operations")
      File.symlink(escaped, link)
      unsafe_roots = [
        ["conflicting-roots", {"AF_DATA_PIPELINE_DATA_ROOT" => pipeline}],
        ["invalid-code", {"AF_DATA_PIPELINE_ROOT" => File.join(root, "absent-code")}],
        ["escaped-destination", {}]
      ]
      unsafe_roots.each do |name, selectors|
        before = [inventory(catalog), inventory(pipeline), inventory(escaped), inventory(source),
          inventory(File.join(data_root, "output")), inventory(File.join(data_root, "audits"))]
        stdout, stderr, status = run_catalog(extra_env.merge(selectors), "resume", operation_id,
          "--approve-final-by", "Fixture Operator", stdin_data: "APPROVE\n")
        raise "#{name} did not reject its destination: #{stdout}\n#{stderr}" unless
          !status.success? && /pipeline|symlink|destination/i.match?(stdout + stderr)
        raise "#{name} wrote outside its destination" unless before == [inventory(catalog), inventory(pipeline), inventory(escaped), inventory(source),
          inventory(File.join(data_root, "output")), inventory(File.join(data_root, "audits"))] && File.symlink?(link)
        puts "NEGATIVE_CONTROL=#{name} verified"
      end
      File.unlink(link)
      # Empty input may prepare a request; DECLINE is durable fixture authority.
      # Preserve each branch's bytes, then restore the absent promotion stores
      # so the independent positive can make its one explicit approval.
      (final_approval_controls? ? ["", "DECLINE\n"] : []).each_with_index do |answer, index|
        before = inventory(catalog)
        stdout, stderr, status = run_catalog(extra_env, "resume", operation_id,
          "--approve-final-by", "Fixture Operator", stdin_data: answer)
        expected = index.zero? ? "No approval recorded." : "DECLINED"
        raise "approval control failed: #{stdout}\n#{stderr}" unless
          !status.success? && stdout.include?(expected) && inventory(catalog) == before
        %w[operations/final-promotions].each do |relative|
          [front, data_root].each do |owner|
            path = File.join(owner, relative)
            next unless File.directory?(path)

            backup = File.join(directory("evidence/approval-control-#{index}"), File.basename(owner))
            FileUtils.cp_r(path, backup)
            FileUtils.remove_entry(path)
          end
        end
        puts "NEGATIVE_CONTROL=#{index.zero? ? 'absent-approval' : 'declined-approval'} verified"
      end
      restored, error, status = run_catalog(extra_env, "resume", operation_id)
      raise "restored positive did not reach review: #{error}" unless status.success? &&
        restored.include?("Final catalog review awaits explicit human approval")
      nil
    end

    # Legacy populated controls retain their established independent branches;
    # empty-start uses separate worlds so a declined durable decision survives.
    def final_approval_controls?
      true
    end

    # Runs the unchanged catalog-owned oracle against all three real consumers
    # in the selected layout. Missing consumers/dependencies or any refusal fail.
    def verify_consumers(source_roots)
      tools = directory("consumer-tools")
      catalog_tools = File.join(tools, "af-xlsx-files-data")
      source_roots.each do |name, source_root|
        names = name == "af-xlsx-files-data" ? %w[bin/check-project-state-consumers contracts Gemfile Gemfile.lock] : %w[bin lib config Gemfile Gemfile.lock]
        self.class.copy_runtime(source_root, File.join(tools, name), names:)
      end
      FileUtils.cp(File.join(catalog, "PROJECT_STATE.yml"), File.join(catalog_tools, "PROJECT_STATE.yml"))
      cleared = ENV.keys.grep(/\A(?:BUNDLE_|BUNDLER_)/).to_h { |key| [key, nil] }
      consumer_env = cleared.merge(environment).merge("AF_WORKSPACE_ROOT" => tools)
      case ENV.fetch("AF_ACCEPTANCE_CONSUMER_BUNDLE", "owner")
      when "owner"
      when "integration"
        consumer_env.merge!(ENV.select { |key, _| key.start_with?("BUNDLE_") })
      else
        raise "invalid acceptance consumer bundle selection"
      end
      command = File.join(catalog_tools, "bin/check-project-state-consumers")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      output, error, status = Open3.capture3(consumer_env, command, chdir: root)
      File.binwrite(File.join(root, "evidence/consumer-stdout.bin"), output)
      File.binwrite(File.join(root, "evidence/consumer-stderr.bin"), error)
      File.binwrite(File.join(root, "evidence/consumer-invocation.json"), JSON.pretty_generate(
        command: [command], cwd: root, environment: consumer_env, exitstatus: status.exitstatus,
        signal: status.termsig, seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      ) + "\n")
      puts output
      raise "real catalog consumer conformance failed: #{error}" unless status.success? &&
        output.include?("PASS (3 consumers,") && output.scan(/: PASS \d+\/\d+/).length == 3
      nil
    end

    # Copies tracked regular runtime files into a private destination. Inputs
    # are repository/destination paths and selected top-level names; returns nil.
    # Unsafe files, Git read failures and filesystem errors stop fixture setup.
    def self.copy_runtime(source, destination, names: %w[bin lib config schemas contracts specifications Gemfile Gemfile.lock], include_candidate: false)
      options = include_candidate ? %w[--cached --others --exclude-standard] : []
      files, error, status = Open3.capture3({"GIT_OPTIONAL_LOCKS" => "0"}, "git", "-C", source, "ls-files", "-z", *options, "--", *names)
      raise "cannot inventory runtime: #{error}" unless status.success?

      files.split("\0").each do |relative|
        original = File.join(source, relative)
        raise "unsafe runtime file: #{original}" unless File.file?(original) && !File.symlink?(original)

        target = File.join(destination, relative)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(original, target, preserve: true)
      end
      nil
    end

    # Copies native objects/index into independent fixture administration for
    # real owner provenance checks. Never links a worktree or object alternate.
    # Inputs are source/destination repositories; unsafe metadata or reads raise.
    def self.copy_git_metadata(source, destination)
      values = %w[--git-common-dir --absolute-git-dir HEAD].map do |selector|
        output, error, status = Open3.capture3({"GIT_OPTIONAL_LOCKS" => "0"}, "git", "-C", source, "rev-parse", selector)
        raise "cannot read Git identity: #{error}" unless status.success?

        output.strip
      end
      common, admin, head = values
      common = File.expand_path(common, source)
      objects = File.join(common, "objects")
      raise "shared alternate objects are unsupported" if File.exist?(File.join(objects, "info/alternates"))
      Dir.glob(File.join(objects, "**", "*"), File::FNM_DOTMATCH).each do |path|
        raise "unsafe Git object path: #{path}" if File.symlink?(path)
      end
      target = File.join(destination, ".git")
      FileUtils.mkdir_p(target)
      FileUtils.cp_r(objects, File.join(target, "objects"))
      FileUtils.cp(File.join(admin, "index"), File.join(target, "index"))
      File.binwrite(File.join(target, "HEAD"), head + "\n")
      File.binwrite(File.join(target, "config"), "[core]\n\trepositoryformatversion = 0\n\tbare = false\n\tfilemode = true\n")
      FileUtils.mkdir_p(File.join(target, "refs"))
      nil
    end

    # Returns the detached public executable used by every journey transition.
    def command
      File.join(front, "bin", "af-catalog")
    end

    private

    # Installs allowlisted owner code, without the old directory or symlinks.
    # Synthetic policy activation is supplied by the existing journey afterward.
    def build_pipeline_facade
      FileUtils.rmdir(@pipeline)
      @pipeline = directory("code/af-pipeline")
      @data_root = directory("af-pipeline-data")
      inventory_path = ENV.fetch("AF_PIPELINE_RUNTIME_INVENTORY",
        File.join(@pipeline_source_root, "public-journey/allowlist.json"))
      if ENV.key?("AF_PIPELINE_RUNTIME_INVENTORY")
        raise "current pipeline inventory mismatch" unless !File.symlink?(inventory_path) &&
          Digest::SHA256.file(inventory_path).hexdigest == "a909b3e77a262f4bc8af0fc6803257caf10cd39e53b8823704723c0eb0554200"
      end
      allowlist = JSON.parse(File.binread(inventory_path))
      allowlist.each do |entry|
        relative = entry.fetch("path")
        next unless %w[bin lib config schemas Gemfile Gemfile.lock].include?(relative.split("/").first)

        original = File.join(@pipeline_source_root, relative)
        raise "pipeline allowlist mismatch: #{relative}" unless
          !File.symlink?(original) && Digest::SHA256.file(original).hexdigest == entry.fetch("sha256") &&
          File.stat(original).mode & 0o777 == entry.fetch("mode")

        target = File.join(pipeline, relative)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(original, target, preserve: true)
      end
      copy_evidence_runtime(File.join(root, "code/af-evidence"))
      self.class.copy_runtime(@pipeline_source_root, pipeline, names: %w[bin/check-project-state-contract])
      self.class.copy_runtime(@repository_root, front, names: %w[bin lib], include_candidate: true)
    end

    # Copies the pinned EV runtime beside a selected AFDP copy. Explicit current
    # inventory selection requires an EV root; absent/changed bytes or modes
    # raise before public execution. Historical setup without selectors is unchanged.
    def copy_evidence_runtime(destination)
      return unless ENV.key?("AF_PIPELINE_RUNTIME_INVENTORY") || ENV.key?("AF_EVIDENCE_ROOT")

      source = File.realpath(ENV.fetch("AF_EVIDENCE_ROOT"))
      entries = JSON.parse(File.binread(File.join(@repository_root, "test/support/af_evidence_runtime_inventory.json")))
      entries.each do |entry|
        relative = entry.fetch("path")
        original = File.join(source, relative)
        raise "evidence runtime mismatch: #{relative}" unless
          !File.symlink?(original) && Digest::SHA256.file(original).hexdigest == entry.fetch("sha256") &&
          File.stat(original).mode & 0o777 == entry.fetch("mode")

        target = File.join(destination, relative)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(original, target, preserve: true)
      end
      nil
    end

    # Selects independent private state; inherited source/catalog/converter
    # ownership is preserved. The selected code has no legacy alias or fallback.
    def environment
      credentials = AdventureFinderWorkspace::OperatorAcceptance::CREDENTIAL_NAMES.to_h { |name| [name, nil] }
      guard = File.join(@repository_root, "test/support/offline_network_guard.rb")
      credentials.merge(super).merge("AF_DATA_PIPELINE_DATA_ROOT" => data_root,
        "AF_DPS10_TRACE_ROOT" => directory("evidence/processes"),
        "TMPDIR" => directory("temporary"), "TMP" => directory("temporary"), "TEMP" => directory("temporary"),
        "BUNDLE_USER_HOME" => directory("cache/bundle"), "BUNDLE_APP_CONFIG" => directory("cache/bundle-config"),
        "RUBOCOP_CACHE_ROOT" => directory("cache/rubocop"), "XDG_CACHE_HOME" => directory("cache/xdg"),
        "BUNDLER_ORIG_RUBYOPT" => "-r#{guard}",
        "RUBYOPT" => [ENV["RUBYOPT"], "-r#{guard}", "-r#{File.join(@repository_root, 'test/support/dual_root_process_trace.rb')}"].compact.join(" "))
    end
  end
end
