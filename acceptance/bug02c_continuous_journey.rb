# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "fileutils"
require "yaml"
require "zip"
require_relative "../test/support/ig07c_source_acceptance_fixture"
require_relative "../test/support/dual_root_journey_fixture"
require_relative "../test/support/coexistence_journey_fixture"
require_relative "../test/support/frontier_journey_fixture"
require_relative "../test/support/empty_start_journey_fixture"
require_relative "../test/support/second_input_journey_fixture"

front = File.expand_path("..", __dir__)
sources = ENV.fetch("AF_PROJECT_ROOT", File.expand_path("../adventure-finder-components", front))
components = ENV.fetch("AF_DATA_PIPELINE_ROOT", File.join(sources, "af-data-pipeline"))
dual_root = ARGV.delete("--dual-root")
coexistence = ARGV.delete("--coexistence")
switch_only = ARGV.delete("--switch-only")
frontier = ARGV.delete("--frontier")
empty_start = ARGV.delete("--empty-start")
second_input = ARGV.delete("--second-input")
dual_root = frontier = true if second_input
source_control = ARGV.delete("--source-review-missing") ? "page_review" : nil
source_control = "blocked" if ARGV.delete("--source-review-declined")
final_control = ARGV.delete("--final-review-missing") ? "" : nil
final_control = "DECLINE\n" if ARGV.delete("--final-review-declined")
abort "usage: ruby acceptance/bug02c_continuous_journey.rb [--second-input | --dual-root [--frontier] [--empty-start] | --coexistence [--switch-only]]" unless
  ARGV.empty? && !(second_input && empty_start) && !(dual_root && coexistence) && (!switch_only || coexistence) && (!frontier || (dual_root && !coexistence)) && (!empty_start || (dual_root && !coexistence)) && (!source_control || empty_start) && (final_control.nil? || (empty_start && frontier && !source_control))
dual_root ||= coexistence
abort "empty Frontier journey requires an explicitly authorized baseline" if
  empty_start && frontier && !ENV["AF_ACCEPTANCE_EMPTY_BASELINE"]
fixture_class = if second_input
  Ig07cSourceAcceptance::SecondInputFixture
elsif empty_start
  ENV["AF_ACCEPTANCE_NATIVE_ROOT"] ? Ig07cSourceAcceptance::ReviewedEmptyStartFixture : Ig07cSourceAcceptance::EmptyStartFixture
elsif frontier
  Ig07cSourceAcceptance::FrontierJourneyFixture
else
  coexistence ? Ig07cSourceAcceptance::CoexistenceFixture :
    (dual_root ? Ig07cSourceAcceptance::DualRootFixture : Ig07cSourceAcceptance::Fixture)
end
fixture = fixture_class.new(repository_root: front, pipeline_source_root: components)
puts "EMPTY_INPUTS=#{JSON.generate(fixture.measure_empty_inputs)}" if empty_start
fixture.prepare_frontier(sources) if frontier
puts "FIXTURE_ROOT=#{fixture.root}"
pipeline = fixture.pipeline
%w[af-data af-staged-scoring-authority af-standing-bulk-score-release af-final-release-package af-final-release-adoption af-project-state].each do |command|
  next if dual_root
  File.symlink(File.join(components, "bin", command), File.join(pipeline, "bin", command))
end
unless dual_root
  FileUtils.rm(File.join(pipeline, "bin/af-final-release-package"))
  FileUtils.cp(File.join(components, "bin/af-final-release-package"), File.join(pipeline, "bin/af-final-release-package"))
end
FileUtils.chmod(0o755, File.join(pipeline, "bin/af-final-release-package"))
FileUtils.mkdir_p(File.join(pipeline, "config"))
FileUtils.cp(File.join(components, "config/staged_scoring_input_policy_v0.1.json"),
             File.join(pipeline, "config/staged_scoring_input_policy_v0.1.json"))
# Independent synthetic activation retains the owner's scope/flag validators;
# fixture evidence must never consume the real project owner's directive.
{"synthetic-policy.json" => "standing_bulk_score_ingestion_policy_v0.1.json",
 "synthetic-owner-selection.json" => "standing_bulk_score_owner_selection_v0.1.json"}.each do |fixture_name, name|
  FileUtils.cp(File.join(components, "test/fixtures/standing_bulk_score", fixture_name),
               File.join(pipeline, "config", name))
