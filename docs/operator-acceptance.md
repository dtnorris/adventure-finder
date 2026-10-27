# Offline operator acceptance

`bin/af-operator-acceptance` is the FO-03 acceptance entrypoint. Every selected
scenario runs with provider credentials removed and the injected TCP, UDP, socket,
and HTTP guard from `test/support/offline_network_guard.rb`. Scenario state is kept in
temporary directories. The harness neither starts Ollama nor makes inference or cloud
provider calls.

`bin/af-test --comprehensive` invokes this public entrypoint after component and
front-door suites. Both standalone and comprehensive operator acceptance execute
all 28 currently registered scenarios. Three front-door unit files
(`batch-front-door`, `local-capacity-bootstrap`, and `production-context`) are
also exercised by front-door rake; they are intentionally rerun under the
operator harness's credential-free, offline guard rather than marked `COVERED`
without independently verified prerequisite evidence. Acceptance counts remain
separate from component/front-door suite totals. The local execution and
operator lifecycle scenarios retain separate process execution and
bundle/environment contracts; component-file scenarios and exception matrices
also prove behavior under the operator harness environment. No standalone CLI
option may assert coverage by a different test run.

Run the complete surface or the coherent lifecycle alone:

```bash
bin/af-operator-acceptance
bin/af-operator-acceptance --only local-multi-model
bin/af-operator-acceptance --only operator-lifecycle
bin/af-operator-acceptance --only batch-front-door
bin/af-operator-acceptance --only batch-dynamic-sources
bin/af-operator-acceptance --only audited-recovery
bin/af-operator-acceptance --only ig19a-entry-contract
bin/af-operator-acceptance --only ig19b-source-exceptions
bin/af-operator-acceptance --only ig19b-boundary-exceptions
bin/af-operator-acceptance --only ig19c-execution-exceptions
bin/af-operator-acceptance --only ig19c-evidence-review-exceptions
bin/af-operator-acceptance --only final-promotion
bin/af-operator-acceptance --only ig19d-restart-promotion
bin/af-operator-acceptance --only ig19d-staleness
```

## Optional batch publishers

`batch-dynamic-sources` runs the real `bin/af-batch resume fo26-default` handoff
into real WLO with a newly registered disposable batch, no policy mapping, and
a separately hashed synthetic plan. Only
publisher output and scorer payloads are fakes. One continuous owner waits with
empty publishers, consumes later LOW and RPOF capacity, and continues through a
healthy publisher after idle source failure. Public status/progress observations
and exact immutable attempt bindings establish continuity. A wrong full digest
prevents dispatch before a corrected publication enables the same execution.
An equivalent explicit-required remote control blocks healthy local capacity
until a fresh empty remote snapshot establishes authority. These defaults and
overrides follow the [foreground configuration contract](batch-foreground.md).

The synthetic 192-job fixture preserves all four original pool requirements,
the initial 75 complete / 5 failed / 112 pending boundary, and the original 80
terminal jobs' bytes/history. Its final 187 complete / 5 failed / 0 pending state
is `workload_failed`, exit 2. This is offline scheduling/accounting evidence,
not production scoring or recovery acceptance. The original production plan
is read only and hash-checked; no real scorer or provider is invoked.

The scenario also loads actual AF-generated YAML with WLO's validator and
checks optional/required availability, fresh-snapshot retention and expiry,
invalid replacements, capability matching, fatal registry collision, active
worker loss and public execution safety refusals. Test-owned process teardown
includes timeout, interruption, assertion-failure and unrelated-sentinel checks.
Set `FO25_EVIDENCE_ROOT` to a disposable evidence directory to retain public
observations, publisher bytes, source YAML, logs and attempt artifacts. Failed
fixtures are retained at the printed paths. These tests complement the owner
scenarios; they do not replace the full offline coverage or acceptance gates.

## Durable restart and staleness proof

