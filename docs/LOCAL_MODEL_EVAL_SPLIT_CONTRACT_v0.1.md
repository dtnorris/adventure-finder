# AdventureFinder Local Model Evaluation Split Contract v0.1

**Status:** FROZEN architectural contract once committed to `adventure-finder` `main`
**Scope:** split of the current `local-model-eval` repository into `af-inference-orchestrator` (AFIO) and `runpod-ollama-fleet` (RPOF)
**Owner of this contract:** `adventure-finder` workspace repository
**Contract path:** `docs/LOCAL_MODEL_EVAL_SPLIT_CONTRACT_v0.1.md`

## 1. Purpose

This document freezes the architectural ownership map and the first AFIO ↔ RPOF
boundary **before any implementation files are moved or extracted**.

The split is behavior-preserving. Its purpose is to separate two bounded contexts
that currently coexist inside `local-model-eval`:

- **AFIO — `af-inference-orchestrator`** owns why AdventureFinder inference work
  exists: experiments, qualification, production-scoring workload policy,
  scheduling intent, local execution, scorer invocation, result interpretation,
  reproducibility, and AdventureFinder evidence.
- **RPOF — `runpod-ollama-fleet`** owns how optional paid RunPod/Ollama compute is
  provisioned, made ready, kept safe, and used to execute opaque workloads.

This contract is an architecture/topology contract. It does **not** redefine AFAO,
AFPS, AFMRS, Adventure Boundary semantics, scoring rubrics, canonical catalog
state, source identity, or editorial acceptance.

## 2. Authority and versioning

The `adventure-finder` workspace may own this cross-repository contract because the
contract describes repository boundaries and coordination. It does not become a
second authority for implementation-specific or semantic facts.

Authority remains:

- `md-specification-files` — accepted AdventureFinder semantic specifications;
- `af-xlsx-data-sources/PROJECT_STATE.yml` — moving canonical AMC role state;
- `md-for-llm-book-content` — canonical private source corpus and source registry;
- each implementation repository — its code and repository-local tests.

### Freeze rule

Once this file is committed to `adventure-finder` `main`, **v0.1 is frozen**.

A change that alters ownership, required fields, failure semantics, compatibility
obligations, or the allowed direction of dependencies requires a new contract
version (for example `v0.2`). Typographical, formatting, or link-only corrections
may amend v0.1 only when they do not change an obligation.

The Git commit containing this file is the authoritative freeze point.

## 3. Frozen pre-split baseline

The contract was written against the measured pre-refactor freeze:

| Repository / artifact | Frozen identity |
| --- | --- |
| `adventure-finder` | `0479145b2382d89b89ac8b2f45cf8b3704580a48` |
| `local-model-eval` | `2e34ccfdf0a6e4f6de97ddea8c1876fe489ba839` |
| `af-cli-scoring-utility` | `9721354b1e80ac9dc34376f1d8bd14d014e59805` |
| Workspace cross-repo test | 7/7 current/default suites passed |
| `local-model-eval` local test | 234 runs, 1422 assertions, 0 failures, 0 errors, 3 skips |
| Legacy readiness-path inventory | 391 references to `af-cli-scoring-utility-readiness` |

The baseline evidence is external to the repositories and was SHA-256 sealed before
this contract was authored.

The split may change repository topology and test-suite counts. It must not
silently change scoring behavior merely to make the topology migration easier.

## 4. Target architecture

```text
canonical/scoring-ready AMC
        |
        v
af-cli-scoring-utility
(scoring semantics + one assessment execution)
        ^
        |
        | scorer invocation / scoring evidence
        |
af-inference-orchestrator (AFIO)
(why the work exists)
        |
        +--------------------> local Ollama
        |
        | versioned generic workload/capability contract
        v
runpod-ollama-fleet (RPOF)
(how optional paid remote compute exists)
        |
        v
remote Ollama
```

The initial split preserves the current control-plane model:

- AdventureFinder scorer code and source corpus remain local.
- RPOF may provision and expose remote Ollama endpoints.
- Generic workload processes execute from the control plane and receive an
  assigned Ollama endpoint.
- The initial split does **not** move the scorer or source corpus onto remote pods.

Whole-job remote execution is outside v0.1 unless a later contract version
explicitly introduces it.

## 5. Non-negotiable ownership rules

### 5.1 AFIO owns why the work exists

AFIO owns:

- experiment manifests and experiment expansion;
- model and dimension qualification;
- qualification plans, oracles, comparisons, and interpretation;
- AdventureFinder-specific production-backlog semantics;
- scoring-workload selection and scheduling intent;
- scorer invocation intent and configuration;
- local Ollama execution;
- AdventureFinder-specific failure classification and continuation policy;
- production pause/resume policy;
- workload/result semantics;
- reproducibility metadata about the AdventureFinder run;
- transformation of generic execution evidence into AdventureFinder evidence;
- operator workflows whose purpose is AdventureFinder inference, even when they
  use RPOF as an execution backend.

AFIO may know Adventure IDs, AFAO dimensions, AMC versions, scoring profiles,
production-backlog contract types, qualification expectations, and scorer paths.

### 5.2 RPOF owns how optional paid remote compute exists

RPOF owns:

- RunPod API interaction;
- provider credentials and provider request/response handling;
- cloud/GPU profiles;
- fleet namespaces and fleet state;
- fleet create, scale, replace, and destroy;
- logical worker identity and physical worker generations;
- per-pod lifecycle;
- Ollama process/bootstrap management;
- model cache population and cache reuse;
- model digest/context/GPU-residency capability verification;
- SSH setup and host-key handling;
- tunnels and endpoint health;
- provider readiness and provider provenance;
- runtime/spend leases and watchdog behavior;
- provider status and cost/rate accounting;
- generic N-worker dispatch;
- generic affinity/grouping;
- generic subprocess supervision;
- infrastructure quarantine and safe recovery;
- fail-closed provider/infrastructure behavior.

RPOF may know opaque workload IDs, command argv, environment keys/values supplied
for execution, model identifiers/digests, context requirements, GPU requirements,
worker counts, and generic safety ceilings.

### 5.3 RPOF must not know AdventureFinder semantics

RPOF must never require or interpret:

- Adventure IDs;
- adventure titles;
- AFAO dimensions or scores;
- AMC versions or catalog roles;
- AFPS or AFMRS;
- production-backlog contract types;
- qualification oracles or pass/fail expectations;
- AdventureFinder scoring profiles or rubrics;
- source-book identity or source-page boundaries;
- scorer-specific success semantics beyond generic process exit/evidence integrity;
- editorial acceptance state.

An opaque argv or environment value may happen to contain an AdventureFinder
string because AFIO supplied it to a workload. RPOF must treat it as opaque data,
not as a field it understands or validates.

### 5.4 AFIO must not know RunPod mechanics

After the compatibility bridge is complete, AFIO must not require or manipulate:

- RunPod REST endpoints;
- physical RunPod pod IDs;
- provider create/delete request semantics;
- SSH external ports;
- `known_hosts` paths or provider host-key mechanics;
- persistent-volume identifiers or provider storage lifecycle;
- replacement-pod mechanics or physical generations;
- lease-watchdog PIDs;
- provider billing-record internals.

AFIO may receive **opaque logical worker identity** and an accessible Ollama base
URL because those are execution capabilities, not provider mechanics.

## 6. Neighbor-repository boundaries

### 6.1 `af-cli-scoring-utility`

`af-cli-scoring-utility` remains authoritative for:

- scoring behavior;
- prompts and scoring profiles;
- AFAO interpretation;
- source resolution and canonical page extraction;
- scoring guardrails;
- deterministic scoring validation;
- one assessment execution and its native scoring evidence.

