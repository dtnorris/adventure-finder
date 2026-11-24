# Catalog ingest front door v0.1

`bin/af-catalog` is the single AdventureFinder-owned entry for a normal owned
digital-book ingest. The durable command family is:

```bash
bin/af-catalog start INPUT.pdf \
  --source-id "EXPLICIT SOURCE ID" \
  --edition "EXPLICIT EDITION" \
  --pagination-authority "EXPLICIT PAGINATION AUTHORITY" \
  --publisher "EXPLICIT PUBLISHER" \
  --base-catalog /path/to/exact-base.xlsx \
  --prepare-staged-scoring \
  --selected-by "OPERATOR" \
  --successor-version 7.5.2 \
  --canonical-destination /explicit/source/root/Book_LLM_Edition.md

bin/af-catalog resume OPERATION-UUID
bin/af-catalog resume OPERATION-UUID --approve-boundary-by "HUMAN REVIEWER"
bin/af-catalog resume OPERATION-UUID --approve-final-by "HUMAN REVIEWER"

bin/af-catalog bind-successor-version OPERATION-UUID \
  --successor-version 7.5.2 \
  --selected-by "OPERATOR"

bin/af-catalog successor-version-authority OPERATION-UUID --json
```

Start requires every semantic source declaration, an exact base catalog, and an
explicit scoring disposition. With `--prepare-staged-scoring`, the front door
resolves the pipeline's versioned staged-scoring input policy definition and
records its exact ID, version, byte digest and selected `afw-qualified-default`
value with the operator attribution. The selected definition is checked against
the supported pipeline policy contract before an operation is created. A missing
or changed definition fails closed. `--decline-staged-scoring` records an
attributed decline with a null inert policy. A start with neither disposition
still accepts all four explicit `--policy-definition`, `--policy-id`,
`--policy-version` and `--policy-values` inputs for compatibility. An
incomplete explicit group is refused; an explicit group combined with prepare
must match the resolved policy exactly. An explicit group combined with decline
is refused before an operation is bound. Deferred preparation rechecks the
immutable selected values against the exact supported selection before publishing
an affirmative intent. The selected policy is inert intent.
It does not authorize scoring,
inference, execution, retry, recovery, provider capacity, catalog mutation, commit, or
push. Boundaries, parentage, Adventure IDs, and approval remain explicitly unset.

The --canonical-destination option is optional for backward compatibility. When
present, it must be an explicit .md path beneath AF_SOURCE_ROOT; it enables the
deterministic source-only continuation described below. The front door stores only
its portable source-root-relative locator in the operation's resume context. It
never derives the destination from a source ID, filename, receipt, registry, or
prior shell state.

For continuous ingest, `--successor-version` binds the explicitly selected,
dotted numeric version at the initial interaction. It requires the canonical
destination. The existing `bind-successor-version` command remains available for
older operations and explicit recovery; the version is never inferred from the
base workbook or scoring policy.

The command generates and prints a lowercase UUIDv4 handle unless `--operation-id` is
supplied. The latter is useful for deliberate external identity assignment and exact
conflict tests; reusing a handle for different immutable input fails closed.

## Start behavior

Start hashes the PDF, catalog, and any selected policy definition, creates revision zero through
`IngestOperationStore`, and persists a versioned local resume context. The v0.1
context contains absolute runtime root mappings only. A v0.2 context additionally
binds the explicit canonical-destination locator that authorizes source progression.
The context is not part of operation document identity, and the operation document
retains only portable root-relative locators plus content digests and byte counts.

`AF_DATA_PIPELINE_ROOT` selects executable code independently of
`AF_DATA_PIPELINE_DATA_ROOT`, an existing absolute private state directory.
For the public cutover, set `AF_PIPELINE_EXPECTED_DATA_ROOT` in the installed
launcher to the approved absolute private store path. Keep that value fixed
when changing or testing the data selector. The front door requires that the
selected store match this path and that the public checkout have the origin
and clean Git revision pinned in `repos.yml`. It checks these requirements
before conversion or coordination writes, including during cold resume.
Historical recovery uses the original code and storage selectors with
`AF_PIPELINE_EXPECTED_DATA_ROOT` unset.
With private storage selected, the operation's `pipeline` locator resolves there;
`af-source-progress --pipeline-root` receives that state directory while executable
paths still resolve in the selected code checkout. Invalid, overlapping or symlinked
roots refuse without fallback. Replay retains the selected executable context;
changing an environment selector does not substitute another checkout.
Cold resume also requires the retained pipeline data binding: changing or
unsetting a private data selector refuses before continuation. Restore the
original matching selectors to resume; rollback selection applies to subsequent
legacy operations and does not relocate an existing operation.

