# Standard staged-workload preparation v0.1 and v0.2

AdventureFinder records operator scoring intent and coordinates one authorized,
zero-inference AFW workload. Pipeline remains the only staged-scoring authority;
AFW remains the only qualified-production selector and compiler. This flow does not
execute scoring or change a shared catalog role.

This document describes **explicit preparation and local-start controls** for an
operator who needs to inspect or separately authorize those stages. In the
canonical V2 clean path, ordinary `af-catalog resume` after approved boundaries
reuses these component authorities and continues through local execution and
standing release automatically; the manual preparation, plan and `local-start`
commands below are not additional required operator decision episodes.

Record the explicit choice while starting the durable ingest:

```bash
bin/af-catalog start INPUT.pdf \
  --source-id SOURCE --edition EDITION \
  --pagination-authority AUTHORITY --publisher PUBLISHER \
  --base-catalog BASE.xlsx \
  --policy-definition "$AF_DATA_PIPELINE_ROOT/config/staged_scoring_input_policy_v0.1.json" \
  --policy-id approved-new-records --policy-version 1 \
  --policy-values '{"selection":"afw-qualified-default"}' \
  --selected-by OPERATOR --prepare-staged-scoring
```

If the affirmative choice was not recorded at start, it can be made once after the
boundary review. Ordinary resume then reuses that immutable choice without another
prompt:

```bash
bin/af-catalog resume OPERATION_UUID --prepare-staged-scoring --selected-by OPERATOR
bin/af-catalog resume OPERATION_UUID
```

After the boundary freeze, editorial approval, and successor-version authorization
exist, prepare through the same command family:

```bash
bin/af-catalog prepare-workload OPERATION_UUID \
  --freeze BOUNDARY_FREEZE.yml \
  --approval APPROVAL.json \
  --editorial-bundle EDITORIAL_BUNDLE_DIR \
  --historical-project-state RETAINED_PROJECT_STATE.yml
```

Preparation defaults to the manifest-pinned `af-scorer` checkout under
`AF_PROJECT_ROOT`. An explicit `AF_SCORER_ROOT` selects a different checkout,
including the original scorer for historical recovery. For split preparation,
set `AF_SCORER_CONFIG=/absolute/path/to/input-selection.yml`. Use AFW's roots-only
configuration: `paths.xlsx_root`, `specification_root`, `source_root`,
`output_root`, and optional `files.source_registry`. The coordinator passes the
same file through staged selection, compilation, inspection and the rendered
inspection command. Keep this selector set for release continuation: its v0.2
release inputs carry `selection_scorer_config` to pipeline's AFW owner verifier.
The immutable selection binds the file path and exact bytes. Missing or changed
configuration refuses continuation; exact restoration permits revalidation.
This does not rebind stored operations, approve inputs or qualify execution.

The command derives a stable workload ID from the operation and asks pipeline to
issue exact staged authority for the complete new-ID allocation. It then consumes
AFW's public `afw-staged-selection/v0.1` owner result. AFW, not the front door,
classifies every allocated ID as `selected-qualified`, `legitimately-deferred`, or
`refused`, and owns conditional Levels, page, blank-score, source-preflight,
dimension, model, profile, runtime and capability decisions. Only the exact selected
subset can enter the workload. The front door freezes the generic
131072-context/full-GPU-residency requirements without naming a GPU, worker,
provider, endpoint, placement profile, or budget.

The durable `adventurefinder-staged-workload-preparation/v0.2` result retains the
AFW selection identity, complete reasoned disposition ledger, exact case/metric
denominator and the final `afw-workload-inspection/v0.1` evidence. A zero allocation
reports `NO_SUCCESSOR_NEEDED`; a nonempty allocation with no qualified IDs reports
`ALL_DEFERRED`. Invalid or unsupported evidence reports `REFUSED`, never deferred.
None of those outcomes claims a runnable workload or completed scoring.

Before any build, reuse, deterministic regeneration or refusal of existing workload
state, the coordinator consumes AFW's read-only inspection action. `fresh-build`
permits the public selection/compiler flow, `reuse` preserves exact frozen bytes,
and `regenerate` permits only AFW's existing deterministic generated-build recovery.
`refuse` preserves partial, conflicting or corrupt evidence without deletion,
overwrite or workload-identity churn. A second inspection must report verified
`reuse` before AdventureFinder records `PREPARED`. Existing results remain observed
evidence with no completion claim and are never removed or regenerated.

The next safe local action printed after preparation is the exact public read-only
AFW inspection command, including its authority, selection, catalog and capability
bindings. WLO execution is a later, explicit operator action and is not started by
this command.

Existing v0.1 `PREPARED` results remain readable by the local-capability planner.
New preparation writes v0.2 and requires the retained AFW selection and final reuse
inspection before local planning can proceed.

After successful preparation, derive the deterministic planning-only capability
inventory and possible one-worker sequence from those exact frozen bytes:

```bash
bin/af-catalog plan-local-capabilities OPERATION_UUID --json
```

The output follows
[`adventurefinder-local-capability-plan/v0.1`](../contracts/adventurefinder-local-capability-plan/v0.1/README.md).
It preserves exact WLO requirements and pool constraints, reports no READY state,
and grants no execution, provider, capacity, or catalog-adoption authority.

After reviewing that plan, explicitly authorize and drive its local-only execution:

```bash
bin/af-catalog local-start OPERATION_UUID --selected-by OPERATOR
bin/af-catalog local-status OPERATION_UUID
```

The durable coordination, capability-transition, restart, cancellation, and evidence
handoff rules are defined by
[`LOCAL_INGEST_EXECUTION_V0.1.md`](LOCAL_INGEST_EXECUTION_V0.1.md). The driver keeps
the same AFW workload and WLO execution throughout; it does not add retry, remote
capacity, scoring acceptance, or catalog-adoption authority.