The scorer does not own experiment scheduling, distributed/parallel execution,
provider lifecycle, qualification continuation, or production-backlog policy.

AFIO invokes the scorer. RPOF never becomes the scorer's semantic owner.

### 6.2 `af-data-pipeline`

`af-data-pipeline` remains the deterministic boundary/review/AMC-mutation layer.

For new production inference, its orchestration boundary is AFIO, **never RPOF**.
RPOF is replaceable infrastructure beneath AFIO and must not become a data-pipeline
dependency.

Historical LME evidence readers remain supported where inexpensive; they are not
rewritten merely because repository topology changes.

### 6.3 `adventure-finder`

The workspace documents and tests cross-repository topology. It does not absorb
AFIO, RPOF, scorer, catalog, source-corpus, or scoring-semantic implementation.

## 7. Frozen ownership map for current `local-model-eval`

The following classifications are against the frozen
`local-model-eval@2e34ccfdf0a6e4f6de97ddea8c1876fe489ba839`.

A file may remain physically in `local-model-eval` temporarily while the
compatibility bridge exists. Classification states the **intended owner**, not the
first migration commit in which the file must move.

### 7.1 AFIO-owned library code

The following current components belong to AFIO:

```text
lib/adventure_ingest.rb
lib/adventure_ingest_verifier.rb
lib/batch_failure_policy.sh
lib/production_backlog_dispatch.rb
lib/production_backlog_runner_policy.rb
lib/production_backlog_runtime_contract.rb
lib/production_backlog_selector.rb
lib/production_failure_classifier.rb

lib/local_model_evaluation/config.rb
lib/local_model_evaluation/experiment.rb
lib/local_model_evaluation/job.rb
lib/local_model_evaluation/production_backlog_source_preflight.rb
lib/local_model_evaluation/qualification_plan.rb
lib/local_model_evaluation/qualification_runner.rb
lib/local_model_evaluation/reporter.rb
lib/local_model_evaluation/run_status.rb
lib/local_model_evaluation/runner.rb
lib/local_model_evaluation/scheduler.rb
lib/local_model_evaluation/terra_comparator.rb
lib/local_model_evaluation/worker.rb
lib/local_model_evaluation/worker_check.rb
```

The root `lib/local_model_evaluation.rb` remains an AFIO-side compatibility façade
during the migration. Its current RunPod `require` lines are migration seams, not
evidence that AFIO owns provider implementation.

### 7.2 RPOF-owned library code

The following current components belong to RPOF:

```text
lib/local_model_evaluation/bootstrap_store.rb
lib/local_model_evaluation/process_supervisor.rb
lib/local_model_evaluation/runpod_bootstrap.rb
lib/local_model_evaluation/runpod_client.rb
lib/local_model_evaluation/runpod_dispatcher.rb
lib/local_model_evaluation/runpod_fleet.rb
lib/local_model_evaluation/runpod_fleet_lifecycle.rb
lib/local_model_evaluation/runpod_fleet_namespace.rb
lib/local_model_evaluation/runpod_fleet_state.rb
lib/local_model_evaluation/runpod_lease.rb
lib/local_model_evaluation/runpod_status.rb
lib/local_model_evaluation/runpod_tunnels.rb
lib/local_model_evaluation/runpod_workers.rb
```

Tests whose subject is one of these provider-control-plane components move with
the implementation to RPOF, except where an AFIO compatibility test intentionally
tests the bridge.

### 7.3 Bridge/interface components

The current combined implementations below must be split at the boundary rather
than simply assigned wholesale:

```text
lib/local_model_evaluation/runpod_ready.rb
lib/local_model_evaluation/runpod_provenance.rb
bin/lme
```

The target split is:

- AFIO owns **requirements**: what models/capabilities a workload needs and how
  AdventureFinder interprets readiness/provenance.
- RPOF owns **capability verification**: whether the generic fleet/endpoints
  satisfy model, digest, context, GPU, tunnel, lease, and provider-state
  requirements.
