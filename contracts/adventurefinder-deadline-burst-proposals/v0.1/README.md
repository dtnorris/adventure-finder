# AdventureFinder deadline burst proposals v0.1 (FO-21C)

`adventurefinder-deadline-burst-proposals/v0.1` is advisory composition of the
landed FO-21A planner and supplied public FO-21B documents. Every output is
`read_only: true`, `planning_only: true`, `mutation_permission: false`.

## API and CLI

```ruby
require_relative "lib/adventure_finder_deadline_proposals"
result = AdventureFinderDeadlineProposals.compose(
  wlo: wlo_document,
  deadline: "2026-10-04T18:00:00Z", baseline_workers: 2, max_workers: 6,
  as_of: "2026-10-04T12:00:00Z", max_evidence_age_seconds: 300,
  association: explicit_identity,
  rpof_evidence: { 2 => rpof_for_two, 3 => rpof_for_three, 4 => rpof_for_four }
)
puts AdventureFinderDeadlineProposals.render(result)
```

```text
bin/af-deadline-proposals --measurements WLO.json --association association.json \
  --deadline 2026-10-04T18:00:00Z --baseline-workers 2 --max-workers 6 \
  --as-of 2026-10-04T12:00:00Z --max-evidence-age-seconds 300 \
  --rpof-evidence 2=RPOF-2.json --rpof-evidence 3=RPOF-3.json \
  --rpof-evidence 4=RPOF-4.json --rpof-evidence 5=RPOF-5.json \
  --rpof-evidence 6=RPOF-6.json --json
```

The core has no file, network, subprocess, environment or implicit clock access.
The CLI reads only explicitly supplied JSON paths and writes only stdout/stderr.
It does not fetch or refresh owner evidence. Exit 0 means a document was produced,
not that any proposal is feasible; inspect status. Invalid CLI arguments, duplicate
worker keys, unreadable files or invalid JSON exit 1. Omit `--json` for the human
view. Missing evidence is allowed for reporting but never extrapolated: that count
cannot be feasible. Unused collection keys are not evaluated or recommended.

The API invokes `AdventureFinderDeadlinePlan.plan` with the exact supplied WLO
measurement and mathematical inputs. It never accepts an independently supplied
plan, preventing a join to a plan derived from another measurement. FO-21A owns all
throughput, scaling, duration, completion, margin, candidate bounds and evidence
quality calculations, unchanged. Its complete output is retained as `deadline_plan`.
The FO-21A contract/version and read-only/planning-only markers are checked.

## Explicit association and temporal consistency

`association` must supply all six exact RPOF identity fields:

- campaign_id
- campaign_identity_sha256
- binding_sha256
- budget_id
- profile_id
- capability_fingerprint

Digests are lowercase 64-hex strings. Each document must match that association,
the RPOF v0.1 version and read-only marker. The Integer collection key, FO-21A
worker_count and RPOF proposal.profile_workers must be identical. Counts are
absolute targets for this profile, not increments. No plan is inferred for a
missing count and no authority is inferred from another count's preview.

WLO's public contract supplies execution identity but does not bind its measured
throughput to an RPOF profile. The association and baseline worker context are
explicit caller assertions, not claimed to have been independently proven. The
original WLO measurement is validated exclusively through FO-21A: contract/version,
read_only, measured_at_utc, work.remaining_jobs, throughput status/sample_count/
jobs_per_hour/denominator_seconds, and execution.window status/start/end/duration.
No attempt metadata or WLO private state is read.

`as_of` and `max_evidence_age_seconds` are mandatory caller-selected planning
context. The latter is a nonnegative Integer, not a new provider freshness rule.
Both WLO and RPOF observations must be at or before as_of and no older than that
allowance; equality is accepted. This bounds their skew without inventing a
universal staleness threshold. No `Time.now` is consulted. The result carries WLO
measurement time, planning time and each matched provider observation time.
Explicitly choosing a historical as_of gives a historical proposal, not a claim
about present-time availability. Stale WLO measurements cannot support feasibility
or a mathematical-only refusal about current work.

