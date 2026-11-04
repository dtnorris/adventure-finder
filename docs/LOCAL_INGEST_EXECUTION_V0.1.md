# Local ingest execution v0.1

This is the operator contract for advancing one prepared ingest workload through
local exact-capability establishment and one retained WLO execution. It follows
[`STAGED_WORKLOAD_PREPARATION_V0.1.md`](STAGED_WORKLOAD_PREPARATION_V0.1.md): AFW's
frozen plan remains workload authority, LOW remains worker/readiness authority, and
WLO remains scheduler, attempt, execution-lock, pause, retry, breaker, and retained
state authority.

Start only after `prepare-workload` has produced a verified workload and
`plan-local-capabilities` describes its exact immutable sequence:

```bash
bin/af-catalog local-start OPERATION_UUID --selected-by OPERATOR
```

This records one immutable local-only execution intent before it invokes either
component. The intent binds the operation, frozen workload and plan SHA-256,
capability-sequence digest, component roots, WLO workdir/output locator, and WLO
consumer identity. It grants ordinary execution and bounded local capability
establishment only. It explicitly grants no retry, recovery, breaker
acknowledgement, remote capacity, paid-resource, or catalog-adoption authority.

## Coordination guarantees

The driver holds an operation-scoped coordination lock while WLO owns its own
execution lock and attempts. It creates exactly one required `local` worker source
whose command is LOW's public `workers --json`; it never copies, merges, fabricates,
or edits a registry. Environment overrides remain supported through
`AF_PROJECT_ROOT`, `AF_ADVENTURE_FINDER_ROOT`, `AF_AFW_ROOT`, `LOW_REPO_ROOT`,
`LOW_STATE_ROOT`, and `WLO_REPO_ROOT`.

With `AF_STATE_ROOT` selected, AF reads preparation records and retains execution
intent, coordinator phase/lock, worker-source configuration and capability inputs
in that external namespace. Unset selection preserves legacy paths. Planning,
start, resume and status use the original namespace and bound owner selectors;
invalid or changed selection refuses without importing context or authorization.

WLO's existing output remains
`$AF_ADVENTURE_FINDER_ROOT/output/local-ingest-executions/v0.1/OPERATION_UUID/wlo`.
Its workdir, consumer identity, attempts and accounting are unchanged. Retain WLO
state independently even when nested in a checkout; AFW and LOW state also remain
with their owners. The
[front-door state contract](CATALOG_INGEST_FRONT_DOOR_V0.1.md#external-adventurefinder-coordination-state)
defines the complete backup set and narrower same-path replacement proof.

For each frozen sequence step, the driver first inspects LOW's fresh public
publication. If the exact requirement is not READY, it gives LOW the frozen generic
capability request and then independently re-reads the public publication and applies
WLO's public matcher. A successful bootstrap exit, an installed model, an alias, or
previous evidence is not readiness.

WLO alone selects jobs and workers. When unmet WLO demand requires the next
capability, the driver requests a graceful pause only after every affected public
consumer-demand observation is fresh, active, quiescent, and has zero bound or
uncertain jobs. It persists coordinator drain ownership before requesting the pause,
then waits for public paused/drained state and an inactive executor. Only then may it
ask LOW for the next exact capability and resume the same plan, workdir, output,
consumer identity, attempts, breakers, and completed jobs. Multiple evidenced
capabilities still describe one worker and one WLO busy slot.

Stale, unknown, busy, failed, or missing observations never imply idle or success.
They wait only for the bounded observation window and then fail with the owning
public gate. An existing pause without persisted coordinator drain ownership is an
operator pause and is never silently cleared. A fresh process reconstructs these
decisions from the immutable intent, coordinator phase, LOW publication, WLO
action-check/status, and WLO consumer-demand; any changed binding is refused.

## Operation and cancellation

`local-start` and `local-resume` are foreground commands. The child `wlo run` or
`wlo resume` process remains the foreground work owner. Ctrl-C or termination is
forwarded to WLO's process group, so WLO applies its normal foreground cancellation
contract and retains interruption evidence. If the coordinator must abort while it
owns that child, it terminates and reaps the child rather than leaving a second
driver. Interrupted or failed work remains behind WLO's explicit review and
`retry-failed`/breaker controls; rerunning the local command does not authorize them.
An already-active WLO executor is observed and is never launched a second time.

Use the grounded status view at any point:

```bash
bin/af-catalog local-status OPERATION_UUID
bin/af-catalog local-resume OPERATION_UUID
```

Status reports selected/deferred AFW coverage, exact readiness for every frozen
capability, WLO execution/executor state, and the appropriate public continuation or
recovery handoff. Plain `local-resume` is valid for an unstarted intent or a completed
coordinator drain. An unrelated operator pause remains a gate until WLO is publicly
drained and the operator supplies the distinct
`--continue-operator-pause` authorization. Neither form retries terminal jobs or
acknowledges a breaker.

WLO `completed` means only that the exact execution is terminal. It does not mean
AFW has complete receipts and does not accept scores or promote a catalog. The driver
prints the exact AFW evidence bind and publication commands. Only after the published
manifest reports `evidence_complete=true` is the deterministic ingest continuation:

```bash
bin/af-catalog resume OPERATION_UUID
```
