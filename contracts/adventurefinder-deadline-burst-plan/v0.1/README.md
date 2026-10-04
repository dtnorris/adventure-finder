# AdventureFinder deadline burst plan v0.1 (FO-21A)

Pure calculation over public `wlo-execution-measurements/v0.1` evidence.
This contract neither schedules work nor starts capacity. No provider evidence,
prices, availability or admission logic are implemented here.

## Input API

```ruby
require_relative "lib/adventure_finder_deadline_plan"
plan = AdventureFinderDeadlinePlan.plan(
  wlo: measurement_document, # JSON-decoded, string-keyed Hash
  deadline: "2026-10-04T18:00:00Z",
  baseline_workers: 2,
  max_workers: 8,            # optional mathematical bound; defaults to baseline + 2
  as_of: "2026-10-04T12:00:00Z" # optional; defaults to WLO measured_at_utc
)
```

No files, network, clock or execution state are read by this API. Input is not
mutated. No WLO, RPOF, LOW, AFW or AdventureFinder workspace runtime is imported.
The API accepts a document, not a path to WLO private retained state. FO-20's
composition is unchanged: it does not retain the measurement timestamp/window
needed here, so the original public WLO document is used directly.

WLO exposes no exact baseline worker count. `baseline_workers` is therefore
required positive integer caller-supplied planning context for candidate estimates.
The caller must associate that count with the measured throughput baseline. It
is not inferred from active intervals, worker identities or private bindings and
does not assert a current provider worker count or authority. Historical changes
in parallelism can make this simple extrapolation inaccurate.

Timestamps require an absolute ISO-8601 date/time including seconds and `Z` or a
numeric offset; up to nine fractional digits are accepted. They normalize to UTC
with nine fractional digits. There is no implicit `Time.now`. A measurement later
than explicit `as_of` is invalid. With no external `as_of`, the measurement is the
entire time reference; the planner cannot detect future/stale evidence relative
to real time. A later `as_of` holds remaining work fixed, without guessing progress.
Nothing sets or extends a campaign deadline: `deadline` is a completion target only.

## Public WLO evidence consumed

| Field | Use |
| --- | --- |
| `contract_version`, `read_only` | Require the public v0.1 read-only contract |
| `measured_at_utc` | Evidence time and default planning time |
| `work.remaining_jobs` | WLO's pending plus running count |
| `throughput.status`, `sample_count`, `jobs_per_hour` | Availability, sample size and measured baseline rate |
| `throughput.denominator_seconds` | Reported wall-clock denominator |
| `execution.window.status`, `started_at_utc`, `ended_at_utc`, `elapsed_seconds` | Window provenance and consistency checks |

WLO's numerator is completed successful attempts with valid timing, including
archived attempts. It is cumulative execution wall-clock throughput, not per-worker
throughput or a recent rolling rate. WLO includes retry-pending jobs in pending;
failed/interrupted jobs outside that remaining count are not invented as runnable
work here. `complete` means zero **reported remaining work**, not a declaration that
the entire execution succeeded. Paused/terminal evidence is hypothetical planning
input; this API never resumes or retries it.

Command duration evidence is available publicly but is not the wall-clock
throughput denominator. Existing WLO ETA uses the same rate and is not independent
evidence. Neither is consumed; neither worker intervals nor utilization can supply
an exact baseline worker count. Unavailable throughput/window cannot support an
estimate. The reported rate is used directly, including WLO's rounding, rather
than rebuilding measurements from attempt details.

## Formula and bounded candidates

Let `R` be remaining jobs, `H` the measured jobs/hour, `B` explicit baseline workers,
`N` a candidate worker count and `T` the planning time:

```text
scale(N) = N / B
throughput(N) = H * scale(N)
duration_seconds(N) = R * 3600 / throughput(N)
completion(N) = T + duration_seconds(N)
margin_seconds(N) = deadline - completion(N)
mathematically_meets_deadline(N) = margin_seconds(N) >= 0
```

Candidates enumerate every integer from `B` through `max_workers`, inclusive,
in ascending order; omission of the maximum yields B, B+1, B+2. The minimum is the
first meeting candidate **within that range**, not a claim about counts below B.
If none meets the deadline, the minimum is null. A `plan_available` result may
contain only candidates that miss the deadline.

Counts must be integers in 0..2^53-1 (workers positive); the maximum must be at
least B and the range can contain at most 1000 candidates. These are numeric and
allocation guards, not campaign limits. Invalid bounds are rejected, never clamped.
Intermediate math uses exact rationals from the supplied numeric rate. Displayed
numeric estimates use finite floats; completion timestamps truncate to nanoseconds.
The deadline comparison uses unrounded math. Unrepresentable/nonfinite estimates
or completion years outside 1..9999 fail closed with no partial candidate list.

## Output

`contract_version` is `adventurefinder-deadline-burst-plan/v0.1`; `read_only` and
`planning_only` are true. All results have `status`, `reason` (null on success),
`measured_at_utc`, `as_of_utc`, `deadline_utc`, `seconds_until_deadline`,
`remaining_jobs`, `sample_count`, `evidence_quality`, `measured_baseline_jobs_per_hour`,
`baseline_workers`, `candidate_max_workers`, `measurement_window`, `assumptions`,
`candidates`, and `minimum_candidate_workers_meeting_deadline`. Fields not established
by validation remain null; candidates remain empty without an estimate.

Every candidate contains `worker_count`, `scaling_factor`, `estimated_jobs_per_hour`,
`estimated_remaining_seconds`, `estimated_completion_at_utc`, `deadline_margin_seconds`,
`mathematically_meets_deadline`, `sample_count` and `evidence_quality`.
Negative margin means lateness. These are mathematical estimates under assumptions,
never available, affordable, admitted or safe-to-launch capacity proposals.

Evidence labels are deterministic sample-size descriptions: zero/missing/invalid
samples = `none`, 1..4 = `limited`, 5+ = `measured`. They express no statistical
confidence or assurance about linear scaling. Samples accompany every estimate.

Validation precedence:

1. Invalid contract, timestamp, future measurement or remaining count returns
   `insufficient_evidence` with a reason code.
2. Zero reported remaining work returns `complete`, even after the target deadline.
3. Positive work at/past the target returns `deadline_passed` (no possible future
   completion by that target). These two states need no rate, baseline or bounds
   and produce no numerical candidate estimates.
4. Otherwise missing/invalid baseline, bounds, sample count, nonpositive/nonfinite
   rate, unavailable window, inconsistent window or out-of-range math returns
   `insufficient_evidence`. No historical defaults or alternative rate is guessed.
5. Sufficient evidence returns `plan_available`.

Usable windows must have start < end <= measured time. Reported duration must be
positive and match the throughput denominator within 0.000001 seconds. It must
also differ by less than one second from timestamp duration, accommodating WLO's
whole-second timestamps and fractional elapsed value. Subsecond windows whose
public endpoints are identical are conservatively insufficient.

## Visible assumptions and ownership

Every output states: cumulative measured throughput is treated as the current
baseline; approximately linear scaling is assumed; baseline workers are caller
context; queueing, cold start, model load, provider startup, contention, failures
and diminishing returns are not separately modeled (historical effects may already
be present in WLO measurements); provider availability/cost/feasibility/admission
are not evaluated; a later planning time does not extrapolate progress.

The same inputs give deterministic output. There is no GPU selection, price,
budget, hourly ceiling, campaign deadline, worker maximum authority, automatic
start, admission, provider call or execution mutation. FO-21B/C/D are outside this
checkpoint. No CLI is added; existing FO-20 presentation remains unchanged.