The independently selectable `ig19d-restart-promotion` scenario compares public
operation, source, approved-boundary, staged-successor and standing-release
observations with fresh processes launched from another working directory.
It checks exact bindings and completed-work counts, then uses the real
final-package and adoption CLIs through the front door. It does not substitute
a serialized package or mocked validator for that handoff. An owner refusal
remains a failed acceptance row and blocks downstream promotion rows.

`ig19d-staleness` supplements those checks with the landed owners' executable
concurrency, workload-restart, local execution and authority predicates. Scoring
reuse and promotion readiness remain separate. Synthetic producer setup and
component predicates do not constitute a continuous automatic ingest journey.
The existing [operation composition](INGEST_OPERATION_ROUTING_COMPOSITION_V0.1.md),
[workload preparation](STAGED_WORKLOAD_PREPARATION_V0.1.md) and
[local execution](LOCAL_INGEST_EXECUTION_V0.1.md) contracts remain authoritative;
IG-16B is exercised only as an unavailable-authority refusal, not enabled.

The IG-19 fixture qualification wrapper uses checkout-contained scratch by default:

```bash
export AF_PROJECT_ROOT=/path/to/adventure-finder-components
bundle exec ruby acceptance/ig19d_validation.rb fixture
bundle exec ruby acceptance/ig19d_validation.rb focused
bundle exec ruby acceptance/ig19d_validation.rb matrices
bundle exec ruby acceptance/ig19d_validation.rb adventure-finder
```

`IG19_SCRATCH_ROOT` may select another explicitly permitted disposable directory.
Focused fixture proofs support spaces. Unchanged default suites retain their
own path and process-isolation assumptions; report their failures separately.
The wrapper copies tracked component bytes and independent
Git metadata into its scratch workspace, removes provider credentials, and
propagates the existing offline guard. It does not clone shared object stores or
construct catalog history. Preserve the complete candidate before costly suites;
checkpoint registration and publication remain separate operator actions.

`test/fixtures/ig19/{standing,promotion}.{json,zip}` contain pre-existing synthetic
history. The loader pins descriptor SHA-256, archive bytes, contained regular
paths, native HEAD/tree/index/objects, and committed manifest/workbook bindings.
The standing input must also match the unchanged owner recipe byte for byte.
Cold fixture caches and fixed ZIP timestamps isolate scenario preparation.
The BUG-02C archive is independently pinned by its journey but has different
`0.0.1` inputs; it cannot replace the standing or promotion histories.

The continuous BUG-02C journey also accepts `--dual-root`:

```bash
TMPDIR=/absolute/disposable/scratch AF_PROJECT_ROOT=/path/to/prepared/components \
  bundle exec ruby acceptance/bug02c_continuous_journey.rb --dual-root
```

This variant copies allowlisted pipeline code into `code/af-pipeline`, uses
`af-pipeline-data` for AFDP state, and copies the public front door independently.
It provides no legacy pipeline alias. The existing source/PDF, catalog history,
synthetic standing policy and owner selection are reused. Converter IO, scorer
payloads/preflight and LOW observation/client responses are external fakes;
pipeline review/authority/release/adoption, AFW selection/evidence and WLO
execution/accounting remain real. It proves deterministic offline mechanics,
not conversion quality, inference quality, real editorial authority or publication.
Children remove provider credentials and load the existing offline network guard.
Run only in qualified disposable roots, including temporary/cache directories.

The retained root contains `root-map.json`, byte/mode inventories, per-process
executable/library provenance and binary stdout/stderr with invocation metadata.
Independent missing/tampered evidence/authority, stale bindings, unsafe roots,
escaped destinations and absent/declined final approval controls must refuse
without adoption. Decline evidence is retained before restoring fixture authority
for the independent positive. The positive retains the original 11-job accounting,
exact reviewed candidate, independent project-state roles and cold replay before
and after promotion. All three real catalog consumers run against the unchanged
catalog-owned oracle. Omit `--dual-root` for the ordinary-layout regression.
These focused proofs do not replace checkpoint registration or required default,
operator, restart/staleness and affected owner gates.

