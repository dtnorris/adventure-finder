# Offline operator acceptance

`bin/af-operator-acceptance` is the FO-03 acceptance entrypoint. Every selected
scenario runs with provider credentials removed and the injected TCP, UDP, socket,
and HTTP guard from `test/support/offline_network_guard.rb`. Scenario state is kept in
temporary directories. The harness neither starts Ollama nor makes inference or cloud
provider calls.

Run the complete surface or the coherent lifecycle alone:

```bash
bin/af-operator-acceptance
bin/af-operator-acceptance --only local-multi-model
bin/af-operator-acceptance --only operator-lifecycle
bin/af-operator-acceptance --only batch-front-door
bin/af-operator-acceptance --only audited-recovery
bin/af-operator-acceptance --only ig19b-source-exceptions
bin/af-operator-acceptance --only ig19b-boundary-exceptions
bin/af-operator-acceptance --only ig19c-execution-exceptions
bin/af-operator-acceptance --only ig19c-evidence-review-exceptions
```

## Automatic local multi-model proof

`local-multi-model` exercises the [local execution contract](LOCAL_INGEST_EXECUTION_V0.1.md)
through the IG-15C1 coordinator, LOW's public CLI with injected observer/client/hardware
components, and WLO's public CLI and real subprocess executor. Its synthetic frozen
plan is checked against AFW's producer-side v0.3 conformance fixture. No scoring,
model-quality, owned-book, or provider payload participates. FIFO payload barriers
hold attempts until public WLO demand observes them; a nonblocking payload lock
checks one-worker exclusivity. Runtime observations contain only one resident model
at a time. LOW alone retains capability evidence and publishes snapshots, including
legitimately retained capabilities; WLO alone retains dispatch and attempts.

The scenario also runs the IG-15D interruption and recovery matrix. Fresh
coordinator processes stop before the first capability request, during LOW
establishment, after READY but before WLO launch, and after completed work but
before the next capability request. Each restart reuses the same operation,
plan, output and WLO consumer identity. The matrix additionally exercises a
public operator pause, foreground cancellation with an unrelated sentinel,
detached WLO owner loss, selected retry and a tripped breaker. Faults target
only fixture-owned processes; no LOW or WLO retained file is edited to produce
a recovery state.

| Checkpoint | Required public result | Explicit next action |
|---|---|---|
| Before the first capability request | No WLO execution exists; resume reconstructs the first LOW bootstrap. | `bin/af-catalog local-resume OPERATION` |
| During LOW establishment | No READY evidence is assumed from process exit or partial runtime mutation; resume re-observes and bootstraps. | `bin/af-catalog local-resume OPERATION` |
| READY before WLO launch | The retained intent and exact READY publication are reused; one WLO execution is launched. | `bin/af-catalog local-resume OPERATION` |
| WLO active | A second driver is refused or observes the public active owner; it never launches a duplicate execution. | Observe with `bin/af-catalog local-status OPERATION`. |
| Completed work before a capability change | Completed attempts remain byte-identical and at attempt 1; current LOW generation/readiness determines the next transition. | `bin/af-catalog local-resume OPERATION` |
| Intentional operator pause | A zero exit and `paused` report remain `OPERATOR_PAUSE`; ordinary resume does not clear it. | After review, `bin/af-catalog local-resume OPERATION --continue-operator-pause`. |
| Foreground SIGINT/SIGTERM | WLO retains interrupted evidence and cancels only its process groups. Ordinary resume remains blocked. | Inspect WLO recovery evidence, then select exact jobs with `bin/wlo retry-failed PLAN --workdir WORKDIR --output OUTPUT --job JOB --reason REASON`. |
| One failed or interrupted job | Retry authorization archives the prior attempt and queues only the selected job; it does not execute it. | Run the reviewed `retry-failed` command, then explicitly continue the paused local execution. |
| Circuit breaker | Retry without `--acknowledge-circuit-breaker` is rejected without mutation. | A separately authorized retry must add `--acknowledge-circuit-breaker`; ordinary local resume never supplies it. |
| Detached WLO manager loss | Running attempts are reported as orphaned/uncertain; neither the coordinator nor a zero exit claims cleanup. | Inspect public WLO status/recovery evidence and resolve the WLO-owned recovery gate before any retry. |
| Changed operation authority, plan, sequence, request or output locator | Reuse fails with `STALE_LOCAL_EXECUTION`; no replacement workload or output is invented. | Return to the bound preparation; create a separately authorized operation only if the underlying intent truly changed. |

The scenario emits a JSON evidence line binding the operation, plan, sequence,
consumer, safe transition observations, LOW registry hashes/revisions, and all
successful attempts. Disposable artifacts are inspected read-only and removed.
Missing component seams fail harness validation rather than passing via skipped
tests. Use `--root` for the component workspace or `LOW_REPO_ROOT`, `WLO_REPO_ROOT`,
and `AF_AFW_SOURCE_ROOT` for exact read-only source checkouts. Existing front-door
and project-root overrides retain their ordinary meanings. This is executable
offline evidence for the linked contract, not new execution or retry authority.

