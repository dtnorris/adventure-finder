# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "securerandom"
require "tmpdir"
require_relative "../lib/adventure_finder_operator_acceptance"

# Runs one focused proof or one unchanged default suite. Owner checkouts are
# copied into an isolated workspace so coverage and lint caches cannot touch
# the originals. Logs survive for the operator; fixture roots are disposable.
root = File.expand_path("..", __dir__)
components = ENV.fetch("AF_PROJECT_ROOT", File.expand_path("../adventure-finder-components", root))
repositories = {
  "adventure-finder" => [root, nil],
  "af-data-pipeline" => [ENV.fetch("AF_DATA_PIPELINE_ROOT", File.join(components, "af-data-pipeline")), "AF_DATA_PIPELINE_ROOT"],
  "af-workloads" => [ENV.fetch("AF_AFW_SOURCE_ROOT", File.join(components, "af-workloads")), "AF_AFW_SOURCE_ROOT"],
  "workload-orchestrator" => [ENV.fetch("WLO_REPO_ROOT", File.join(components, "workload-orchestrator")), "WLO_REPO_ROOT"],
  "local-ollama-workers" => [ENV.fetch("LOW_REPO_ROOT", File.join(components, "local-ollama-workers")), "LOW_REPO_ROOT"],
  "af-cli-scoring-utility" => [ENV.fetch("AF_SCORER_ROOT", File.join(components, "af-cli-scoring-utility")), "AF_SCORER_ROOT"]
}
selection = ARGV.shift || "focused"
abort "usage: ruby acceptance/ig19d_validation.rb [focused|REPOSITORY]" unless ARGV.empty? &&
  (["focused", "focused-support", "staleness"] + repositories.keys).include?(selection)

directory = Dir.mktmpdir("ig19d-validation-", "/private/tmp")
fixtures = File.join(directory, "fixtures")
FileUtils.mkdir_p(fixtures)
token = SecureRandom.hex(32)
File.binwrite(File.join(fixtures, ".ig19d-disposable"), token)
guard_bin = File.join(directory, "guard-bin")
FileUtils.mkdir_p(guard_bin)
git_wrapper = File.join(guard_bin, "git")
File.write(git_wrapper, "#!#{RbConfig.ruby}\nrequire #{File.join(root, 'test/support/ig19d_disposable_git.rb').inspect}\n" \
  "Ig19dDisposableGit.check!(['/usr/bin/git', *ARGV])\nexec('/usr/bin/git', *ARGV)\n")
File.chmod(0o755, git_wrapper)
environment = AdventureFinderWorkspace::OperatorAcceptance::CREDENTIAL_NAMES.to_h { |name| [name, nil] }
environment.merge!(
  "TMPDIR" => fixtures, "IG19D_FIXTURE_ROOT" => fixtures, "IG19D_FIXTURE_TOKEN" => token,
  "PATH" => [guard_bin, ENV.fetch("PATH")].join(File::PATH_SEPARATOR),
  "AF_OPERATOR_ACCEPTANCE_OFFLINE" => "1", "BUNDLE_GEMFILE" => nil, "BUNDLE_LOCKFILE" => nil,
  "AF_TEST_CONTENDED" => nil, "WLO_TEST_CONTENDED" => nil, "COVERAGE" => nil,
  "RUBYOPT" => "-r#{root}/test/support/offline_network_guard.rb -r#{root}/test/support/ig19d_disposable_git.rb"
)
repositories.each do |name, (source, variable)|
  next unless variable

  destination = File.join(fixtures, name)
  output, status = Open3.capture2e("git", "clone", "--quiet", "--shared", source, destination)
  abort output unless status.success?
  head, status = Open3.capture2("git", "-C", source, "rev-parse", "HEAD")
  abort "cannot identify #{source}" unless status.success?
  output, status = Open3.capture2e("git", "-C", destination, "checkout", "--quiet", "--detach", head.strip)
  abort output unless status.success?
  environment[variable] = destination
end
environment["AF_AFW_ROOT"] = environment.fetch("AF_AFW_SOURCE_ROOT")
environment["AF_WORKLOADS_ROOT"] = environment.fetch("AF_AFW_SOURCE_ROOT")
environment["AF_IG07C_PIPELINE_SOURCE_ROOT"] = environment.fetch("AF_DATA_PIPELINE_ROOT")
environment["AF_IG19B_PIPELINE_SOURCE_ROOT"] = environment.fetch("AF_DATA_PIPELINE_ROOT")
environment["AF_PROJECT_ROOT"] = fixtures
environment["AF_ADVENTURE_FINDER_ROOT"] = root
command, cwd = if %w[focused focused-support staleness].include?(selection)
                 file = selection == "staleness" ? "acceptance/ig19d_staleness_matrix.rb" : "acceptance/ig19d_restart_promotion_test.rb"
                 arguments = selection == "focused-support" ? ["--name", "/test_(disposable|operation|source|boundary)/"] : []
                 [[RbConfig.ruby, "-Ilib", "-Itest", file, *arguments], root]
               elsif selection == "adventure-finder"
                 [["bundle", "exec", "rake"], root]
               else
                 destination = environment.fetch(repositories.fetch(selection).last)
                 environment["BUNDLE_GEMFILE"] = File.join(destination, "Gemfile")
                 [["bundle", "exec", "rake"], destination]
               end
environment["BUNDLE_GEMFILE"] = File.join(environment.fetch("AF_DATA_PIPELINE_ROOT"), "Gemfile") if selection.start_with?("focused")
command = ["bundle", "exec", *command] if selection.start_with?("focused")
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
output, status = Open3.capture2e(environment, *command, chdir: cwd)
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
File.binwrite(File.join(directory, "validation.log"), output)
puts output
puts JSON.generate("suite" => selection, "command" => command, "cwd" => cwd,
                   "exitstatus" => status.exitstatus, "wall_seconds" => elapsed,
                   "log" => File.join(directory, "validation.log"),
                   "component_heads" => repositories.transform_values { |source, _| Open3.capture2("git", "-C", source, "rev-parse", "HEAD").first.strip })
exit(status.success? ? 0 : 1)