end
{"af-workloads" => ENV.fetch("AF_AFW_ROOT", File.join(sources, "af-workloads")),
 "af-cli-scoring-utility" => ENV.fetch("AF_SCORER_ROOT", File.join(sources, "af-cli-scoring-utility")),
 "workload-orchestrator" => ENV.fetch("WLO_REPO_ROOT", File.join(sources, "workload-orchestrator"))}.each do |name, source|
  destination = File.join(fixture.components, name)
  if dual_root
    names = %w[bin lib config schemas contracts specifications Gemfile Gemfile.lock]
    if name == "af-workloads"
      names = %w[bin lib config/models.yml Gemfile Gemfile.lock
        production_backlog/qualified_dimensions.yml production_backlog/qualified_number_of_sessions.yml
        production_backlog/qualified_exploration_emphasis.yml production_backlog/qualified_gm_beginner_suitability.yml
        production_backlog/qualified_gm_preparation_burden.yml production_backlog/qualified_seriousness.yml
        production_backlog/ee-v0.5-runtime.yml production_backlog/gmpb-v0.6-runtime.yml
        production_backlog/seriousness-reset-runtime.yml]
    end
    Ig07cSourceAcceptance::DualRootFixture.copy_runtime(source, destination, names:)
    Ig07cSourceAcceptance::DualRootFixture.copy_git_metadata(source, destination) if
      %w[af-workloads af-cli-scoring-utility].include?(name)
  elsif name == "af-workloads"
    FileUtils.mkdir_p(destination)
    Dir.children(source).reject { |entry| %w[workloads build output].include?(entry) }.each do |entry|
      FileUtils.cp_r(File.join(source, entry), File.join(destination, entry))
    end
  else
    FileUtils.cp_r(source, destination)
  end
end
low_source = ENV.fetch("LOW_REPO_ROOT", File.join(sources, "local-ollama-workers"))
low_destination = File.join(fixture.components, "local-ollama-workers")
if dual_root
  Ig07cSourceAcceptance::DualRootFixture.copy_runtime(low_source, low_destination)
else
  FileUtils.cp_r(low_source, low_destination)
end
FileUtils.chmod(0o755, File.join(fixture.components, "af-workloads/bin/afw-score-job"))
FileUtils.mkdir_p(File.join(fixture.root, "low-state"))

