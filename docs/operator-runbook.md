# AdventureFinder composed operator runbook

AdventureFinder resolves registered production context and short handles. WLO
decides execution admissibility and owns attempts/recovery; LOW publishes local
capacity; RPOF decides paid capacity admission and lifecycle; AFW validates
scoring evidence; pipeline owns review state and human editorial decisions.
This runbook calls their public surfaces and does not interpret owner storage.

## Resolve and inspect — read-only

Set `AF_PROJECT_ROOT` to your component parent and run from the separate
`adventure-finder` checkout. Registered production roots can differ from the
development sibling roots. Never infer the executing checkout from pushed main.

```bash
export AF_PROJECT_ROOT=/Users/davidnorris/code/adventure-finder-components
export AF_ADVENTURE_FINDER_ROOT=/Users/davidnorris/code/adventure-finder
cd "$AF_ADVENTURE_FINDER_ROOT"
bin/af-status
bin/af-context batch 39
bin/af-context fleet A
bin/af-context batch 39 --verify
bin/af-context fleet A --verify
```

Resolution prints the exact frozen plan/campaign identity and component roots;
verification must pass before action. Batch 39 and fleet A are registered
examples, not a promise that those artifacts are mounted or presently active.
List the handles in the public AdventureFinder registry (there is no CLI list
subcommand):

```bash
ruby -ryaml -e 'YAML.safe_load_file("config/production_contexts.yml").fetch("contexts").each { |type, rows| puts "#{type}: #{rows.keys.join(", ")}" }'
```

For owner commands without a short-handle wrapper, extract only public context
fields. These shell helpers avoid manually constructing production paths:

```bash
resolve_operator_context() {
  BATCH_CONTEXT=$(bin/af-context batch 39 --verify --json) || return
  FLEET_CONTEXT=$(bin/af-context fleet A --verify --json) || return
  context_value() {
    ruby -rjson -e 'puts JSON.parse(STDIN.read).dig(*ARGV)' "$@"
  }
  AFW_ROOT=$(printf '%s' "$BATCH_CONTEXT" | context_value afw repository_root)
  WLO_ROOT=$(printf '%s' "$BATCH_CONTEXT" | context_value wlo repository_root)
  PLAN=$(printf '%s' "$BATCH_CONTEXT" | context_value afw plan_path)
  WLO_OUTPUT=$(printf '%s' "$BATCH_CONTEXT" | context_value wlo output_root)
  RPOF_ROOT=$(printf '%s' "$FLEET_CONTEXT" | context_value rpof repository_root)
  CAMPAIGN=$(printf '%s' "$FLEET_CONTEXT" | context_value rpof campaign_path)
  BUDGET=$(printf '%s' "$FLEET_CONTEXT" | context_value rpof budget_path)
  STATE_ROOT=$(printf '%s' "$FLEET_CONTEXT" | context_value rpof state_root)
  rpof_campaign() {
    "$RPOF_ROOT/bin/rpof" campaign "$@" --campaign "$CAMPAIGN" \
      --budget "$BUDGET" --state-root "$STATE_ROOT"
  }
}
resolve_operator_context
```

Run the assignments only after verification succeeds; if either command fails,
stop that workflow. Inspect `git rev-parse HEAD` and `git status --short` in each
returned execution root before consequential operations, including any required
ancestor/cleanliness checks in its owner runbook. Do not substitute a development
root to make a failed production verification pass.

## Model preflight and execution

