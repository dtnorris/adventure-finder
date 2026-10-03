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

Retained-state decisions are conservative:

| Retained state | `start` | `resume` |
| --- | --- | --- |
| none | start exact frozen plan | refuse; use `start` |
| active executor | refuse duplicate owner | refuse duplicate owner |
| paused | refuse; point to `resume` | delegate to WLO resume |
| complete | report complete; execute nothing | report complete; execute nothing |
| failed/interrupted/breaker/halt | require explicit reviewed recovery | require explicit reviewed recovery |
| safe pending state | continue pending work only | use WLO resume semantics |
| identity or plan drift | fail closed | fail closed |

`AF_PROJECT_ROOT` relocates every registered repository and runtime path. The
Batch context selects `local`, `remote`, or both in `worker_sources`.
AdventureFinder writes a strict `wlo-worker-sources/v0.1` configuration and
hands it to WLO; it does not poll, merge, deduplicate or republish registry
snapshots. WLO invokes the observational `low workers --json` and/or
`rpof workers --json` publishers directly, preserves each registry namespace
and checkpoint, and schedules across their union. Source failure or identity
and revision conflict fails closed instead of being presented as zero capacity.
This handoff performs no provider mutation or local bootstrap.

Local capability establishment is a separate explicit operator action:

```bash
bin/af-local bootstrap batch 39 qwen35
```

The command resolves the alias against the frozen plan and invokes LOW only with the
resulting exact `adventurefinder-model-requirement/v0.1` artifact. A local worker that
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
acknowledgement is available only as an explicit retry/resume flag.

`bin/af-batch repair 39 --reason TEXT --dry-run` reports the current repair
boundary. There is no deterministic generic repair today, so an actual repair
request fails closed without changing retained evidence.