scorer = File.join(fixture.components, "af-cli-scoring-utility")
script = <<~'SCORER'
  #!/usr/bin/env ruby
  require 'json'
  require 'digest'
  require 'csv'
  require 'time'
  require 'fileutils'
  require 'yaml'
  root = File.expand_path('..', __dir__)
  args = ARGV.dup
  option = ->(name) { args.include?(name) ? args[args.index(name) + 1] : nil }
  id = args.last
  dimension = option.call('--dimension')
  model = option.call('--model')
  output = option.call('--output')
  if (path = option.call('--prepare-source'))
    template = JSON.parse(File.binread(File.join(root, 'prepared-template.json')))
    template.fetch('adventure')['id'] = id
    # Consume the compiler's exact public input; staging owns its basename.
    template.fetch('catalog')['path'] = YAML.safe_load_file(option.call('--config'), aliases: true).fetch('files').fetch('catalog')
    %w[catalog source_registry source_file].each do |key|
      source = template.fetch(key).fetch('path')
      template.fetch(key)['sha256'] = Digest::SHA256.file(source).hexdigest
    end
    File.binwrite(path, JSON.pretty_generate(template) + "\n")
  elsif (path = option.call('--render-preflight'))
    source = JSON.parse(File.binread(File.join(root, 'prepared-template.json'))).dig('source_file', 'path')
    document = {
      'adventure_id' => id,
      'run_metadata' => {'adventure_id' => id, 'selected_dimension' => dimension,
                         'model' => model, 'provider' => 'ollama',
                         'source_file' => source, 'source_scope' => {},
                         'afao_version' => '1.6.1', 'assessment_spec_version' => '0.1'},
      'targets' => [{'artifact_name' => 'fixture', 'prompt_sha256' => 'a' * 64,
                     'schema_sha256' => 'b' * 64}]
    }
    File.binwrite(path, JSON.pretty_generate(document) + "\n")
  else
    abort 'offline endpoint missing' unless ENV['AF_OLLAMA_BASE_URL'] == 'http://127.0.0.1:11434'
    abort 'scoring output missing' unless output && dimension && model
    run_id = 'synthetic-' + dimension.downcase.gsub(/[^a-z0-9]+/, '-')
    preflight = option.call('--config')
    source = File.join(root, 'prepared-template.json')
    source = JSON.parse(File.binread(source)).dig('source_file', 'path')
    metrics = dimension == 'Levels' ? ['Level Start', 'Level End'] : [dimension]
    headers = %w[run_id status adventure_id adventure_title source_book metric value metric_kind confidence path_sensitive path_variation_affects_anchor assessment_state rationale evidence review_disposition afao_version assessment_spec_version provider model source_file hold_reason metric_review_flags package_review_flags]
    assessment = File.join(output, 'assessments', "#{id}_#{run_id}.csv")
    FileUtils.mkdir_p(File.dirname(assessment))
    CSV.open(assessment, 'w') do |csv|
      csv << headers
      metrics.each do |metric|
        row = {'run_id' => run_id, 'status' => 'PROPOSED', 'adventure_id' => id,
               'adventure_title' => 'Synthetic Procedure', 'source_book' => 'Fixture Source',
               'metric' => metric, 'value' => '3', 'metric_kind' => 'ordinal', 'confidence' => '0.9',
               'path_sensitive' => 'false', 'path_variation_affects_anchor' => 'false',
               'assessment_state' => 'resolved', 'rationale' => 'Synthetic structural evidence.',
               'evidence' => '[]', 'review_disposition' => 'REVIEW_REQUIRED',
               'afao_version' => '1.6.1', 'assessment_spec_version' => '0.1',
               'provider' => 'ollama', 'model' => model, 'source_file' => source}
        csv << headers.map { |header| row[header] }
      end
    end
    raw = File.join(output, 'raw', id, run_id)
    FileUtils.mkdir_p(raw)
    provider = {'provider' => 'ollama', 'payload' => {'model' => model}}
    request = {'record_type' => 'provider_request', 'recorded_before_inference' => true,
               'recorded_at' => Time.now.utc.iso8601,
               'prompt_sha256' => 'a' * 64, 'schema_sha256' => 'b' * 64,
               'request' => provider, 'request_sha256' => Digest::SHA256.hexdigest(JSON.generate(provider))}
    File.binwrite(File.join(raw, 'fixture_request.json'), JSON.generate(request) + "\n")
    File.binwrite(File.join(raw, 'fixture.json'), "{}\n")
  end
SCORER
script = script.gsub("'Fixture Source'", "'Fixture Second Source'") if second_input
File.binwrite(File.join(scorer, "bin/af-score"), script)
FileUtils.chmod(0o755, File.join(scorer, "bin/af-score"))
FileUtils.chmod(0o755, File.join(fixture.components, "af-workloads/bin/afw-bind-scoring-evidence"))
template = {
  "contract_version" => "afsu-prepared-source/v0.1",
  "adventure" => {"id" => "__ADVENTURE_ID__"},
  "source_policy" => {"allow_full_source_fallback" => false, "allow_inward_boundary_clamp" => false, "max_inward_boundary_clamp_gap" => nil},
  "catalog" => {"path" => nil, "sha256" => "0" * 64},
  "source_registry" => {"path" => fixture.registry, "sha256" => "0" * 64},
  "source_file" => {"path" => fixture.canonical, "sha256" => "0" * 64}
}
File.binwrite(File.join(scorer, "prepared-template.json"), JSON.pretty_generate(template) + "\n")