All evaluated matching documents must agree on immutable limits, original campaign
deadline, profile maximum and billing scope. Conflicting authority makes their
composition insufficient. Current commitments may change between observations;
owner snapshots are retained and never merged into a synthetic budget. Candidate
identities must be unique and FO-15 ranks must match supplied order; catalog failure
permits null ranks. No candidate sorter or new hardware qualifier is introduced.

## Status and recommendations

Each proposal preserves every FO-21A candidate field, including sample count and
evidence quality. It adds RPOF observation/deadline, authority, admission preview,
hardware candidates, billing scope, provider caveats, selected display hardware,
tracked compute estimates, status, reasons and mutation_permission=false.

- **feasible**: fresh valid FO-21A evidence mathematically meets the target; matching
  RPOF overall preview is admissible; at least one candidate has authorized=true,
  eligible=true, observed finite positive price, reported availability, a finite
  nonnegative projected aggregate rate and an admissible preview. The included
  owner safety report must be v0.1/PASS, with no refusal reasons and matching
  identity/projected campaign count/rate/deadline. This validates consistency of
  owner evidence; it does not recalculate owner safety or admission.
- **infeasible**: trusted mathematical evidence misses the target, the matched
  RPOF preview refuses, or original provider authority expires at/before planning
  time or before predicted completion. Provider refusal reasons are retained.
- **insufficient_evidence**: missing, malformed, contradictory, mismatched, future
  or too-old evidence; unavailable throughput, catalog, price or safety proof.
  Unknown remains unknown unless an independent known hard fact already refuses.

A fresh mathematical miss can establish infeasibility even without provider
evidence. A verified expired/too-short campaign deadline is likewise a hard fact.
Malformed identity never establishes a provider fact. FO-21A `deadline_passed`
becomes infeasible; `complete` is preserved with no recommendation and means only
zero reported remaining work. FO-21A insufficiency retains its reason and creates
no invented numerical candidates.

Recommendations contain feasible proposals only, in ascending worker count.
Within a count, the first admissible RPOF-ranked candidate is the display choice;
all alternatives remain in owner order. This follows FO-15 cheap-first ordering,
without globally optimizing price or choosing outside RPOF authority. The preferred
proposal is the first recommendation; it is null when none is feasible.

## Cost, deadlines and limitations

`projected_aggregate_hourly_tracked_compute_usd` is copied from the selected RPOF
candidate's projected_aggregate_hourly_rate_usd. No committed-rate arithmetic is
reimplemented. `estimated_remaining_tracked_compute_usd` equals that rate times
FO-21A estimated_remaining_seconds / 3600. Candidate alternatives also show this
estimate when their price/rate evidence supports it. It is cumulative compute over
the projected remaining interval, not a guaranteed bill or budget admission proof.
It includes other profiles' existing commitments if present in the RPOF aggregate
and assumes the whole campaign rate remains constant throughout that interval.
It does not add accrued compute or extrapolate billing between observation times.
Nonfinite completion-cost arithmetic is insufficient evidence.

RPOF authority, original safety report, crash-liability estimate and billing scope
are retained separately without rewrite. A completion-cost estimate never replaces
FO-08 crash-liability admission or creates a new budget. Storage, network, taxes,
credits and other unproven provider charges remain outside tracked pod compute.

`target_completion_deadline_utc` is the workload target. Each proposal's
`rpof_campaign_deadline_utc` is immutable provider authority expiration. Neither is
changed. Completion after campaign expiry cannot be feasible even when the target
is later and RPOF's immediate admission preview passes. Equal predicted completion
and campaign expiry is allowed as a zero-margin mathematical scenario.

FO-21A assumptions remain visible under planner_assumptions and in the nested plan.
The human view prints them alongside composition assumptions: approximate linear
scaling; cumulative measured baseline; caller-provided baseline workers; startup,
load, queueing, contention, failures and diminishing returns not separately modeled.
Estimated completion excludes prospective provider cold start. Unknown cold start
is not measured zero and can make an otherwise feasible estimate miss its target.
Availability is observational, not reserved or guaranteed proposed-count capacity.
Actual admission must recheck current evidence. No command starts, adds, drains,
removes or stops capacity, reserves budget, writes owner state or changes authority.

Real proposal selection, RPOF mutation/admission and broad full-suite closeout are
explicitly deferred to FO-21D.