AFDP-owned source audits, boundary approval/freeze artifacts, staged authority,
workload review/audit, release evidence, final packages and adoption
request/decision/result files belong under the private root. AdventureFinder's
operation revisions, editable editorial workspace, workload coordination,
local execution and final coordination decision retain front-door ownership.
AFW evidence, WLO accounting, canonical source and catalog outputs retain their
existing owners. Without the private selector, historical destinations remain
unchanged. Selecting storage does not move earlier artifacts or grant approval;
retain the same selectors when resuming an existing journey.

After publishing the handle, start invokes the existing public `convert-cached` PDF
entry. A reported durable receipt is bound as a converter-owned artifact in revision
one, then the existing IG-05C2 composer invokes pipeline's public
`af-ingest-next --operation-input ... --json` interface and renders its gate. The
composer never uses `--auto` and never executes a returned command.

When the v0.2 resume context binds a canonical destination, the same start call
continues through pipeline's public af-source-progress seam. Each child call may
perform only one validated PASS transition. AdventureFinder validates the versioned
result, exact operation/routing-input identity, output role and schema allowlist,
declared roots, byte counts, and SHA-256 digests before appending artifact references
to the existing operation. It then recomposes a fresh route from the new revision.
The driver permits only:

- accepted conversion receipt to source intake;
- source intake to source registration plus boundary dossier; and
- boundary dossier to an empty boundary-editorial review workspace.

It stops at BOUNDARY_EDITORIAL_REVIEW and prints a separate editable review copy
whose context and instructions must remain byte-identical to the bound originals.
It never enters candidate decisions, freeze/import, scoring preparation or execution,
inference, capacity, successor application, catalog adoption, or promotion.

A reviewable nonzero converter result still binds and routes a reported receipt, then
returns the converter status. A missing receipt leaves the valid revision-zero
operation at `NEEDS_FIRST_COMPONENT_ARTIFACT`; resume does not retry conversion. A
pipeline rejection is rendered with pipeline ownership and remains a failure.

## External AdventureFinder coordination state

`AF_STATE_ROOT` selects an **existing absolute mutable directory** for AF-owned
durable state. Create a private directory outside selected code and owner-data
roots, then export `AF_STATE_ROOT=/absolute/private/af-state` before starting.
It is independent of `AF_PROJECT_ROOT`, `AF_ADVENTURE_FINDER_ROOT` and
`AF_DATA_PIPELINE_DATA_ROOT`; those still select components, the front-door
contract locator and AFDP storage. An ordinary common parent of sibling roles
is not itself a selected role.

Unset selection preserves historical paths and v0.1/v0.2 context bytes and meaning.
Present empty, relative, traversal-bearing, missing, unwritable or symlinked roots
refuse without fallback. Containment in either direction with selected code or
owner data also refuses. Relevant AF destinations are checked before publication;
symlinks and conflicting directory records refuse. A populated namespace supports
compatible resume and need not be empty.

| State beneath the selected root | Public entry / responsibility |
| --- | --- |
| `output/ingest-operations/v0.1`, `output/ingest-contexts/v0.1` | `af-catalog start`, `resume` and operation lookup |
| `output/ingest-authorities/successor-version/v0.1`, `output/staged-scoring-intents/v0.1` | Explicit successor selection and staged-scoring choices |
| `output/ingest-editorial-workspaces/v0.1` | Editable human review copy; bound originals remain owner artifacts |
| `output/ingest-boundary-continuations/v0.1` | AF operation/authorization projections; AFDP approval/freeze retain their existing destination |
| `output/staged-workload-preparations/v0.1` | Preparation inputs, authority-store locator and frozen workload references |
| `output/ingest-releases/v0.1` | AF-composed release/package inputs; AFDP review/release/packages retain their existing destination |
| `output/local-ingest-executions/v0.1` | Local execution intent, coordinator phase/lock, capability inputs and worker-source configuration |
| `operations/final-promotions` | AF final coordination decisions; AFDP adoption request/decision/result retain their existing destination |
| `output/local-capability-requests`, `output/worker-sources` | `af-local bootstrap` and `af-batch` generated coordination inputs |

Read-only capability planning consumes preparation in the selected namespace.
`af-review` still delegates AFW evidence and AFDP review/audit artifacts to their
owners. WLO workdir/output/consumer identities, LOW state, AFW workload/evidence,
converter receipts/builds, canonical sources, catalog roles and telemetry/test
timing output are not relocated. WLO output historically nested under a checkout
still requires independent retention. No mid-execution migration is authorized.