- AFIO owns the public compatibility command surface `bin/lme` during migration.
  Provider subcommands behind that surface delegate through the versioned RPOF
  CLI/file contract.

### 7.4 AFIO-owned CLI/workflow families

These current operator workflows remain AFIO because their purpose is
AdventureFinder experiments, qualification, production scoring, or interpretation:

```text
bin/build-production-backlog
bin/classify-production-failure
bin/evaluate-production-backlog-ee
bin/lme-matcher-burst
bin/lme-production-backlog-remote
bin/lme-production-remote-job
bin/lme-qualify
bin/lme-qualify-gpu
bin/lme-worker-check
bin/preflight-production-backlog-sources
bin/prepare-discovery-horizontal
bin/prepare-production-backlog*
bin/production-backlog-dispatch
bin/production-backlog-policy
bin/verify-production-backlog*
run_production_backlog.sh
pause_production_backlog.sh
resume_production_backlog.sh
```

`lme-qualify-gpu`, matcher burst, and remote-production commands may call RPOF,
but orchestration intent and interpretation stay in AFIO.

Fixed historical batch helpers such as `ensure_batch009_runtime.sh` and
version/batch-specific preparation scripts remain AFIO/historical compatibility;
they do not move to RPOF merely because they once invoked remote inference.

### 7.5 RPOF-owned CLI families

The implementation behind these current commands belongs to RPOF:

```text
bin/lme-runpod-bootstrap
bin/lme-runpod-dispatch
bin/lme-runpod-lease
bin/lme-runpod-lifecycle
bin/lme-runpod-status
bin/lme-runpod-tunnels
```

During the bridge phase, same-named or `bin/lme runpod-*` commands may remain as
thin compatibility shims in LME/AFIO. The provider implementation itself must
have only one current owner.

### 7.6 Historical compatibility names

The initial split deliberately preserves or aliases where useful:

```text
local-model-eval
LocalModelEvaluation
bin/lme
LME_REPO
LME_*
lme-current-v1
lme-legacy-v1
lme_run_id
historical evidence paths
historical production manifests
```

These names are compatibility/provenance, not target architecture. Their eventual
retirement is a separate migration and must not be bundled into the extraction.

The frozen 391 references to `af-cli-scoring-utility-readiness` are likewise
historical/experiment provenance unless separately proven to be live operational
dependencies. They must not be mass-rewritten as part of the split.

## 8. AFIO ↔ RPOF dependency rule

The repository boundary is **CLI + versioned machine-readable files/output**.

Forbidden:

```text
AFIO require/import RPOF Ruby source
RPOF require/import AFIO Ruby source
shared private Ruby library used as the boundary
reaching into the sibling repo's lib/ tree
depending on sibling internal class names
```

Allowed:

```text
AFIO -> RPOF CLI
AFIO -> versioned JSON/request file -> RPOF
RPOF -> versioned JSON/evidence files -> AFIO
opaque workload subprocess argv/env
accessible Ollama endpoint returned as a generic capability
```

The first interface must remain intentionally small and reflect behavior already
proven in current LME. It is not permission to build a generic compute platform.

Unknown or incompatible contract/schema versions fail closed. No side may silently
reinterpret an unknown version.

## 9. Generic work request contract

A dispatch job contains only:

- `job_id` — stable unique job identity;
- `argv` — non-empty argv array, executed without a shell;
- `env` — string-to-string environment mapping;
- `affinity` — optional opaque affinity string.

No AdventureFinder-specific field may be added to this RPOF job envelope.

### 9.1 Identity

Within one dispatch:

- `job_id` values are unique;
- the same logical job retains the same `job_id` across deterministic resume;
- RPOF never manufactures an AdventureFinder identifier from job contents.

### 9.2 argv

RPOF treats argv as opaque.

