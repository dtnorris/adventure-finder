# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "securerandom"
require_relative "../test/support/ig19_git_fixture"
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
  (["focused", "focused-support", "staleness", "matrices", "fixture"] + repositories.keys).include?(selection)

scratch = File.expand_path(ENV.fetch("IG19_SCRATCH_ROOT", File.join(root, "output", "ig19")))
FileUtils.mkdir_p(scratch)
directory = Dir.mktmpdir("ig19d-validation-", scratch)
fixtures = File.join(directory, "fixtures")
FileUtils.mkdir_p(fixtures)
token = SecureRandom.hex(32)
File.binwrite(File.join(fixtures, ".ig19d-disposable"), token)
network_guard = File.join(root, "test/support/offline_network_guard.rb")
environment = AdventureFinderWorkspace::OperatorAcceptance::CREDENTIAL_NAMES.to_h { |name| [name, nil] }
environment.merge!(
  "TMPDIR" => fixtures, "IG19D_FIXTURE_ROOT" => fixtures, "IG19D_FIXTURE_TOKEN" => token,
  "AF_OPERATOR_ACCEPTANCE_OFFLINE" => "1", "BUNDLE_GEMFILE" => nil, "BUNDLE_LOCKFILE" => nil,
  "AF_TEST_CONTENDED" => nil, "WLO_TEST_CONTENDED" => nil, "COVERAGE" => nil,
  "GIT_OPTIONAL_LOCKS" => "0", "RUBOCOP_CACHE_ROOT" => File.join(directory, "rubocop-cache"),
  "RUBYLIB" => [File.join(root, "test/support"), ENV["RUBYLIB"]].compact.join(File::PATH_SEPARATOR),
  # Preserve the absolute require for ordinary suites whose child environment
  # may reset RUBYLIB; Ruby option splitting needs a load-path name for spaces.
  "RUBYOPT" => network_guard.match?(/\s/) ? "-roffline_network_guard" : "-r#{network_guard}"
)
if %w[adventure-finder workload-orchestrator].include?(selection)
  repositories["runpod-ollama-fleet"] = [ENV.fetch("RPOF_REPO_ROOT", File.join(components, "runpod-ollama-fleet")), "RPOF_REPO_ROOT"]
end
repositories.each do |name, (source, variable)|
  next unless variable

  destination = File.join(fixtures, name)
  # Copy exact tracked source and independent metadata; no shared object stores,
  # source index refresh, checkout, or fixture history construction occurs here.
  files = Ig19GitFixture.git(source, "ls-files", "-z").split("\0")
  files.each do |relative|
    target = File.join(destination, relative)
    FileUtils.mkdir_p(File.dirname(target))
    FileUtils.cp(File.join(source, relative), target, preserve: true)
  end
  FileUtils.cp_r(File.join(source, ".git"), File.join(destination, ".git"))
  environment[variable] = destination
end
# Keep the unchanged guard inside a component's disposable copy during its
# default suite, so domain-independence tests do not see an AF implementation
# dependency merely from instrumentation. Guard bytes and behavior are identical.
if repositories.key?(selection) && selection != "adventure-finder"
  support = File.join(environment.fetch(repositories.fetch(selection).last), "output", "ig19-support")
  FileUtils.mkdir_p(support)
  FileUtils.cp(File.join(root, "test/support/offline_network_guard.rb"), File.join(support, "offline_network_guard.rb"))
  environment["RUBYLIB"] = [support, ENV["RUBYLIB"]].compact.join(File::PATH_SEPARATOR)
  guard = File.join(support, "offline_network_guard.rb")
  environment["RUBYOPT"] = "-r#{guard}" unless guard.match?(/\s/)
end
environment["AF_AFW_ROOT"] = environment.fetch("AF_AFW_SOURCE_ROOT")
environment["AF_WORKLOADS_ROOT"] = environment.fetch("AF_AFW_SOURCE_ROOT")
environment["AF_IG07C_PIPELINE_SOURCE_ROOT"] = environment.fetch("AF_DATA_PIPELINE_ROOT")
environment["AF_IG19B_PIPELINE_SOURCE_ROOT"] = environment.fetch("AF_DATA_PIPELINE_ROOT")
environment["AF_PROJECT_ROOT"] = fixtures
environment["AF_ADVENTURE_FINDER_ROOT"] = root
command, cwd = if %w[focused focused-support staleness matrices fixture].include?(selection)
                 files = case selection
                         when "staleness" then ["acceptance/ig19d_staleness_matrix.rb"]
                         when "matrices" then %w[acceptance/ig19a_entry_contract.rb acceptance/ig19b_source_exception_matrix.rb
                           acceptance/ig19b_boundary_exception_matrix.rb acceptance/ig19c_execution_exception_matrix.rb
                           acceptance/ig19c_evidence_review_exception_matrix.rb acceptance/ig19d_staleness_matrix.rb]
                         when "fixture" then %w[test/ig19_git_fixture_test.rb test/integration/final_promotion_pipeline_seam_test.rb]
                         else ["acceptance/ig19d_restart_promotion_test.rb"]
                         end
                 arguments = selection == "focused-support" ? ["--name", "/test_(disposable|operation|source|boundary)/"] : []
                 [[RbConfig.ruby, "-Ilib", "-Itest", "-e",
                   "ARGV.shift(#{files.length}).each { |path| require File.expand_path(path) }", *files, *arguments], root]
               elsif selection == "adventure-finder"
                 [["bundle", "exec", "rake"], root]
               else
                 destination = environment.fetch(repositories.fetch(selection).last)
                 environment["BUNDLE_GEMFILE"] = File.join(destination, "Gemfile")
                 [["bundle", "exec", "rake"], destination]
               end
environment["BUNDLE_GEMFILE"] = File.join(environment.fetch("AF_DATA_PIPELINE_ROOT"), "Gemfile") if %w[focused focused-support matrices staleness fixture].include?(selection)
command = ["bundle", "exec", *command] if %w[focused focused-support matrices staleness fixture].include?(selection)
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
# Preserve the offline guard through Bundler environment restoration.
environment["BUNDLER_ORIG_RUBYOPT"] = nil
output, status = Open3.capture2e(environment, *command, chdir: cwd)
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
File.binwrite(File.join(directory, "validation.log"), output)
puts output
puts JSON.generate("suite" => selection, "command" => command, "cwd" => cwd,
                   "exitstatus" => status.exitstatus, "wall_seconds" => elapsed,
                   "log" => File.join(directory, "validation.log"),
                   "component_heads" => repositories.transform_values { |source, _| Open3.capture2("git", "-C", source, "rev-parse", "HEAD").first.strip })
exit(status.success? ? 0 : 1)