`AF_STATE_ROOT` optionally selects existing external AF coordination storage for
catalog operations, `af-local bootstrap` capability requests and `af-batch`
worker-source inputs. It takes precedence over historical AF state paths without
changing registered owner artifacts or WLO/LOW storage. Unset preserves legacy
behavior; invalid explicit selection refuses before persistent work. Retain the
original selector for resume. The
[state ownership/replacement procedure](CATALOG_INGEST_FRONT_DOOR_V0.1.md#external-adventurefinder-coordination-state)
defines complete backups and recovery limits. Selection grants no execution,
approval, migration or publication authority.

**Read-only plan resolution, no worker contact/inference:**

```bash
bin/af-model preflight batch 39 qwen35 --json
bin/af-doctor job 39 0946-openness
bin/af-doctor job 39 0946-openness --logs --lines 15
bin/af-doctor fleet A
```

Aliases resolve through the frozen plan. `0946-openness` is an exact short job
handle within that plan; ambiguous or missing handles fail closed. Full canonical
IDs also work. Model preflight returns separate generic runtime requirements and
AF provenance; providers receive the generic request only.

**Local preparation / explicit model load:**

```bash
bin/af-local bootstrap batch 39 qwen35
```

This delegates exact capability establishment to LOW; it can load an already
installed model and retain capability evidence. It is separate from ordinary
registry publication. See [LOW's runbook](https://github.com/dtnorris/local-ollama-workers/blob/main/README.md#operator-runbook).

**Execution / retained-state mutation — foreground owner:**

```bash
bin/af-batch start 39
```

For an existing reviewed execution, use `bin/af-batch resume 39` instead.
AdventureFinder verifies the context and asks WLO's public action check; WLO
decides whether execution is admissible. Start never implies retry or breaker
acknowledgement. Ctrl-C cancels only this foreground execution through WLO and
retains evidence; provider capacity is unchanged.

**Read-only observation and admissibility:**

```bash
"$WLO_ROOT/bin/wlo" status "$PLAN" --output "$WLO_OUTPUT" --human
"$WLO_ROOT/bin/wlo" action-check "$PLAN" --workdir "$AFW_ROOT" --output "$WLO_OUTPUT" --action resume --json
bin/af-batch recovery 39
bin/af-batch retry 39 0946-openness --reason "reviewed transient timeout" --dry-run
```

A produced action-check document can say blocked. Review WLO diagnostics before
submitting an action. **Retained-state mutation:** remove `--dry-run` only after
reviewing the exact selected retry and reason, then resume separately. Breaker
acknowledgement is an explicit reviewed retry option, never implicit recovery.
See [WLO's runbook](https://github.com/dtnorris/workload-orchestrator/blob/main/docs/operator-workflow.md).

## Local or remote capacity

The registered batch selects local, remote or both named sources. WLO consumes
LOW/RPOF registries directly. Zero compatible READY capacity is diagnosed by WLO;
provider-active capacity is not READY. Neither batch start nor resume creates it.
Newly generated source configurations default every selected, registered
publisher to optional when the policy mapping is absent. An explicit mapping
can require fresh authority from a selected source. One unavailable optional publisher
does not block the other's exact compatible capacity; without either, the same
foreground owner waits. WLO status retains source-local failures and freshness.
See [foreground batch configuration](batch-foreground.md) for explicit overrides,
selection/registration rules, generation-only compatibility, and failure-bearing
terminal results.

**Read-only RPOF inspection:**

```bash
rpof_campaign plan --json
rpof_campaign status --json
rpof_campaign desired --json
```

**Provider mutation / paid capacity:** use RPOF's
[owner runbook](https://github.com/dtnorris/runpod-ollama-fleet/blob/main/docs/operator-runbook.md)
for bounded preview and `campaign start --authorize-paid`, exact generic
capability requests, original campaign limits and independent guardian proof.
The plan/preview must expose expected cost, hourly ceiling, cumulative compute
liability, original runtime/deadline and enforcement failure domain before paid
mutation. RPOF owns capacity selection and original campaign limits. Follow its runbook
for a refusal; do not create a new campaign to bypass it.

## Deadline planning — read-only advisory composition

Use public WLO measurements and RPOF planning evidence. Set `PROFILE_ID` and
`CAPABILITY` to the exact associated campaign profile and saved generic capability
request, `BASELINE_WORKERS` to the observed measurement context and `DEADLINE` to the
desired completion timestamp. The example records `AS_OF` after collecting the
evidence so its planning timestamp is not earlier than those observations.
The example evaluates targets 1 through 3; choose a bound supported by original
authority. Use a local `PLANNING_DIR` for derivative files (creating it and
redirecting stdout are local preparation):

```bash
collect_deadline_proposals() {
  mkdir -p "$PLANNING_DIR" || return
  "$WLO_ROOT/bin/wlo" measurements "$PLAN" --output "$WLO_OUTPUT" > "$PLANNING_DIR/wlo.json" || return
  for count in 1 2 3; do
    "$RPOF_ROOT/bin/rpof" planning-evidence --campaign "$CAMPAIGN" --budget "$BUDGET" \
      --state-root "$STATE_ROOT" --profile-id "$PROFILE_ID" --capability-request "$CAPABILITY" \
      --proposed-workers "$count" --json > "$PLANNING_DIR/rpof-$count.json" || return
  done
  ruby -rjson -e 'd=JSON.parse(File.read(ARGV[0])); puts JSON.pretty_generate(d.slice("campaign_id", "campaign_identity_sha256", "binding_sha256", "budget_id", "profile_id", "capability_fingerprint"))' \
    "$PLANNING_DIR/rpof-1.json" > "$PLANNING_DIR/association.json" || return
  AS_OF=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  bin/af-deadline-proposals --measurements "$PLANNING_DIR/wlo.json" \
    --association "$PLANNING_DIR/association.json" --deadline "$DEADLINE" \
    --baseline-workers "$BASELINE_WORKERS" --max-workers 3 --as-of "$AS_OF" \
    --max-evidence-age-seconds 300 --rpof-evidence "1=$PLANNING_DIR/rpof-1.json" \
    --rpof-evidence "2=$PLANNING_DIR/rpof-2.json" --rpof-evidence "3=$PLANNING_DIR/rpof-3.json" --json
}
collect_deadline_proposals
```

Stop if collection fails; do not reuse old files as fresh observations. Verify
the extracted association against fleet A and the selected batch/pool. The
measurement-to-profile association and baseline worker count are explicit caller
assertions; extraction alone does not prove them. The 300-second tolerance is an
explicit example, not provider authority. Missing samples, price, guardian proof
or fresh matching evidence must remain insufficient evidence.

The [proposal contract](../contracts/adventurefinder-deadline-burst-proposals/v0.1/README.md)
preserves planner assumptions, estimated cost and RPOF's original safety evidence.
Output is advisory with `mutation_permission=false`, including feasible proposals.
An operator-approved absolute target enters existing RPOF `campaign add` with its
current desired revision and reason; this is a separate **retained-state mutation
that can cause paid acquisition**. There is no public apply-proposal command.
The current add CLI submits a count, not a promise to acquire display-preferred
hardware. Original capability/hardware qualification and RPOF's fresh final
admission, reservation, budget/deadline/guardian checks remain authoritative.

## Manual single-job evidence review — optional workflow

This `af-review` workflow is for explicit individual human review, not the
canonical staged-scoring V2 standing-directive ingestion path. For the clean
V2 path, ordinary `af-catalog resume` after an approved boundary coordinates
complete AFW evidence binding and pipeline standing release; eligible proposed
scores do not require individual ACCEPT/HOLD/REJECT just to finalize a candidate.
See [the front-door V2 resume contract](CATALOG_INGEST_FRONT_DOOR_V0.1.md)
and [the pipeline's current runbook](https://github.com/dtnorris/af-pipeline/blob/main/docs/operator-runbook.md).

```bash
bin/af-review prepare 39 0946-openness
```

The installed review launcher selects the public checkout and private store
using the [catalog front-door selectors](CATALOG_INGEST_FRONT_DOOR_V0.1.md#start-behavior).
With `AF_DATA_PIPELINE_ROOT` unset, review resolves the public `af-pipeline`
checkout from `repos.yml` and `--root`. It verifies the pinned code and expected
store before asking AFW to bind evidence. Review packages use
`output/adventure-finder-review/PLAN/JOB` and ledgers use
`audits/adventure-finder-review/PLAN/JOB` under the selected store.
The registry must identify the intended AFW/WLO context. Preserve its paths
and the original selectors when recovering historical review packages.

AdventureFinder resolves the job and composes AFW evidence binding with pipeline
review preparation. AFW validates the scoring receipt; pipeline creates/reuses
the package and reports the existing ledger, counts and next human decision.
For this *manual review* route, follow the printed paths and pipeline's
[runbook](https://github.com/dtnorris/af-pipeline/blob/main/docs/operator-runbook.md)
to inspect evidence and choose ACCEPT/HOLD/REJECT. Command success is not an
accepted assessment. Preparation changes no canonical/AMC data; human editorial
mutation and canonical apply/finalize are separate pipeline-owned gates.

## Drain, remove and stop

For orderly workload quiescence, **WLO control mutation** is:

```bash
"$WLO_ROOT/bin/wlo" pause --output "$WLO_OUTPUT"
"$WLO_ROOT/bin/wlo" status "$PLAN" --output "$WLO_OUTPUT" --human --verbose
```

Use RPOF's [selected generation controls](https://github.com/dtnorris/runpod-ollama-fleet/blob/main/docs/SELECTED_WORKER_LIFECYCLE.md)
for drain, lower desired target and explicitly confirmed removal. Obtain exact
identities/revisions from public status and review bound/uncertain work through
WLO's [consumer-demand contract](https://github.com/dtnorris/workload-orchestrator/blob/main/contracts/wlo-consumer-demand/v0.1/README.md),
not retained files. Drain/removal authority belongs to RPOF.

**Provider teardown request, then read-only verification:**

```bash
rpof_campaign stop --reason "operator requested teardown"
rpof_campaign status --json
bin/af-doctor campaign A
```

Continue inspection until RPOF reports CLOSED with verified provider absence.
Stopping WLO or closing a view does not stop paid resources.

## Failure ownership

| Failure | Public next surface |
| --- | --- |
| Context/handle/frozen identity | `af-context --verify` and `af-doctor` |
| Execution/admissibility/retry | WLO status/doctor/action-check |
| Local Ollama readiness | LOW bootstrap/workers diagnostics |
| Provider/budget/guardian/lifecycle | RPOF campaign status/doctor |
| Scoring-evidence mismatch | AFW evidence-binding diagnostic |
| Review package/ledger/canonical conflict | Pipeline prepare-review/audit/apply report |

Stop at the owning component's refusal. Preserve evidence and original authority;
do not edit retained state by hand or read sibling implementation to invent a repair.