low = File.join(fixture.components, "local-ollama-workers/bin/low")
low_script = <<~LOW
  #!/usr/bin/env ruby
  require 'json'
  require 'stringio'
  $LOAD_PATH.unshift #{File.join(fixture.components, 'local-ollama-workers/lib').inspect}
  %w[error contract worker_record capability_evidence_store ollama_capability_request
     capability_bootstrapper local_worker_source publisher_state registry_publisher cli].each do |name|
    require "local_ollama_workers/\#{name}"
  end
  class FixtureObserver
    def observe
      {'worker_id' => 'fixture-local', 'generation_id' => 'fixture-generation-1',
       'endpoint' => 'http://127.0.0.1:11434'}
    end
  end
  class FixtureHardware
    def gpu_id = 'Fixture GPU'
  end
  class FixtureClient
    def initialize(root)
      @path = File.join(root, 'runtime.json')
      plan = Dir.glob(#{File.join(fixture.components, 'af-workloads/workloads/ingest-*/execution-plan.json').inspect}).first
      @models = JSON.parse(File.binread(plan)).fetch('pools').map do |pool|
        ollama = pool.fetch('requirements').fetch('ollama')
        {'model' => ollama.fetch('model'), 'digest' => ollama.fetch('expected_digest')}
      end.uniq
    end
    def endpoint = 'http://127.0.0.1:11434'
    def version = 'fixture-1'
    def installed_models = @models
    def preload!(model:, context_length:)
      File.binwrite(@path, JSON.generate('model' => model, 'context_length' => context_length))
    end
    def running_models
      return [] unless File.file?(@path)
      row = JSON.parse(File.binread(@path))
      digest = @models.find { |entry| entry['model'] == row.fetch('model') }.fetch('digest')
      [{'model' => row.fetch('model'), 'digest' => digest,
        'context_length' => row.fetch('context_length'), 'fully_gpu_resident' => true,
        'runtime_size_bytes' => 1024, 'runtime_size_vram_bytes' => 1024}]
    end
  end
  components = {observer: FixtureObserver.new, hardware_probe: FixtureHardware.new,
                client: FixtureClient.new(ENV.fetch('LOW_STATE_ROOT'))}
  stdout = StringIO.new
  status = LocalOllamaWorkers::CLI.run(ARGV, components: components, stdout: stdout)
  print stdout.string
  exit status
LOW
File.binwrite(low, low_script)
FileUtils.chmod(0o755, low)
git_guard = File.join(fixture.root, "sentinel-bin/git")
File.binwrite(git_guard, <<~'GIT')
  #!/bin/sh
  case " $* " in
    *" rev-parse "*|*" diff "*|*" status "*|*" show "*|*" remote "*) exec /usr/bin/git "$@" ;;
    *) echo 'git mutation forbidden in synthetic journey' >&2; exit 99 ;;
  esac
GIT
FileUtils.chmod(0o755, git_guard)

# The archive is a fixed synthetic catalog and prebuilt Git history. Extracting
# it does not stage or commit during this acceptance journey.
unless empty_start || second_input
archive = File.join(front, "test/fixtures/bug02c-precommitted-catalog.zip")
abort "catalog fixture identity changed" unless Digest::SHA256.file(archive).hexdigest ==
  "fdb44f13c4103cd6682e632fb54ac6f46e7e683bf3aab993ce9cc26e010303dd"
Zip::File.open(archive) do |zip|
  zip.each do |entry|
    abort "unsafe catalog fixture path" unless
      ["PROJECT_STATE.yml", "5e_Adventure_Master_Catalog_0.0.1.xlsx", ".git/HEAD", ".git/config", ".git/index",
       ".git/refs/heads/main"].include?(entry.name) || entry.name.match?(%r{\A\.git/objects/[0-9a-f]{2}/[0-9a-f]{38}\z})
    destination = File.join(fixture.catalog, entry.name)
    FileUtils.mkdir_p(File.dirname(destination))
    File.binwrite(destination, entry.get_input_stream.read)
  end
end
head, git_error, observed = Open3.capture3("git", "-C", fixture.catalog, "rev-parse", "HEAD")
abort "prebuilt catalog Git invalid: #{git_error}" unless
  observed.success? && head.strip == "2a6a3da7c3cbbaf58c1e2ff1640042819ff8b04f"
puts "CATALOG_HEAD=#{head.strip}"
end
# Compare literal Git bytes, including cached index metadata. Optional locks
# disable Git's observational cache write without bypassing its validators.
git_bytes = Dir.glob(File.join(fixture.catalog, ".git", "**", "*"), File::FNM_DOTMATCH)
  .select { |path| File.file?(path) }.to_h { |path| [path, File.binread(path)] }
args = fixture.send(:start_arguments)
%w[--policy-definition --policy-id --policy-version --policy-values].each do |flag|
  args.slice!(args.index(flag), 2)
