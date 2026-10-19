# AdventureFinder Batch 039b — Live Dynamic-Capacity Operations

**Date:** October 19, 2026  
**Classification:** Observed live operational acceptance of dynamic-capacity controls; **not** complete Batch 039b acceptance or proof of paid-resource teardown.

## Concise milestone statement

On October 19, 2026, AdventureFinder's existing WLO, LOW, RPOF, and AFW interfaces supported live changes to Batch 039b's inference capacity without modifying repository code, rewriting the frozen plan, manually editing execution state, or restarting the running workload. The operator brought bounded RunPod A40 Qwen35 capacity online, admitted and gracefully drained the Mac's local worker, replaced that worker's advertised Qwen35 capability with independently verified Qwen27 and GPT-OSS capabilities, and re-offered it while the A40 continued Qwen35 scoring. WLO observed both workers executing compatible jobs concurrently and later acknowledged a fully drained remote source. This establishes a successful **live operational acceptance of dynamic-capacity management** within the demonstrated scope, rather than acceptance of the entire scoring batch.

## What the live journey demonstrated

- **Late capacity and continuity:** A bounded RPOF A40 became READY and contributed to the pre-existing Batch 039b WLO execution; no workload restart or new execution was required.
- **Operator consent and graceful withdrawal:** WLO's `source-offer`, `source-adopt`, `source-drain`, and `source-status` were exercised against optional local and remote sources. Source withdrawal blocked new assignments while existing jobs could finish.
- **Exact local model qualification:** Following a deliberate Ollama.app restart, an already-installed Qwen27 model received the exact plan-required local tag (`ollama cp`, no model download). LOW `bootstrap` verified exact digest, 131072-token context, and full GPU residency for `qwen3.6:27b` and `gpt-oss:20b`.
- **Selective capability publication:** LOW then published those two models, *not* Qwen35. WLO matched the Mac to GPT-OSS and the remote A40 to Qwen35; the dashboard showed two running jobs simultaneously. Qwen27 correctly showed a compatible but busy worker rather than a second active inference job.
- **Safe remote withdrawal:** WLO reported `remote` source `effective: true`, `active_attempt_count: 0`, and `drain_result: fully_drained` after the last A40-assigned scoring attempt finished.

## Boundaries and unresolved acceptance

- The live observations establish scheduling, consent, exact capability qualification, and graceful source-drain behavior; **they do not establish that all 192 Batch 039b jobs completed successfully**.
- At the last relevant progress observation, a Qwen35 job was still marked failed (`f1`); its diagnosis and any authorized recovery are separate.
- A **successful RPOF campaign stop and provider-absence verification were not shown** in the captured conversation. Paid teardown remains **NOT VERIFIED**, even though WLO's remote source was fully drained.
- Earlier local `drain_result: uncertain` reflected conservative historical in-doubt evidence; the operator used additional checks before switching local Ollama. This evidence must not be erased or treated as a completed historical reconciliation.
- The operator used supported manual steps (Ollama.app restart and local model alias). The experience was **no repository hacks**, not zero manual intervention.

## Evidence references (local, authoritative; do not copy secrets)

- **Frozen plan:** `af-workloads-production/workloads/production-batch-039b-20261017/execution-plan.json`
- **WLO retained execution:** `workload-orchestrator-production/output/production-batch-039b-20261017/` — exact attempts, source offers/acknowledgments, job status, and publisher checkpoints.
- **RPOF production state:** `runpod-ollama-fleet-production/output/runpod-fleets/` — bound campaign and guardian/budget/provider status; verify `CLOSED` and provider absence separately.
- **LOW capability evidence:** local LOW `workers --json` publication and current-generation evidence for Qwen27 and GPT-OSS.

These are root-relative references beneath the operator's AdventureFinder component workspace, **not** exported copies of provider credentials or a claimed immutable evidence archive. For stronger auditability, preserve sanitized, timestamped public CLI status outputs with the actual execution and campaign identity hashes when collecting a final closeout.

## Recommended preservation

**Canonical narrative:** Commit this note (after operator review and separate Git authorization) in the `dtnorris/adventure-finder` repository at `docs/field-notes/2026-10-19-batch-039b-dynamic-capacity.md`. This is a proposed new documentation path, not an assertion that it already exists.

**Concise milestone/index:** Add the milestone statement, or a two-sentence version of it, to `adventure-finder/README.md` under **Historical milestones**, linking to that field note. This is the single discoverable entry point; avoid duplicating the long narrative across component repositories.

**Optional cross-reference:** Add a short pointer from `docs/operator-acceptance.md` with an explicit **live observation, not an offline harness result** label. Keep operational source-of-truth and troubleshooting detail in WLO/LOW/RPOF's existing operator documents.

No real repositories or lifecycle states were changed by preparing this export.