## Coherent lifecycle replay

`OperatorLifecycleTest#test_offline_operator_lifecycle_from_context_to_verified_teardown`
performs one ordered replay:

1. Resolve the checked-in production-style batch and fleet registrations beneath a
   temporary `AF_PROJECT_ROOT` with the FO-01 portable context resolver.
2. Create a WLO v0.3 plan with two pools and two fake jobs. WLO starts with no workers
   and retains both jobs as pending without invoking an executor or provider fallback.
3. Start an RPOF campaign through `CampaignLifecycle` and
   `CampaignCapacityAdmission`; injected provider, guardian, process, and health fakes
   make every mutation local and deterministic.
4. Publish a new registry revision with bootstrap-incomplete `NOT_READY` workers, then
   a later revision with two compatible `READY` workers.
5. Let WLO consume only those READY workers. The fake command executor records the
   exact `WLO_WORKER_ENDPOINT`; WLO retains worker, generation, endpoint, capability,
   registry-revision, attempt, stdout, and exit evidence with no legacy provider
   request.
6. Read the WLO report and RPOF campaign status and prove those observer actions do
   not mutate their durable evidence.
7. Request campaign stop. The campaign remains `TEARDOWN_REQUIRED`; a simulated
   provider probe failure remains retryable and cannot claim absence. A later guardian
   tick deletes the fake pods, verifies provider absence, and reaches `CLOSED` without
   changing completed WLO evidence.

## Acceptance coverage map

The methods below are the assertion sites, not merely suggestive filenames.

| ID | Acceptance case | Harness scenario and assertion evidence |
|---|---|---|
| HP-01 | Portable production-style context resolution | `production-context`: `ProductionContextTest#test_workspace_override_resolves_the_same_context_beneath_temporary_root`, plus lifecycle phase `portable context` |
| HP-02 | WLO starts with zero capacity and waits without provider fallback | `operator-lifecycle` phase `WLO waiting`; `wlo-ready-workers`: `DynamicLocalDispatchTest#test_no_workers_means_polling_without_provider_fallback` |
| HP-03 | RPOF admission publishes later READY capacity consumed by WLO | `operator-lifecycle` phases `campaign start`, `NOT_READY publication`, and `WLO completion` (which asserts registry revision 3 and exact bindings); `wlo-rpof-publication`: `Dw28LateCapacityIntegrationTest#test_capacity_published_after_start_launches_pending_job_without_resume` |
| HP-04 | WLO pause/resume owns workload dispatch, not paid capacity | `wlo-dynamic-cli`: `DynamicCliTest#test_detached_start_keeps_polling_after_parent_exit_and_resume_reuses_checkpoint`; `wlo-process-ownership`: `OperatorUxTest#test_detachment_duplicate_exclusion_pause_resume_and_retained_launch_evidence` |
| HP-05 | Status/observer paths are read-only and distinct from pause/teardown | lifecycle phase `read-only observers`; `process-ownership`: both `OperatorProcessOwnershipTest` methods; `rpof-campaign-lifecycle`: `CampaignLifecycleTest#test_status_exposes_guardian_limits_capacity_and_pending_liability` |
| HP-06 | Stop is a teardown request; closure requires verified provider absence | lifecycle phases `teardown requested`, `teardown retry`, and `verified close`; `rpof-teardown`: `RunpodBudgetGuardianTest#test_teardown_destroys_committed_and_pending_slots_then_closes_budget` |
| HP-07 | Foreground Ctrl-C cancels only WLO-owned child trees while pause drains | `wlo-foreground-cancellation`: `ForegroundCancellationTest`, including child/grandchild termination, unrelated-sentinel survival, TERM-to-KILL escalation, partial evidence, explicit retry, and pause/resume cases |
| HP-08 | Batch 39 front door verifies the frozen plan and delegates safe start/resume without remanifest, replay, recovery authorization, or provider mutation | `batch-front-door`: `BatchFrontDoorTest`, including first start, completed/failed/interrupted evidence preservation, pause/resume separation, breaker/halt refusal, duplicate-owner locking, direct foreground exec, unknown handle, and portable-root cases |
| HP-09 | Recovery preview, selected authorization, history, resume, and repair remain distinct and preserve prior attempts | `audited-recovery`: `RetryTest`, including exact selection, evidence hashes/archives, idempotency, dry-run, breaker boundary, and fail-closed repair; `batch-front-door`: FO-07 short-handle delegation tests |
| HP-10 | Local-only, remote-only and mixed registries preserve publisher namespaces, exact attempt bindings and source-scoped loss | `batch-front-door`: independent source selection and strict WLO configuration; `wlo-multi-source-registry`: `MultiSourceWorkerTest`, including same-named workers, independent checkpoints, immutable bindings and source-scoped disappearance/replacement |
| FP-01 | Missing/malformed dynamic source fails closed without legacy fallback | `wlo-dynamic-cli`: `DynamicCliTest#test_source_failure_and_malformed_registry_halt_without_legacy_fallback` |
| FP-02 | Incompatible or NOT_READY workers do not run jobs | lifecycle phase `NOT_READY publication`; `wlo-rpof-publication` waiting assertions; `rpof-worker-publication`: bootstrap/unhealthy/tunnel tests |
| FP-03 | Stale, replayed, changed, or future-dated registry data fails closed | `wlo-registry-failures`: `WorkerRegistryPollerTest#test_revision_rollback_fails_closed`, `#test_same_revision_with_changed_bytes_fails_closed`, `#test_expired_snapshot_fails_closed`, and `#test_future_dated_snapshot_still_fails_closed` |
| FP-04 | Job failure and circuit breaker preserve attempt evidence and stop dispatch | `wlo-ready-workers`: `DynamicLocalDispatchTest#test_heterogeneous_commands_and_all_results_stay_local_with_exact_evidence`; `wlo-process-ownership`: `OperatorUxTest#test_detached_failure_and_post_acknowledgement_error_are_recorded` |
| FP-05 | Provider/bootstrap/capability failures do not publish false READY state | `rpof-campaign-lifecycle`: partial and ambiguous start tests; `rpof-worker-publication`: bootstrap incomplete, missing capability, unhealthy, stale provider identity, and conflicting model evidence tests |
| FP-06 | Teardown failure remains retryable and cannot claim provider absence | lifecycle phase `teardown retry`; `rpof-teardown`: `RunpodBudgetGuardianTest#test_failed_provider_teardown_remains_in_progress_without_absence_claim` |
| FP-07 | Ctrl-C/help semantics do not conflate foreground cancellation, WLO pause, observation, or provider teardown | `wlo-foreground-cancellation`: all cancellation/pause contrasts; `process-ownership`: `OperatorProcessOwnershipTest#test_top_level_help_distinguishes_observation_work_and_teardown` and `#test_campaign_help_states_short_lived_cli_and_verified_teardown_rule`; `wlo-process-ownership`: `OperatorUxTest#test_start_output_says_detached_work_outlives_the_invoking_cli` |