end
args.concat(["--prepare-staged-scoring", "--successor-version", second_input ? "0.0.3" : "0.0.2"])
fixture.seal_code if dual_root
fixture_env = {
  "GIT_OPTIONAL_LOCKS" => "0",
  "AF_AFW_ROOT" => File.join(fixture.components, "af-workloads"),
  "AF_SCORER_ROOT" => File.join(fixture.components, "af-cli-scoring-utility"),
  "WLO_REPO_ROOT" => File.join(fixture.components, "workload-orchestrator"),
  "LOW_REPO_ROOT" => File.join(fixture.components, "local-ollama-workers"),
  "LOW_STATE_ROOT" => File.join(fixture.root, "low-state")
}
fixture.legacy_probe(fixture_env, "88888888-8888-4888-8888-888888888888") if coexistence
if source_control
  fixture.verify_source_review_control(fixture_env, args, source_control)
  exit 0
end
stdout, stderr, status = fixture.run_catalog(fixture_env.merge("IG07C_MARKDOWN_MODE" => "synthetic_procedure"), *args)
abort "start: #{stdout}\n#{stderr}" unless status.success?
puts "START_OK"
if empty_start
  registered = AfDataPipeline::BoundaryFreeze.registry_context(fixture.source, nil).fetch("sources")
  raise "first registration did not retain exactly one source" unless
    registered.keys == [Ig07cSourceAcceptance::Fixture::SOURCE_ID]
end
fixture.verify_switch(fixture_env) if coexistence
exit 0 if switch_only
operation_id = second_input ? Ig07cSourceAcceptance::SecondInputFixture::SECOND_OPERATION : Ig07cSourceAcceptance::Fixture::OPERATION_ID
base_bytes = File.binread(fixture.base)
before_state = File.binread(File.join(fixture.catalog, "PROJECT_STATE.yml"))
bundle = File.join(fixture.front, "output", "ingest-editorial-workspaces", "v0.1", operation_id)
ledger_path = File.join(bundle, "editorial_decisions.yml")
ledger = YAML.safe_load_file(ledger_path)
ledger.fetch("candidates") << {
  "candidate_key" => "synthetic-sequence", "provisional_title" => "Synthetic Procedure",
  "playability_evidence" => "Entry, authored middle, and exit on the synthetic page.",
  "open_questions" => [], "review_history" => [
    {"phase" => "phase1", "status" => "retained", "rationale" => "Three steps."},
    {"phase" => "phase1b", "status" => "survived", "rationale" => "Entry, middle and exit."},
    {"phase" => "phase2", "status" => "accepted", "rationale" => "One bounded procedure."}
  ], "disposition" => "accept", "decision" => {
    "canonical_title" => "Synthetic Procedure", "printed_pages" => {"start" => 1, "end" => 1},
    "pdf_pages" => {"start" => 1, "end" => 1}, "levels" => {"start" => 1, "end" => 1},
    "editorial_rationale" => "Synthetic page supplies complete procedural sequence."
  }
}
File.binwrite(ledger_path, YAML.dump(ledger))
fixture.verify_boundary_review_controls(fixture_env, ledger_path) if empty_start
stdout, stderr, status = fixture.run_catalog(fixture_env, "resume", operation_id, "--approve-boundary-by", "Fixture Operator")
puts "RESUME_STATUS=#{status.exitstatus}"
puts stdout.lines.last(25).join
puts stderr.lines.last(8).join
if empty_start && !frontier
  stage_paths = Dir.glob(File.join(fixture.root, "**", "*-verified-staged-successor-from-amc-*.json"))
  registered = AfDataPipeline::BoundaryFreeze.registry_context(fixture.source, nil).fetch("sources")
  raise "first registration did not retain exactly one source" unless registered.keys == [Ig07cSourceAcceptance::Fixture::SOURCE_ID]
  raise "initial roles or workbook changed" unless File.binread(fixture.base) == base_bytes &&
    File.binread(File.join(fixture.catalog, "PROJECT_STATE.yml")) == before_state
  if status.success?
    raise "missing first real staged successor" unless stage_paths.length == 1
    stage = JSON.parse(File.binread(stage_paths.first))
    raise "first stage is not verified" unless stage.fetch("status") == "verified_staged_successor"
  end
  # The raw public result is retained even when the next owner transition fails.
  File.binwrite(File.join(fixture.root, "evidence/empty-start-result.json"), JSON.pretty_generate(
    public_exitstatus: status.exitstatus, catalog_git_present: File.exist?(File.join(fixture.catalog, ".git")),
    stage_receipts: stage_paths, registered_sources: registered.keys,
    first_transition_status: status.success? ? "STAGED; downstream review still required" : "FAILED; inspect raw public output",
    final_acceptance: "INCOMPLETE"
  ) + "\n")
  puts "EMPTY_START_BOUNDED_STOP=#{fixture.root}"
  exit(status.success? ? 0 : 2)
