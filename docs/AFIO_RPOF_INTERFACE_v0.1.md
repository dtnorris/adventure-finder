# AFIO ↔ RPOF Minimal Inter-Repository Interface v0.1

**Status:** proposed for freeze on `adventure-finder` `main`
**Parent contract:** `docs/LOCAL_MODEL_EVAL_SPLIT_CONTRACT_v0.1.md`
**Scope:** the smallest machine-readable boundary needed for AFIO to use RPOF without a shared Ruby dependency
**Owner:** `adventure-finder` workspace repository

## 1. Purpose

This document defines the first executable boundary between:

- **AFIO (`af-inference-orchestrator`)** — AdventureFinder inference/workload intent; and
- **RPOF (`runpod-ollama-fleet`)** — optional RunPod/Ollama remote-compute infrastructure.

It refines the frozen split contract without changing it.

The v0.1 interface intentionally exposes only two AFIO-facing operations:

1. **read-only capability check** against an already operator-managed RPOF fleet; and
2. **generic dispatch** of opaque jobs against the checked logical fleet/workers.

Fleet creation, scaling, replacement, bootstrap, model-cache population, tunnel
repair, lease management, and destruction remain **RPOF operator APIs**, not AFIO
dependencies in v0.1.

That choice preserves the proven current control-plane workflow and avoids turning
the initial split into an orchestration-platform redesign.

## 2. Dependency shape

AFIO and RPOF communicate through:

```text
CLI invocation
    +
versioned JSON request/result files
    +
durable dispatch evidence directory
```

They do **not** communicate through:

```text
Ruby require/import
shared private gem/library
sibling lib/ paths
RPOF internal class names
AFIO internal class names
provider state files read directly by AFIO
```

AFIO supplies the path to the RPOF executable. The interface does not require a
hard-coded sibling checkout path.

## 3. Version identifiers

v0.1 freezes these machine-readable identifiers:

```text
afio-rpof-capability-check-request/v0.1
afio-rpof-capability-check-result/v0.1
afio-rpof-dispatch-request/v0.1
afio-rpof-dispatch-summary/v0.1
```

Unknown versions fail closed.

Schemas live under:

```text
contracts/afio-rpof/v0.1/
```

The schemas are normative for field shape. This document is normative for
behavior, ownership, exit status, and evidence semantics.

## 4. Operation A — capability check

### Invocation

```text
bin/rpof capability-check \
  --request CAPABILITY_REQUEST.json \
  --output CAPABILITY_RESULT.json
```

This operation is **read-only**.

It may inspect RPOF-owned fleet state, provider state, bootstrap/provenance
artifacts, tunnels, Ollama endpoints, and current cost/lease state. It must not
create, scale, replace, destroy, bootstrap, pull a model, repair a tunnel, or
otherwise mutate paid infrastructure.

### Request

The request identifies:

- a logical RPOF fleet key;
- either all active logical workers or explicit logical worker indices;
- required Ollama model name(s);
- optional expected exact model digest(s);
- required context length;
- the current v0.1 requirement that selected models be fully GPU resident; and
- optionally an exact required GPU id.

AFIO resolves AdventureFinder model aliases before crossing the boundary. RPOF
receives only Ollama/provider-generic requirements.

Example:

```json
{
  "contract_version": "afio-rpof-capability-check-request/v0.1",
  "fleet_key": "scoring-a6000",
  "worker_selector": {
    "mode": "indices",
    "indices": [1, 2, 3, 4]
  },
  "requirements": {
    "models": [
      {
        "name": "qwen3.6:35b-a3b",
        "expected_digest": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      }
    ],
    "required_context_length": 131072,
    "require_fully_gpu_resident": true,
    "required_gpu_id": "NVIDIA RTX A6000"
  }
}
```

`expected_digest` and `required_gpu_id` are optional because current LME behavior
can prove an internally pinned exact digest/GPU contract without AFIO independently
supplying those values. When AFIO does supply either value, RPOF must verify it
exactly.

### Result

RPOF writes one result document even when readiness fails.

The result contains:

- `ready`;
- the requested logical fleet key;
- the opaque current fleet id, when available;
- the selected logical worker indices;
- generic verified capabilities/provenance, when available;
- generic diagnostics; and
- optional generic billing snapshot.

Example:

