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
worker source is only `rpof workers --json`, the provider-neutral registry
publication path; it performs no provider mutation.