Fixture construction is a separate, explicitly authorized phase. The retained
`acceptance/build_ig19_git_fixtures.rb` records its recipe hashes and construction
provenance; normal qualification never invokes it. Its historic builder hash in
the descriptors identifies the original construction bytes. Rebuilding requires
separate authority and must use a new absent output directory without replacing
reviewed artifacts or rebinding their provenance.

The bounded public proof starts after fixture extraction and qualification.
Real package validation, adoption preparation, explicit promotion and cold replay
retain native Git reads. Complete metadata inventories (directories and all file
paths/hashes, including additions/deletions) are compared around each public
child; package preparation/validation and final state receive the same check.
`GIT_OPTIONAL_LOCKS=0` prevents optional index refresh. Native Git trace events
record explicit commands. Application outputs, promoted workbook and
`PROJECT_STATE.yml` changes remain allowed by their existing assertions.
These observations establish endpoint nonmutation. They do not prevent or detect
all transient write-then-restore activity or contain hostile descendants.

The existing disposable-Git helper remains a narrow Ruby setup check, not a
universal Git interceptor. Unchanged owner/default test suites may construct
ordinary disposable Git histories during their setup. Those suites are separate
regression gates and are never claimed mutation-free. No component test is
rewritten to suppress its setup. Default coverage, runtime, benchmark, lint and
dependency tasks remain unchanged. Logs survive under the printed scratch paths;
failed scenario roots are retained for diagnosis. This qualification is not the
final IG-19E journey verdict or re-entry.

## IG-19A public entry proof

`ig19a-entry-contract` runs the public `af-catalog start` CLI against a
disposable synthetic PDF and valid XLSX catalog. The existing IG-07C fixture
supplies the supported fake converter IO; the scenario uses the pipeline's
real read-only `af-ingest-next` routing command and AdventureFinder's durable
operation store. It selects an explicit staged-scoring decline, so no policy
definition, ID, version or JSON values are supplied at admission. Assertions
cover the source and catalog byte bindings, attribution, conversion receipt,
decline decision, exactly one operation, and two fresh-process resumes that
leave durable evidence unchanged. Missing choices, missing policy authority,
invalid source or catalog paths and conflicting choices fail before admission.
The scenario needs the af-data-pipeline checkout and bundle, but no remote
capacity component.

Its successful gate is `NEEDS_CANONICAL_MARKDOWN_PLACEMENT`. This proves entry,
conversion handoff and restart/replay only; it does not approve a boundary,
prepare or execute scoring, apply standing acceptance, or promote a catalog.
The continuous three-decision V2 journey remains a separate proof. The
[staged-workload procedure](STAGED_WORKLOAD_PREPARATION_V0.1.md) retains its
explicit path-based preparation and local-start authority.

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

## Final promotion matrix

`final-promotion` is the IG-18C executable composition proof. It runs the
AdventureFinder review and persistence handoff against the pipeline's public
package, adoption, catalog-transaction, and `ProjectState` interfaces. The
clean fixture uses standing-directive acceptance with zero individual-human and
zero IG-16B-machine acceptances; the optional frontier cases remain separate.

The matrix also executes the pipeline owner's landed refusal cases for changed
candidate, package, referenced evidence, manifest, catalog role, and repository
HEAD; incompatible lineage and a scoring-safe-but-promotion-unsafe advanced
catalog; decline and interrupted import; destination collision; and identical
replay. The composed success case snapshots catalog HEAD, refs, index, preserved
roles, existing workbooks, and an unrelated dirty file. Promotion leaves Git
state untouched, prints only scoped workflow-owned persistence paths, and a
second invocation reports `ALREADY_PROMOTED` without replacing the durable
`PROMOTED` result or mutating the catalog again. All repositories and
workbooks are disposable synthetic fixtures.