```json
{
  "contract_version": "afio-rpof-capability-check-result/v0.1",
  "ready": true,
  "fleet_key": "scoring-a6000",
  "fleet_id": "opaque-fleet-id",
  "selected_worker_indices": [1, 2, 3, 4],
  "capabilities": {
    "gpu_id": "NVIDIA RTX A6000",
    "bootstrap_run_id": "bootstrap-20260914",
    "models": [
      {
        "name": "qwen3.6:35b-a3b",
        "digest": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        "context_length": 131072,
        "fully_gpu_resident": true
      }
    ]
  },
  "diagnostics": [
    {
      "code": "fleet.active",
      "status": "PASS",
      "detail": "selected logical fleet is active"
    }
  ],
  "billing": {
    "tracked_elapsed_seconds": 300.0,
    "current_tracked_hourly_rate_usd": 0.74,
    "estimated_accrued_cost_usd": 0.0617
  }
}
```

AFIO may use `ready`, `fleet_key`, `fleet_id`, `selected_worker_indices`, and
verified generic capability/provenance as program logic.

`diagnostics[].detail` is human diagnostic text and must **not** become a parsed
cross-repository API.

### Capability-check exit status

```text
0  result written and ready=true
1  result written and ready=false
2  invalid invocation, unreadable request, unsupported contract version,
   or request-schema violation
```

AFIO must read the result document rather than infer capability details from
human stdout/stderr.

## 5. Operation B — generic dispatch

### Invocation

```text
bin/rpof dispatch \
  --request DISPATCH_REQUEST.json \
  --workdir AFIO_WORKDIR \
  --output EVIDENCE_DIR
```

`--workdir` is required.

RPOF executes every job with that one working directory. This preserves the
current LME behavior in which relative workload argv such as
`bin/lme-production-remote-job` resolves inside the orchestration repository,
without adding `cwd` to the frozen per-job envelope.

RPOF treats `--workdir` as an opaque execution location. It must not inspect the
directory to infer AdventureFinder semantics.

### Request

The request contains:

- the logical fleet key;
- the opaque `expected_fleet_id` returned by the capability check;
- explicit logical worker indices returned/approved by the capability check;
- the generic job list; and
- whether stable affinity grouping is requested.

Example:

```json
{
  "contract_version": "afio-rpof-dispatch-request/v0.1",
  "target": {
    "fleet_key": "scoring-a6000",
    "expected_fleet_id": "opaque-fleet-id",
    "worker_indices": [1, 2, 3, 4]
  },
  "group_by_affinity": true,
  "jobs": [
    {
      "job_id": "production-0001",
      "argv": ["bin/lme-production-remote-job", "experiments/example.yml"],
      "env": {
        "LME_RUNTIME_MAX_TOKENS": "8192"
      },
      "affinity": "model:qwen3.6:35b-a3b"
    }
  ]
}
```

### Stable job envelope

Each job contains only:

```text
job_id
argv
env       (optional; defaults to {})
affinity  (optional)
```

No additional per-job fields are part of v0.1.

RPOF may validate generic execution safety. It must not parse AdventureFinder
meaning from any of those values.

### Dispatch target safety

Before the first assignment and while dispatch is active, RPOF must fail closed if
the selected logical fleet:

- is missing or inactive;
- no longer has `expected_fleet_id`;
- no longer contains a selected logical worker;
- changes a selected worker's physical identity/routing unexpectedly; or
- loses the generic infrastructure readiness required for safe assignment.

This preserves the current dispatcher's protection against fleet/routing changes
during a run without exposing physical pod identity to AFIO.

### Compatibility environment injection

For the initial bridge only, RPOF must preserve the current workload environment
semantics by injecting:

```text
LME_JOB_ID
LME_WORKER_INDEX
LME_OLLAMA_URL
```

A job may not override those names.

These are **v0.1 compatibility names**, not permanent RPOF branding. Replacing
them with neutral names requires a later contract version or an explicitly
backward-compatible dual-injection migration.

### Secrets

AFIO may supply secret values through `env` when a workload genuinely requires
them.

RPOF must not persist supplied environment **values** in generic evidence.
Persisting environment variable names is allowed.

Secrets must not be placed in argv because argv is durable generic evidence.

## 6. Dispatch evidence

RPOF owns the evidence directory.

The v0.1 layout is:

```text
EVIDENCE_DIR/
├── manifest.json
├── summary.json
└── jobs/
    └── <job_id>/
        ├── metadata.json
        ├── stdout.log
        └── stderr.log
```