end
abort "public journey stopped before final review" unless status.success?
release_root = File.join(dual_root ? fixture.data_root : fixture.front, "output/ingest-releases/v0.1", operation_id)
release_inputs = JSON.parse(File.binread(File.join(release_root, "release-inputs.json")))
accounting = JSON.parse(File.binread(File.join(release_root, "release/release-accounting.json")))
package = JSON.parse(File.binread(File.join(release_root, "package.json")))
puts "RELEASE_SCHEMA=#{release_inputs.fetch('schema_version')} SELECTION=#{package.dig('provenance', 'nodes', 'release_input:afw_selection', 'sha256')}"
puts "RELEASE_COUNTS=#{accounting.fetch('counts').inspect}"
puts "PACKAGE_READY=#{package.dig('readiness', 'ready')} PACKAGE=#{package.fetch('package_id')}"
abort "standing release did not bind the AFW v0.2 selection" unless
  release_inputs.fetch("schema_version") == "af-standing-bulk-score-release-inputs/v0.2" &&
  release_inputs.dig("staged_scoring", "selection_path") &&
  release_inputs.dig("staged_scoring", "workload_paths", "generated")
counts = accounting.fetch("counts")
expected_counts = second_input ? fixture.expected_accounting(operation_id) : [11, 11, 6, 5, 0, 0]
abort "eligible denominator or standing authority changed" unless
  counts.values_at("intended_cases", "execution_evidence_ready_cases", "standing_directive_accepted",
                   "deferred_or_unsupported", "individual_human_accepted", "ig16b_machine_accepted") ==
    expected_counts
abort "final package is not ready" unless package.dig("readiness", "ready") == true
abort "catalog changed before final approval" unless
  File.binread(File.join(fixture.catalog, "PROJECT_STATE.yml")) == before_state && File.binread(fixture.base) == base_bytes
workload_id = "ingest-#{operation_id}"
wlo_output = File.join(fixture.front, "output/local-ingest-executions/v0.1", operation_id, "wlo")
jobs = JSON.parse(File.binread(File.join(wlo_output, "jobs.json"))).fetch("jobs")
receipts = Dir.glob(File.join(fixture.components, "af-workloads/output/workloads", workload_id, "evidence", "*.json"))
abort "WLO attempt or AFW receipt denominator differs" unless
  jobs.length == expected_counts.first && jobs.all? { |job| job["status"] == "complete" && job["attempt"] == 1 } && receipts.length == expected_counts.first
frozen_cases = Dir.glob(File.join(fixture.components, "af-workloads/build/workloads", workload_id, "cases/*.yml")).sort
case_bindings = frozen_cases.to_h do |path|
  [YAML.safe_load_file(path).fetch("case_id"), Digest::SHA256.file(path).hexdigest]
end
receipt_rows = receipts.map { |path| JSON.parse(File.binread(path)) }
abort "jobs or receipts do not match exact frozen case intent" unless
  case_bindings.length == frozen_cases.length && case_bindings.length == counts.fetch("intended_cases") &&
  jobs.map { |job| job.fetch("job_id") }.sort == case_bindings.keys.sort &&
  receipt_rows.map { |row| row.dig("scoring_intent", "case_id") }.sort == case_bindings.keys.sort &&
  receipt_rows.all? { |row|
    row.dig("attempt", "attempt") == 1 &&
      row.dig("scoring_intent", "case_sha256") == case_bindings.fetch(row.dig("scoring_intent", "case_id"))
  }
puts "WLO_JOBS=#{jobs.length} AFW_RECEIPTS=#{receipts.length} ATTEMPTS=#{jobs.map { |job| job['attempt'] }.tally}"
selection_path = File.join(fixture.components, "af-workloads/workloads/.selections", workload_id, "selection.json")
selection = JSON.parse(File.binread(selection_path))
staged = selection.fetch("staged_amc")
staged_path = File.join(fixture.catalog, staged.fetch("filename"))
abort "staged filename was reconstructed as a publication path" unless
  staged.fetch("filename") == "staged-5e_Adventure_Master_Catalog_#{package.dig('candidate', 'version')}.xlsx"
