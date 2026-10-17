# Foreground production batches

AdventureFinder resolves a registered production batch and hands the terminal
to WLO's existing foreground owner:

```bash
bin/af-batch start 39
bin/af-batch resume 39
```

`start` verifies the exact FO-01 plan ID and SHA, then uses WLO `run`. It does
not compile or regenerate AFW artifacts, clear pause, retry failed/interrupted
jobs, acknowledge a breaker, or replay completed work. `resume` requires an
existing retained execution and delegates only to WLO's foreground `resume`.

Both commands are **FOREGROUND WORK OWNERS**. Ctrl-C reaches WLO directly;
FO-06 cancels only this execution's owned process groups and retains partial
evidence. The FO-05 dashboard is rendered by WLO. Neither command starts,
changes, or tears down RPOF capacity. With no compatible READY workers, WLO
truthfully remains in its waiting state.

AdventureFinder calls WLO's public
[`wlo-execution-action-check/v0.1`](https://github.com/dtnorris/workload-orchestrator/blob/main/contracts/wlo-execution-action-check/v0.1/README.md)
before delegation. WLO owns retained-state admissibility and rechecks during the
real operation. AdventureFinder presents the returned disposition/reason; it
does not interpret execution storage. See the [composed runbook](operator-runbook.md).

`AF_PROJECT_ROOT` relocates every registered repository and runtime path. The
Batch context selects `local`, `remote`, or both in `worker_sources`.
An explicit `worker_source_policies` mapping opts a context into
`wlo-worker-sources/v0.2`. It must match every selected source exactly, with
each value `required` or `optional`. Batch 39 selects both publishers:

```yaml
worker_sources: [local, remote]
worker_source_policies:
  local: optional
  remote: optional
```

Contexts without this mapping retain v0.1 and all-required behavior. Invalid,
duplicate, missing or extra configuration authority refuses before launch;
optional availability never excuses missing publisher executables or Gemfiles.
Each command uses its component Gemfile/workdir. `env -u BUNDLE_LOCKFILE` clears
inherited lockfile authority before component Bundler starts; source environments
remain string maps as WLO requires.

AdventureFinder hands this configuration to WLO; it does not poll, merge,
deduplicate or republish registry
snapshots. WLO invokes the observational `low workers --json` and/or
`rpof workers --json` publishers directly, preserves each registry namespace
and checkpoint, and schedules across their union. Optional publishers may be
unavailable independently: retained pending work waits when neither has exact
compatible READY capacity, and later capacity is consumed without restarting
the foreground execution. A healthy publisher continues after an idle optional
publisher fails. A valid empty publication is ordinary zero capacity. Source
health, policy, poll failure and freshness remain visible in WLO human/JSON
status. A failed refresh cannot rewrite accepted evidence or extend its expiry;
only that source's unexpired accepted capacity remains usable. Duplicate
registry IDs stay fatal. Loss of a worker bound to running work still halts for
explicit recovery. See WLO's authoritative
[source contract](https://github.com/dtnorris/workload-orchestrator/blob/main/docs/worker-sources.md).
This handoff performs no provider mutation or local bootstrap; capacity must be
established separately through explicit operator action.

Finishing all pending jobs does not erase retained failures. WLO reports
`workload_failed` and foreground exit 2 when failed jobs remain; this is a
failure-bearing terminal result, even at 100% terminal progress. Resume grants
no retry authorization and never substitutes a model, digest, context or worker.

Local capability establishment is a separate explicit operator action:

```bash
bin/af-local bootstrap batch 39 qwen35
```

The command resolves the alias against the frozen plan and invokes LOW only with the
resulting exact generic `ollama-capability-request/v0.1` artifact. A local worker that
advertises multiple compatible models remains one worker and therefore one WLO busy
slot across all pools.

## Audited recovery

Repair, resume, and selected retry are separate actions:

```bash
bin/af-batch retry 39 0946-openness --reason "confirmed transient model timeout" --dry-run
bin/af-batch retry 39 0946-openness --reason "confirmed transient model timeout"
bin/af-batch recovery 39
bin/af-batch resume 39
```

Retry requires exact canonical IDs or unambiguous FO-07 short handles. WLO
archives prior attempt evidence, records hashes and the human reason, and queues
only selected failed/interrupted jobs. It never starts execution. Resume later
runs pending work; unrelated terminal jobs remain terminal. Breaker
acknowledgement on this front door is an explicit reviewed retry flag; WLO's
public resume command also has its own explicit acknowledgement option.

`bin/af-batch repair 39 --reason TEXT --dry-run` reports the current repair
boundary. There is no deterministic generic repair today, so an actual repair
request fails closed without changing retained evidence.