RPOF may validate generic execution safety (non-empty strings, no NUL bytes, etc.)
but must not parse scorer/adventure/dimension semantics from argv.

Secrets must not be placed in argv because argv and generic evidence may be
persisted.

### 9.3 environment

RPOF may inject generic execution context such as:

- logical job identity;
- logical worker identity;
- assigned Ollama endpoint.

Environment **values supplied for workload execution must not be persisted** in
generic evidence. Recording environment variable names is allowed.

The current injected names `LME_JOB_ID`, `LME_WORKER_INDEX`, and
`LME_OLLAMA_URL` are compatibility names. v0.1 preserves their behavior where
needed but does not freeze them as permanent RPOF branding.

### 9.4 affinity

Affinity is optional and opaque.

RPOF may group or order work by equal affinity values to improve cache/model
locality. Affinity must not become a hidden AdventureFinder semantic field and
does not create a global barrier between affinity groups unless a future contract
explicitly says so.

## 10. Generic capability request contract

AFIO may express **what capability it needs**. RPOF decides how RunPod satisfies
that requirement.

The v0.1 capability vocabulary may include:

- target worker count;
- required Ollama model identifier(s);
- exact expected model digest(s);
- required context length;
- GPU profile / exact GPU type requirement;
- cache-reuse request or requirement;
- generic cloud-tier constraint;
- generic maximum fleet hourly rate;
- generic maximum aggregate managed hourly rate;
- generic runtime limit;
- generic spend limit.

The request must not contain AdventureFinder scoring semantics.

RPOF may return:

- an opaque fleet identity;
- opaque logical worker identities;
- an accessible Ollama URL for each ready logical worker;
- generic capability/readiness state;
- generic rate/lease/safety state;
- versioned generic provenance.

AFIO must not require physical pod IDs or provider-internal lifecycle state from
that response.

## 11. Generic execution evidence contract

RPOF owns durable generic execution evidence. At minimum the dispatch evidence
contains:

```text
manifest
summary
jobs/<job_id>/metadata
jobs/<job_id>/stdout
jobs/<job_id>/stderr
```

The exact serialized envelope must carry a version and may preserve the current
dispatcher `schema_version: 1` during extraction.

Per-job generic metadata may include:

- schema/contract version;
- `job_id`;
- logical worker identity;
- assigned Ollama URL;
- argv;
- environment variable names, never supplied environment values;
- start time;
- finish time;
- elapsed duration;
- generic job status;
- process exit status;
- stdout/stderr artifact paths;
- generic execution error text when applicable.

The summary/manifest may include:

- fleet/logical-worker identity;
- selected workers;
- job identities;
- affinity/grouping mode;
- start/finish times;
- completed/failed/interrupted/integrity counts;
- generic infrastructure failures;
- resume-relevant state.

RPOF does not decide whether a process result is a valid AFAO assessment, an
expected model failure, a scoring regression, or a production-acceptance outcome.
AFIO owns those interpretations.

## 12. Execution and failure semantics

The following behavior is part of the v0.1 split contract because it is already
proven by the current dispatcher and must survive extraction.

### 12.1 Concurrency

- One logical worker runs at most one active workload job at a time.
- M jobs on N workers must work for M < N, M = N, and M > N.
- Adding workers changes concurrency, not the number of logical jobs.

### 12.2 Workload failure

A workload process exiting nonzero is a **generic job failure**, not automatically
an infrastructure failure.

RPOF:

- records the failure and durable evidence;
- preserves already-completed jobs;
- may continue independent jobs when infrastructure remains safe;
- does not infer AdventureFinder retry/continuation policy.

AFIO decides whether that generic failure is expected, sticky, retryable, fatal to
an experiment, or eligible for an explicit rerun.

### 12.3 Infrastructure failure

On worker/fleet/tunnel/provider-state failure, RPOF must fail closed for unsafe
assignments.

