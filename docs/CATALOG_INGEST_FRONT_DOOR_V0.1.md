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
metadata, not semantic identity: after an intentional relocation, they must be
explicitly repaired and the unchanged bound bytes revalidated; resume never searches
by filename or silently substitutes content.

`AF_PROJECT_ROOT` remains the component root and `AF_ADVENTURE_FINDER_ROOT` remains the
detached front-door root. Existing `AF_PDF_CONVERTER_ROOT` and
`AF_DATA_PIPELINE_ROOT` overrides are preserved. `AF_SOURCE_ROOT` may explicitly
select the source root used by read-only routing. Paths with spaces and symlinked root
parents are supported through content validation and real-path containment.

Missing, changed, partial, malformed, wrong-identity, or wrong-schema progression
outputs stop immediately. A zero child exit is not success unless the expected
versioned result and output bytes validate. Page/OCR, source identity, registry,
catalog-base, and source-QA gates are rendered without bypass. Once an editorial
context and decisions ledger are bound, every later resume stops at the same review
workspace without invoking progression again.

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