External operations write context v0.3 with the original state path and directory
device/inode binding, unchanged runtime roots and optional source-progression
locator. Operation v0.1 revisions and independent authorizations keep their formats,
IDs and hashes. Lookup uses only the selected namespace. Copied contexts, changed
selectors, replaced state directories, conflicting retained owner/code selectors,
unsupported context versions and incompatible histories refuse before continuation.
Restore the original configuration to resume. There is no search, import, approval
regeneration or relocation command. Revision zero without its separately published
context is an explicit recovery boundary; starting again with its ID does not
recreate context. Physical namespace binding is not a new peer-library identity rule.

For same-path code replacement, stop all writers and retain the entire external
namespace: contexts, every revision, authorizations, intents, editable decisions,
preparations, capability inputs and final coordination decisions. Also retain every
bound owner artifact: original input/policy definitions, converter receipt/build,
AFDP data/approval/freeze/release/adoption artifacts, source registry/canonical files,
all catalog roles and historical project-state evidence, AFW workload/selection/
build/evidence, WLO execution/attempt/accounting and LOW state. Preserve selectors
and source identities separately from backups.

Replace the stopped front door **at the identical absolute code path with identical
selected code**, materializing only code files. Do not restore checkout output,
contexts or approvals into the replacement. From another CWD, invoke its absolute
`bin/af-catalog resume OPERATION-UUID` with original selectors. The declared
converter-fake/real-AFDP fixture exercises this at
`NEEDS_CANONICAL_MARKDOWN_PLACEMENT`; it does not establish new-path relocation,
code-upgrade compatibility, empty-library initialization or full-system recovery.
Restoring files into a new state directory changes its identity and needs explicit
recovery outside this interface; a backup alone does not prove resume.

## Resume behavior

Ordinary resume accepts only the handle. It reloads the versioned root context, validates the
complete append-only operation history and every bound byte sequence, and recomputes
the current gate through `IngestOperationRouting`. For a v0.2 source-progression
context it resumes the same source-only loop, reusing exact compatible component
outputs and appending only missing compatible operation references. It requires no
prior shell history or repeated input, catalog, component, or artifact paths.
When a staged-scoring decision exists, resume also revalidates its public decision
and frozen policy binding against the current definition; changed or missing
authority stops rather than substituting a later policy.

An unknown handle, malformed context, corrupt operation, missing bound artifact,
changed bytes, incompatible version, unsafe locator, or component contract conflict
fails closed with the existing stable diagnostic. Root mappings are coordination
metadata, not semantic identity. Historical readers retain their meaning; external
v0.3 contexts additionally require the original physical namespace binding. No
relocation/repair interface is supplied; resume never searches by filename or
silently substitutes content.

`AF_PROJECT_ROOT` remains the component root and `AF_ADVENTURE_FINDER_ROOT` remains the
detached front-door root. Existing `AF_PDF_CONVERTER_ROOT` and
`AF_DATA_PIPELINE_ROOT` overrides are preserved. `AF_SOURCE_ROOT` may explicitly
select the source root used by read-only routing. Paths with spaces and symlinked root
parents are supported through content validation and real-path containment.

Missing, changed, partial, malformed, wrong-identity, or wrong-schema progression
outputs stop immediately. A zero child exit is not success unless the expected
versioned result and output bytes validate. Page/OCR, source identity, registry,
catalog-base, and source-QA gates are rendered without bypass. After an editorial
context and decisions ledger are bound, ordinary resume **before boundary approval**
stops at that same review workspace without redoing source progression. This is
not the terminal gate for an operation whose boundary review is approved.

After the human completes the ledger and reviews it through pipeline's public
editorial interface, `resume --approve-boundary-by NAME` attests that exact review.
The front door validates the complete ledger, calls pipeline's public `approve`,
`freeze-approved`, `validate-approved-freeze`, and `boundary-freeze-stage`
commands, and retains their exact approval, freeze, operation projection, successor
authority, and staging receipt. Pipeline owns every validation, allocation, and
workbook change. After staging verifies the live manifest, the front door retains
its exact bytes as `HISTORICAL_PROJECT_STATE_OPERATION-UUID.yml` beside the role
workbooks, as required by the pipeline's historical-state resolver. This immutable
evidence copy changes no shared role; conflicting or symlinked copies are refused.
Later workload/release validation uses this retained locator separately from the
live manifest. An older frozen operation without retained evidence requires
explicit recovery; resume does not replace its historical binding.
Repeating the same approval and inputs reuses exact bytes; changed
inputs fail closed. The front door then requests AFW qualified workload preparation
and starts the existing local coordinator only for a `PREPARED` result. A verified
zero-record freeze reports `NO_SUCCESSOR_NEEDED` and does not start work.