RPOF may quarantine a failed logical worker and continue on surviving safe workers.
It must not silently assign new work to a worker whose identity/routing/readiness
changed unexpectedly.

### 12.4 No silent inference retry

RPOF must not silently rerun a model/workload invocation.

Any retry that could repeat inference is explicit AFIO/operator policy and must be
visible in stable job/evidence identity. Infrastructure recovery must not be used
as an excuse to hide a second inference attempt.

### 12.5 Resume

Resume must:

- validate the prior manifest/contract before reuse;
- preserve terminal completed evidence;
- never duplicate a completed `job_id`;
- deterministically identify genuinely pending work;
- fail closed on conflicting or untrustworthy resume state.

### 12.6 Accounting integrity

Duplicate result identities, unknown job identities, impossible/nonterminal result
accounting, or equivalent dispatcher-accounting anomalies must not be reported as
success.

They produce a generic integrity failure and preserve diagnostic evidence.

### 12.7 Interruption

On operator/process interruption:

- stop new claims;
- terminate active workload process groups safely;
- persist an interrupted summary;
- do not silently replay a possibly-started job.

## 13. Readiness and provenance split

`RunpodReady` and `RunpodProvenance` currently combine both sides of the future
boundary.

They must be decomposed as follows.

### AFIO adapter owns

- translating experiment/model requirements into the generic capability request;
- deciding whether a missing capability blocks the AdventureFinder workload;
- attaching generic RPOF provenance to the AFIO run;
- interpreting whether the resulting run is eligible for comparison/production.

### RPOF verifier owns

- provider fleet-state validation;
- active logical-worker validation;
- tunnel/endpoint health;
- required-model presence;
- exact digest verification;
- context capability;
- GPU/profile capability;
- lease/spend/provider safety state;
- provider-generic provenance.

The bridge may temporarily preserve current command/output shapes, but the
implementation must converge on this ownership.

## 14. Local execution independence

AFIO must remain able to run a supported local Ollama workload **without RPOF
installed or present**.

Therefore:

- local worker configuration stays an AFIO concern;
- local qualification and local scorer execution do not route through RPOF;
- RPOF is an optional remote-compute backend, not AFIO's runtime foundation;
- failure or absence of RPOF must not break local-only workflows.

This is a hard acceptance criterion for the split.

## 15. Provider and cost safety

RPOF owns provider-side operational safety.

The extraction must preserve current fail-closed protections including, where
applicable:

- explicit paid-create confirmation;
- dry-run behavior;
- exact GPU selection/validation;
- fleet and aggregate hourly caps;
- runtime/spend leases;
- fleet identity checks;
- duplicate-pod protection;
- safe replacement/scaling;
- model digest/context/GPU-residency validation;
- tunnel/SSH identity checks;
- signal cleanup;
- deletion of only known managed provider resources;
- durable provider provenance.

A refactor must not weaken a safety check merely to simplify the new interface.

No paid RunPod resource is required to prove the split when deterministic/fake
coverage can establish the boundary.

If a real-provider smoke test is later proven necessary, use one worker on the
cheapest viable GPU, predeclare PASS/FAIL criteria and expected cost, and destroy
it immediately after the test.

## 16. Historical reproducibility and compatibility

The architecture migration must not rewrite history.

Historical evidence may legitimately continue to contain:

```text
local-model-eval
/Users/davidnorris/code/local-model-eval
LocalModelEvaluation
LME_REPO
LME_*
lme_run_id
lme-current-v1
lme-legacy-v1
af-cli-scoring-utility-readiness
```

Those values are provenance when they describe historical runs.

The initial migration:

- does not mass-rename historical evidence;
- does not rewrite old manifests merely for cosmetic consistency;
- preserves historical readers where inexpensive;
- introduces successor AFIO/RPOF producer names only for new evidence when the
  relevant later migration gate is reached.

Repository identity, CLI compatibility, Ruby namespace compatibility, environment
variable compatibility, and evidence-schema migration are separate concerns and
must not be collapsed into one rename.