All of those files are durable generic execution evidence.

To keep the inter-repository dependency minimal:

- **`summary.json` is the machine-readable AFIO-facing output contract.**
- `manifest.json` and per-job `metadata.json` are RPOF-owned durable evidence and
  resume state in v0.1.
- AFIO may preserve/archive those files but must not depend on their private fields
  unless a later interface version promotes those fields into the public contract.
- `stdout.log` and `stderr.log` are opaque workload evidence referenced by
  `summary.json`.

This deliberately prevents AFIO from coupling itself to RPOF's internal resume
manifest while retaining the evidence currently proven by LME.

## 7. Dispatch summary

`summary.json` conforms to:

```text
contracts/afio-rpof/v0.1/dispatch-summary.schema.json
```

The allowed top-level status values are:

```text
completed
workload_failed
infrastructure_failed
integrity_failed
interrupted
```

AFIO owns the AdventureFinder interpretation of those generic outcomes.

### Status meaning

**`completed`** — every planned job has exactly one terminal `completed` result.

**`workload_failed`** — every planned job reached a terminal generic result, but
at least one workload process failed.

**`infrastructure_failed`** — one or more jobs were not started because RPOF could
not safely continue assignment.

**`integrity_failed`** — dispatcher accounting is not trustworthy, for example
duplicate/unknown result identity or nonterminal result accounting.

**`interrupted`** — the dispatcher was interrupted. New claims stop, active
process groups are terminated safely, and possibly-started work is not silently
retried.

### Per-job summary

The AFIO-facing per-job summary contains generic execution facts only:

- `job_id`;
- logical `worker_index`;
- start/finish timestamps;
- elapsed seconds;
- `status` (`completed` or `failed`);
- process `exit_status`, when available;
- relative `stdout_path`;
- relative `stderr_path`; and
- optional generic `error`.

It does **not** expose physical RunPod pod IDs or provider mechanics.

## 8. Dispatch exit status

```text
0  summary status = completed
1  summary status = workload_failed, infrastructure_failed,
   integrity_failed, or interrupted
2  invalid invocation, unreadable request, unsupported contract version,
   or request-schema violation
```

When interruption is delivered as an operating-system signal, conventional
signal-derived process exit status (for example 130/143) is permitted. RPOF should
still persist `summary.json` with `status: "interrupted"` when it can do so safely.

AFIO must classify a completed invocation from `summary.json`, not by parsing
human stdout/stderr.

## 9. Resume behavior

Reusing an existing `EVIDENCE_DIR` means resume.

RPOF must validate that existing durable state matches the requested logical jobs
and dispatch mode before resuming.

Resume must:

- preserve completed terminal jobs;
- preserve failed terminal jobs unless AFIO explicitly issues a new campaign;
- never automatically retry a job recorded as possibly running/started;
- never duplicate a completed `job_id`;
- resume only work proven not to have started;
- fail closed on inconsistent or unsupported prior evidence.

AFIO creates a **new evidence directory / new dispatch identity** when it
intentionally wants a new inference attempt.

## 10. Affinity behavior

`group_by_affinity: false` is FIFO.

When `true`:

- equal affinity values are stably grouped;
- group order follows first appearance;
- FIFO order is preserved within each affinity group;
- missing affinity is one group;
- grouping does not create a global barrier between groups.

Affinity is an opaque scheduling hint. RPOF must not interpret `model:...` or any
other affinity convention semantically.

## 11. Concurrency and failure invariants

v0.1 preserves these proven invariants:

- one selected logical worker runs at most one active job at a time;
- M jobs on N workers works for M < N, M = N, and M > N;
- each logical job executes at most once unless AFIO explicitly creates a new
  attempt;
- a workload failure does not automatically quarantine infrastructure;
- an infrastructure failure may quarantine that logical worker and allow safe
  surviving workers to continue;
- completed evidence survives unrelated failures;
- RPOF never silently retries model inference;
- unsafe fleet/tunnel/routing changes stop new assignments;
- accounting anomalies cannot be reported as successful completion.

## 12. What is deliberately not in the v0.1 AFIO-facing interface

The following remain RPOF operator concerns and are **not** AFIO API calls:

```text
fleet create
fleet scale
fleet replace
fleet destroy
bootstrap / model pull
cache-reuse mutation
tunnel start/repair/stop
lease watchdog start/stop
provider inventory probing
provider billing internals
SSH setup / known_hosts management
persistent-volume management
physical pod identity
```

AFIO may tell an operator that capability check failed. It does not repair the
provider fleet through the v0.1 inter-repository interface.

A later interface version may add a declarative “ensure capability” operation only
if real usage demonstrates that the extra coupling is worth it.

## 13. Compatibility bridge requirements

During extraction, existing LME operator commands may remain as shims.

The bridge must translate:

```text
existing LME readiness intent
    -> capability-check request/result

existing LME generic jobs
    -> dispatch request

existing LME RunPod dispatch result
    <- dispatch summary/evidence
```

without changing frozen production manifests, scorer invocation semantics,
AdventureFinder failure interpretation, local-only execution, or existing
historical evidence.

The bridge may adapt old exit codes to the v0.1 interface. Existing user-facing
LME behavior should remain compatible while provider implementation moves.

## 14. Schema compatibility rule

For v0.1:

- producers must emit exactly the frozen `contract_version`;
- consumers reject unknown contract identifiers;
- required fields may not be removed or reinterpreted.

The supplied v0.1 JSON Schemas use `additionalProperties: false`, so adding fields
to these four frozen documents requires v0.2. This strictness is intentional
during the split.

## 15. Acceptance tests required before the bridge is considered implemented

All of these can and should be deterministic/fake/local.

### Capability check

- ready fleet + matching requirements -> exit 0, `ready=true`;
- missing/inactive fleet -> exit 1, `ready=false`;
- selected worker missing/inactive -> exit 1;
- model absent -> exit 1;
- pinned digest mismatch -> exit 1;
- context mismatch -> exit 1;
- GPU mismatch when requested -> exit 1;
- not fully GPU resident -> exit 1;
- unhealthy tunnel/Ollama endpoint -> exit 1;
- unsupported contract version -> exit 2;
- capability check performs no provider mutation.

### Dispatch

- M<N, M=N, M>N;
- one active job maximum per logical worker;
- stable affinity grouping behavior;
- exact-once 900-job/16-worker regression remains green;
- target fleet id mismatch fails before unsafe assignment;
- worker routing change quarantines/stops unsafe assignment;
- workload failure preserves independent jobs/evidence;
- infrastructure failure preserves completed evidence;
- duplicate/unknown/nonterminal accounting -> `integrity_failed`;
- resume preserves terminal jobs and does not retry possibly-started jobs;
- `INT`/`TERM` stops new claims and persists interrupted evidence;
- supplied env values are absent from durable generic evidence;
- RPOF can dispatch a non-AdventureFinder fake workload with the same interface.

### Independence

- AFIO local-only tests/run path work with no RPOF checkout;
- RPOF interface tests contain no Adventure IDs, AFAO dimensions, AMC versions,
  backlog contract types, or scorer-specific interpretation.

No paid RunPod invocation is required for this acceptance gate.

## 16. Freeze rule

Once this interface document and its four JSON Schemas are committed to
`adventure-finder` `main`, **AFIO ↔ RPOF interface v0.1 is frozen**.

Implementation may then begin against this boundary.

Changing the operation set, required CLI arguments, request/result meaning, job
envelope, status/exit semantics, resume semantics, exposed provider identity, or
dependency direction requires v0.2.

## 17. PASS gate for migration Step 3

Step 3, “Define the minimal inter-repo interface,” is complete when:

- [x] the AFIO-facing operation set is only capability check + generic dispatch;
- [x] fleet mutation is explicitly outside the v0.1 AFIO dependency;
- [x] the four versioned JSON documents have normative schemas;
- [x] logical worker indices require a positive integer (`minimum: 1`) and the
      inter-repo schema does not impose an architectural maximum;
- [x] dispatch has an explicit caller-supplied `--workdir`;
- [x] no AdventureFinder semantic field crosses into RPOF;
- [x] no physical RunPod identity crosses into AFIO;
- [x] generic status, exit, failure, resume, and evidence semantics are explicit;
- [x] deterministic acceptance criteria are explicit;
- [ ] this document and the four schemas are committed to clean
      `adventure-finder` `main` and pushed;
- [ ] `adventure-finder` repository-local tests pass after the interface-only
      change.

No RPOF repository creation or implementation-file movement should happen before
the final two items are satisfied.