`AF_DATA_PIPELINE_DATA_ROOT` selects the existing absolute private AFDP directory
for `output/staged-scoring-authority/v0.1`. Preparation retains an immutable
`authority-store.json` locator beside its inputs; AFDP alone issues and validates
the authority, publication proof and operation lock there. AFW and release
continuation consume that same store. Restart validates existing authority and
never reissues missing approval. Changed stores or missing/corrupt publications
fail closed; selecting a root does not migrate historical authority. Unset keeps
the checkout store. Older preparations without a locator may validate only in
that original layout, with their original owner evidence still available.
Review/release outputs and ingest-operation storage keep their existing paths;
in private mode AFDP also requires its review/release destinations beneath the
selected root. An incompatible layout refuses rather than relocating artifacts.

On terminal WLO completion, the front door verifies the exact frozen plan and
asks AFW's public binder and manifest publisher to account for its whole case
denominator. It asks pipeline's public workload review, standing bulk release,
and final package commands to validate the resulting evidence and prepare the
reviewed workbook. For an AFW qualified workload, the standing release uses
the pipeline's v0.2 input contract with the exact selection locator, AFW and
scorer roots, and generated workload directory; replay retains these same
bindings. The configured versioned standing directive and owner
selection remain pipeline-owned authority; the front door supplies no score
decisions. Incomplete execution, missing AFW receipts, changed inputs, or a
blocked package stop before final approval. A later plain `resume` retries
deterministic handoffs using the retained boundary approval and local intent;
it never reinterprets a failed WLO execution as complete.

Once the package is ready, `resume --approve-final-by NAME` displays the exact
pipeline-validated package and prompts for APPROVE or DECLINE. Only an explicit
APPROVE enters the existing pipeline adoption transaction. A package with a
stale catalog HEAD or changed reviewed bytes is refused. A repeat invocation
routes an existing operation-bound package directly to final promotion, without
rebuilding a workload or reapplying standing scores. It uses IG-19D-3's owner
validators and retained decision rather than minting a new
approval. `AF_AFW_ROOT`, `WLO_REPO_ROOT`, and the established component-root
overrides remain supported.

Optional frontier supplementation remains a separately requested component-tool
handoff at final review. The front door does not create its request, check installed
producer compatibility, or route that branch from `resume`. Use AFDP's
[Optional frontier producer v0.2](https://github.com/dtnorris/af-data-pipeline/blob/main/docs/FINAL_RELEASE_PACKAGE_V0.1.md#optional-frontier-producer-v02)
contract: the operator supplies the exact displayed absolute package-input and
package paths, an explicit frozen rubric (`id`, absolute `path`, `sha256`, `bytes`),
and a successor version newer than the original staged version bound by the
release manifest's `lineage.staged_amc.filename`. No rubric or version is inferred.
Leave original promotion unapproved when requesting that branch. After the
component's prepare/apply (or decline) and verify operations, prepare a new final
package from its public `RESULT_DIR/package-inputs.json`, then pass those inputs
and that package to `af-catalog final-promotion`. An absent/incompatible producer
or structured `BLOCKED` result grants no supplementation authority. Derived
values retain `frontier_manual` attribution and require a new exact final approval;
decline retains the original candidate and validated terminal gaps. Supplements
cannot chain. Original-candidate promotion remains available under its validated
terminal-gap authority without an additional mandatory decision.

## Successor-version authority

`bind-successor-version` validates the existing operation and its frozen bytes, then
records one explicit AdventureFinder-owned successor-version authorization. It
validates dot-separated numeric syntax but does not infer or enforce an increment
policy. Exact replay is idempotent; a conflicting version or selector fails closed.
The command does not call the converter, pipeline, boundary application, scoring,
inference, a provider, catalog adoption, or Git.

`successor-version-authority --json` emits the validated public projection for a later
pipeline-owned IG-09C consumer. It does not expose or require knowledge of the private
authority store layout. See
[`SUCCESSOR_VERSION_AUTHORIZATION_V0.1.md`](SUCCESSOR_VERSION_AUTHORIZATION_V0.1.md)
for the frozen provenance and verification rules. This authority is not a policy
value and does not change the existing resume route.

## Existing PDF compatibility

The historical invocation remains supported unchanged:

```bash
bin/af-catalog INPUT.pdf
```

It calls `convert-cached` and routes the reported receipt directly, preserving its
existing output and exit behavior. It does not create a durable ingest operation. New
durable work should use `start`; retained scripts may continue using the PDF form until
they deliberately adopt operation handles.