## V2 source and boundary exception matrices

`ig19b-source-exceptions` groups the landed IG-07C public-driver acceptance
cases into one table-defined matrix. Each row records its input condition,
public gate, permitted and prohibited mutations, preserved evidence, and one
operator action. It includes the clean control, converter readiness and page
review, canonical-byte conflict, missing/invalid registry, identity/segment
conflict, zero-exit missing output, changed bound evidence, and explicit public
correction/resume.

`ig19b-boundary-exceptions` groups the pipeline's public editorial, freeze, and
operation-bound staging tests without copying its implementation or fixtures.
It distinguishes unreviewed emptiness from approved zero-record review, proves
approval invalidation for every bound input, rejects invalid parent/span/freeze
and version/destination conflicts, preserves identical approval/freeze replay,
and proves IDs appear only in a verified staged successor. The scenario never
runs scoring, inference, catalog adoption, Git persistence, or provider code.

## Standing-ingestion exception routing

`ig19c-execution-exceptions` composes the landed AFW qualification, LOW
generation-bound capability, WLO execution/recovery, and AdventureFinder local
coordination proofs. Its table records the exact public identities and owner next
action for the exclusive 100-page boundary, Levels handling, invalid units,
missing or stale READY evidence, zero compatible workers, operator pause, active
owners, interruption, selected retry, breaker acknowledgement, and restart drift.
It does not invoke inference, relax capability requirements, create remote
capacity, or grant recovery authority.

`ig19c-evidence-review-exceptions` composes AFW's authoritative-attempt and
complete-denominator evidence tests with pipeline review, standing-release, and
final-package tests. It proves that missing, ambiguous, superseded, changed, or
partial evidence remains visible; Levels siblings remain separate candidates;
human and source decisions retain precedence; advisory-only flags follow the
active standing policy; and hard invalidity fails closed. The current final
package contract requires exactly zero IG-16B acceptances because the separate
application and suspension/follow-up authority has not landed. Historical V1
mechanical counts remain a distinct category. Both matrices stop before final
promotion and use the component owners' public executable tests rather than
copying their state or implementation into AdventureFinder.

FO-08 adds `rpof-safety-gate` to the same hard-offline harness. Its
`CampaignSafetyGateTest` proves that a finite compute-liability report is emitted
before the first fake provider mutation; invalid cumulative/runtime bounds,
guardian arm/health/identity failures, expired durable deadlines, and excessive
projected liability fail before creation; pending ambiguous reservations remain
in the liability calculation; and billing output labels the cap as RunPod pod
compute only. The scenario runs with credentials removed and the same socket and
HTTP guard, so its expected provider/inference cost remains `$0`.

On complete success the summary is evidence that all listed tests ran behind the hard
network guard with fake-only provider access, zero inference calls, and zero paid
resources.
