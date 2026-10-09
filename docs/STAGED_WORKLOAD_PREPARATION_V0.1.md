# Standard staged-workload preparation v0.1

AdventureFinder records operator scoring intent and coordinates one authorized,
zero-inference AFW workload. Pipeline remains the only staged-scoring authority;
AFW remains the only qualified-production selector and compiler. This flow does not
execute scoring or change a shared catalog role.

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

The command derives a stable workload ID from the operation. It asks pipeline to
issue exact staged authority, passes only pipeline-allocated Adventure IDs to AFW,
and omits AFW dimension selection so AFW's current qualified default remains
authoritative. It freezes the generic 131072-context/full-GPU-residency requirements
without naming a GPU, worker, provider, endpoint, placement profile, or budget.

Successful output reports the exact workload, case/metric denominator, and every
selected ID. A zero-record operation reports `NO_RUNNABLE_WORK`. AFW qualification
refusal lists every authorized ID as deferred and does not claim a prepared workload.
On restart, a complete existing workload is verified with
`bin/afw-verify-staged-workload`; it is never deleted or blindly rebuilt.

The next safe local action printed after preparation is read-only workload
verification. WLO execution is a later, explicit operator action and is not started
by this command.

After successful preparation, derive the deterministic planning-only capability
inventory and possible one-worker sequence from those exact frozen bytes:

```bash
bin/af-catalog plan-local-capabilities OPERATION_UUID --json
```

The output follows
[`adventurefinder-local-capability-plan/v0.1`](../contracts/adventurefinder-local-capability-plan/v0.1/README.md).
It preserves exact WLO requirements and pool constraints, reports no READY state,
and grants no execution, provider, capacity, or catalog-adoption authority.
