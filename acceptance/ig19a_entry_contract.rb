# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "shellwords"
require_relative "../lib/adventure_finder_operator_acceptance"

# Admission diagnostic only. A parser refusal cannot prove a downstream journey.
# Keep it outside the default unit suite, like the other IG-19 scenario files.
root = File.expand_path("..", __dir__)
guard = File.join(root, "test/support/offline_network_guard.rb")
environment = AdventureFinderWorkspace::OperatorAcceptance::CREDENTIAL_NAMES.to_h { |name| [name, nil] }
environment.merge!(
  "BUNDLE_GEMFILE" => nil,
  "RUBYOPT" => "-r#{guard}",
  "AF_PROJECT_ROOT" => ENV.fetch("AF_PROJECT_ROOT", File.join(root, "..", "adventure-finder-components")),
  "AF_ADVENTURE_FINDER_ROOT" => ENV.fetch("AF_ADVENTURE_FINDER_ROOT", root)
)

# These are parser inputs, not a qualified synthetic workbook or conversion
# fixture. No file is opened on the observed MISSING_CHOICE path. Do not proceed
# with these inputs if admission changes: replace this diagnostic with the real
# continuous journey using the existing owner fixtures and validators.
operation_id = "19191919-1919-4191-8191-191919191919"
arguments = [
  "start", "IG19A-synthetic.pdf",
  "--operation-id", operation_id,
  "--source-id", "IG19A Synthetic Source",
  "--edition", "Synthetic digital edition",
  "--pagination-authority", "Explicit printed labels",
  "--publisher", "Synthetic Publisher",
  "--base-catalog", "IG19A-synthetic-base.xlsx",
  "--selected-by", "Scripted David input",
  "--prepare-staged-scoring"
]
command = [RbConfig.ruby, File.join(root, "bin/af-catalog"), *arguments]
stdout, stderr, status = Open3.capture3(environment, *command, chdir: root)
missing = %w[policy_definition policy_id policy_version policy_values]
expected_diagnostic = "af-catalog: MISSING_CHOICE: usage: bin/af-catalog start INPUT.pdf " \
                      "[required options]; missing: #{missing.join(', ')}\n"
confirmed = status.exitstatus == 1 && stdout.empty? && stderr == expected_diagnostic

entry = {
  "id" => "public-entry-without-internal-policy-reconstruction",
  "input" => "explicit source, edition, pagination, publisher, base choice and scoring intent",
  "precondition" => "parser admission only; no source/workbook eligibility claim",
  "identities" => {"requested_operation_id" => operation_id, "created_operation_id" => nil},
  "expected" => "no mandatory internal policy path or policy reconstruction at entry",
  "actual" => {"stdout" => stdout, "stderr" => stderr, "exitstatus" => status.exitstatus},
  "allowed_mutation" => "none in this admission diagnostic",
  "forbidden_mutation" => "source, catalog, Git, approval, execution or acceptance changes",
  "preserved_evidence" => "exact public command and parser diagnostic; no downstream artifacts created",
  "next_action" => "AdventureFinder owner judgment on entry defaults and continuous delegation",
  "command" => Shellwords.join(command),
  "status" => confirmed ? "FAIL" : "BLOCKED",
  "classification" => confirmed ? "D" : "A",
  "owner" => "adventure-finder",
  "requested_additional_facts" => confirmed ? missing : [],
  "assertion" => "exact MISSING_CHOICE text, exit 1 and empty stdout must agree"
}

downstream = [
  ["source-progression", "accepted conversion reaches boundary review"],
  ["boundary-review-and-staging", "one review episode, exact approval/freeze and staged lineage"],
  ["frozen-local-execution", "one frozen multi-capability workload, one worker, completed jobs run once"],
  ["complete-evidence-and-standing-release", "full denominator and exact standing application/finalization"],
  ["final-promotion", "one final approval promotes reviewed bytes and preserves independent roles and Git"]
].map do |id, expected|
  {
    "id" => id,
    "input" => "outputs of the preceding continuous stage",
    "precondition" => "admitted durable operation and all preceding validated owner evidence",
    "identities" => {"requested_operation_id" => operation_id, "authoritative_stage_identity" => nil},
    "expected" => expected,
    "actual" => "not executed; admission diagnostic supplies no downstream fixture or authority",
    "allowed_mutation" => "none while blocked",
    "forbidden_mutation" => "manufactured state, human acceptance, machine authority or promotion",
    "preserved_evidence" => "no downstream artifacts created or existing owner artifacts modified",
    "next_action" => "run a continuous owner-fixture journey after the entry defect is resolved",
    "status" => "BLOCKED",
    "classification" => confirmed ? "D" : "A",
    "owner" => "adventure-finder"
  }
end

matrix = [entry, *downstream]
puts "IG-19A entry diagnostic: #{JSON.generate(
  "scenario" => "ig19a-entry-contract",
  "scope" => "parser admission; not a continuous clean-path proof",
  "rows" => matrix,
  "totals" => %w[PASS FAIL BLOCKED].to_h { |state| [state, matrix.count { |row| row.fetch('status') == state }] },
  "decision_episodes" => {"attempted" => ["start intent"], "completed" => [], "three_episode_verdict" => "FAIL"},
  "acceptance" => {"standing_application" => nil, "individual_human_accepted" => 0, "ig16b_machine_accepted" => 0},
  "final_promotion" => "not executed"
)}"
exit(confirmed ? 1 : 2)