abort "staged receipt bytes differ" unless Digest::SHA256.file(staged_path).hexdigest == staged.fetch("sha256")
if empty_start
  first_workbook = AfDataPipeline::BoundaryFreezeApply::Workbook.new(staged_path)
  ordinary = first_workbook.sheet_by_name!("Adventure Catalog").catalog_records
  large = first_workbook.sheet_by_name!("AMC >100pg").catalog_records
  raise "first allocation is not one ordinary ADV-0001" unless
    ordinary.length == 1 && ordinary.first.fetch("adventure_id") == "ADV-0001" && large.empty?
  puts "FIRST_REGISTRATION=1 FIRST_ALLOCATION=ADV-0001"
end
candidate = package.dig("candidate", "selected")
abort "staged and scored successors must have distinct paths and bytes" unless
  staged_path != candidate.fetch("path") && staged.fetch("sha256") != candidate.fetch("sha256")
protected = [fixture.base, fixture.registry, fixture.canonical, staged_path, File.join(release_root, "package.json"),
  *(dual_root ? [selection_path, *receipts,
    *frozen_cases,
    *Dir.glob(File.join(fixture.data_root, "output/staged-scoring-authority", "**", "*")).select { |path| File.file?(path) },
    *Dir.glob(File.join(fixture.front, "output/ingest-operations", "**", "*")).select { |path| File.file?(path) }] : []),
  *Dir.glob(File.join(release_root, "release", "**", "*")).select { |path| File.file?(path) }]
  .to_h { |path| [path, File.binread(path)] }
protected_modes = protected.keys.to_h { |path| [path, File.stat(path).mode] }
replay_inventories = if dual_root
  [File.join(fixture.front, "output/ingest-operations"),
   File.join(fixture.data_root, "output/staged-scoring-authority"),
   File.join(fixture.catalog, ".git")].to_h { |path| [path, fixture.inventory(path)] }
else
  {}
end
puts "STAGED=#{JSON.generate(staged.merge('path' => staged_path))}"
puts "SCORED=#{JSON.generate(candidate)}"
package_bytes = File.binread(File.join(release_root, "package.json"))
release_bytes = File.binread(File.join(release_root, "release/release-accounting.json"))
replay_out, replay_err, replay_status = fixture.run_catalog(fixture_env, "resume", operation_id)
abort "public replay did not retain the exact release: #{replay_err}" unless
  replay_status.success? && replay_out.include?("Final catalog review awaits explicit human approval") &&
  File.binread(File.join(release_root, "package.json")) == package_bytes &&
  File.binread(File.join(release_root, "release/release-accounting.json")) == release_bytes &&
  File.binread(File.join(fixture.catalog, "PROJECT_STATE.yml")) == before_state &&
  JSON.parse(File.binread(File.join(wlo_output, "jobs.json"))).fetch("jobs") == jobs &&
  Dir.glob(File.join(fixture.components, "af-workloads/output/workloads", workload_id, "evidence", "*.json")) == receipts
abort "preapproval replay changed operation, authority or Git inventory" unless
  replay_inventories.all? { |path, inventory| fixture.inventory(path) == inventory }
puts "PREAPPROVAL_REPLAY=verified"
unless final_control.nil?
  fixture.verify_final_review_control(fixture_env, final_control)
  exit 0
end
fixture.verify_refusals(fixture_env, candidate.fetch("path")) if dual_root
fixture.rollback_selection(fixture_env) if coexistence
before_approval = File.binread(File.join(fixture.catalog, "PROJECT_STATE.yml"))
approval_entry = frontier ? :approve_and_export : :run_catalog
approval_stdout, approval_stderr, approval_status = fixture.public_send(approval_entry,
  fixture_env,
  "resume", operation_id, "--approve-final-by", "Fixture Operator",
  stdin_data: "APPROVE\n", chdir: fixture.root
)
puts "FINAL_APPROVAL_STATUS=#{approval_status.exitstatus}"
puts approval_stdout.lines.last(35).join
puts approval_stderr.lines.last(10).join
after_approval = File.binread(File.join(fixture.catalog, "PROJECT_STATE.yml"))
puts "PROJECT_STATE_CHANGED=#{before_approval != after_approval}"
abort "final catalog promotion did not succeed" unless approval_status.success?
old_roles = YAML.safe_load(before_approval).slice("catalog_head", "matcher_authorized_baseline", "production_dependency_floor")
new_roles = YAML.safe_load(after_approval).slice("catalog_head", "matcher_authorized_baseline", "production_dependency_floor")
candidate = package.dig("candidate", "selected")
abort "promoted role differs from the exact reviewed candidate" unless
  new_roles.fetch("catalog_head").slice("version", "filename", "sha256", "bytes") ==
    {"version" => package.dig("candidate", "version"),
     "filename" => File.basename(candidate.fetch("path")).sub("release-candidate.xlsx", "5e_Adventure_Master_Catalog_#{package.dig('candidate', 'version')}.xlsx"),
     "sha256" => candidate.fetch("sha256"), "bytes" => candidate.fetch("bytes")}