## 17. Explicit non-goals for v0.1

The split is **not** permission to:

- build a generic multi-cloud compute abstraction;
- add Vast, Lambda, or other providers;
- redesign scorer prompts or scoring semantics;
- change AFAO;
- change AFPS/AFMRS;
- redesign production-backlog policy;
- change matcher semantics;
- redesign source resolution;
- migrate or normalize historical evidence;
- rename every `LME_*` identifier;
- rewrite all Ruby namespaces immediately;
- optimize unrelated test architecture;
- add hosted APIs or services;
- add public-product infrastructure;
- move the source corpus onto cloud workers;
- move whole scoring jobs onto RunPod workers;
- optimize runtime merely because files are being moved.

The goal is one clean architectural boundary.

## 18. Stop / rollback conditions

Pause the migration and revisit this contract rather than broadening scope if any
of the following becomes necessary:

1. RPOF's interface requires an Adventure ID, AFAO dimension, AMC version, scoring
   profile, backlog contract type, or other AdventureFinder semantic field.
2. AFIO must manipulate physical RunPod pod IDs or provider deletion mechanics
   after the bridge is complete.
3. AFIO local-only execution requires RPOF to be installed.
4. Historical evidence becomes unreadable without destructive rewrites.
5. Extraction requires coordinated implementation changes across most
   AdventureFinder repositories at once.
6. Scoring behavior materially changes during the topology move.
7. A shared Ruby implementation dependency is introduced between AFIO and RPOF.
8. Paid provider smoke tests become the primary debugging method.
9. Safety/cost guardrails must be weakened to make the split pass.
10. RPOF must inspect workload output using AdventureFinder-specific rules.

The split should reduce coupling. If completing it creates more coupling, stop and
revisit the boundary.

## 19. Contract PASS gate

This contract authorizes physical extraction only when all of the following are
true:

- [x] Pre-split repository/test baseline is frozen and healthy.
- [x] AFIO and RPOF ownership principles are explicit.
- [x] Every current production library/CLI/script family has one intended owner,
      bridge classification, or historical-compatibility classification.
- [x] `RunpodReady`, `RunpodProvenance`, and the mixed `bin/lme` surface have an
      explicit bridge decomposition.
- [x] AFIO ↔ RPOF uses CLI + versioned machine-readable files/output, not a shared
      Ruby library dependency.
- [x] Generic job fields are limited to stable job identity, argv, environment,
      and optional affinity.
- [x] Generic capability intent and provider mechanics are separated.
- [x] Generic evidence ownership and AdventureFinder interpretation ownership are
      separated.
- [x] Local AFIO execution is explicitly independent of RPOF.
- [x] Historical compatibility obligations are explicit.
- [x] Non-goals and stop conditions are explicit.
- [ ] This exact v0.1 file is committed to clean `adventure-finder` `main` and
      pushed.
- [ ] `adventure-finder` repository-local tests pass after the documentation-only
      commit.

The final two unchecked items are the mechanical freeze step. **No implementation
file move/extraction is authorized until both are satisfied.**

## 20. First action authorized after freeze

After the final two PASS items above are satisfied, the next authorized
implementation step is:

1. create `dtnorris/runpod-ollama-fleet` and
   `/Users/davidnorris/code/runpod-ollama-fleet`;
2. copy/extract the RPOF-owned provider-control-plane implementation and its tests;
3. make RPOF pass independently against fake/local boundaries;
4. keep `local-model-eval` named and operational;
5. add the compatibility bridge;
6. only then remove duplicated provider implementation from LME.

Do **not** rename `local-model-eval` to `af-inference-orchestrator` before the
provider extraction and compatibility bridge are green.

The minimum milestone that proves the architectural split succeeded is: RPOF owns
the provider implementation, LME/AFIO uses the frozen boundary, and LME/AFIO no
longer contains a hidden second RunPod implementation.