abort "independent catalog roles changed" unless
  new_roles.except("catalog_head") == old_roles.except("catalog_head")
abort "base workbook changed" unless File.binread(fixture.base) == base_bytes
puts "PROMOTED=#{new_roles.fetch('catalog_head').inspect}"
destination = File.join(fixture.catalog, new_roles.dig("catalog_head", "filename"))
abort "publication bytes differ from approval-bound candidate" unless File.binread(destination) == File.binread(candidate.fetch("path"))
abort "promotion changed protected release or staged bytes" unless protected.all? { |path, bytes| File.binread(path) == bytes }
abort "promotion changed protected modes" unless protected_modes.all? { |path, mode| File.stat(path).mode == mode }
abort "catalog Git bytes changed during observation or promotion" unless
  git_bytes == git_bytes.keys.to_h { |path| [path, File.binread(path)] }
puts "GIT_INDEX_REFS_OBJECTS=unchanged"
promoted_state = File.binread(File.join(fixture.catalog, "PROJECT_STATE.yml"))
promotion_roots = [fixture.front, *(dual_root ? [fixture.data_root] : [])]
promotion_files = promotion_roots.flat_map { |root| Dir.glob(File.join(root, "operations/final-promotions", "**", "*")) }
  .select { |path| File.file?(path) }.to_h { |path| [path, File.binread(path)] }
promotion_inventories = dual_root ? promotion_roots.to_h do |root|
  path = File.join(root, "operations/final-promotions")
  [path, fixture.inventory(path)]
end : {}
fixture.rollback_selection(fixture_env, adopted: true) if coexistence
replay_stdout, replay_stderr, replay_status = fixture.run_catalog(
  fixture_env,
  "resume", operation_id, "--approve-final-by", "Fixture Operator",
  stdin_data: "", chdir: fixture.root
)
puts "POSTPROMOTION_REPLAY_STATUS=#{replay_status.exitstatus}"
puts replay_stdout.lines.last(30).join
puts replay_stderr.lines.last(10).join
abort "post-promotion public resume did not verify completed promotion" unless
  replay_status.success? && replay_stdout.include?("Final promotion: ALREADY_PROMOTED.")
abort "post-promotion replay mutated authority, jobs or receipts" unless
  File.binread(File.join(fixture.catalog, "PROJECT_STATE.yml")) == promoted_state &&
  promotion_files.all? { |path, bytes| File.binread(path) == bytes } &&
  protected.all? { |path, bytes| File.binread(path) == bytes } &&
  protected_modes.all? { |path, mode| File.stat(path).mode == mode } &&
  git_bytes == git_bytes.keys.to_h { |path| [path, File.binread(path)] } &&
  JSON.parse(File.binread(File.join(wlo_output, "jobs.json"))).fetch("jobs") == jobs &&
  Dir.glob(File.join(fixture.components, "af-workloads/output/workloads", workload_id, "evidence", "*.json")) == receipts
abort "post-promotion replay changed operation, authority, Git or adoption inventory" unless
  replay_inventories.merge(promotion_inventories).all? { |path, inventory| fixture.inventory(path) == inventory }
abort "forbidden child call observed" unless fixture.forbidden_calls.empty?
if dual_root
  fixture.verify_consumers(%w[af-xlsx-data-sources af-cli-query-matcher af-frontier-pack].to_h do |name|
    [name, name == "af-cli-query-matcher" ? ENV.fetch("AF_QUERY_MATCHER_ROOT", File.join(sources, name)) : File.join(sources, name)]
  end)
  fixture.verify_code
end
fixture.verify_frontier_replay(fixture_env) if frontier
puts "POSTPROMOTION_REPLAY=verified DECISIONS=3 MANUAL_INTERMEDIATE_COMMANDS=0 PAID_COST=0"
