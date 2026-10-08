# Durable source-side ingest driver v0.1

AdventureFinderWorkspace::IngestSourceDriver composes the existing durable ingest
operation, the read-only operation router, and pipeline's public
bin/af-source-progress continuation. It is reached only through bin/af-catalog start
or bin/af-catalog resume; it is not a second command family or a competing pipeline
state machine.

## Authority and durable intent

AdventureFinder continues to own the operation UUID, immutable PDF and base-catalog
bindings, attributed source declarations, resume context, and append-only component
references. Pipeline owns source-intake, registration, boundary-dossier, and
boundary-editorial validation and publication.

An explicit --canonical-destination on start creates a v0.2 resume context. The
context stores a portable locator beneath the configured source root. The value is
never inferred and survives fresh-process resume. Existing v0.1 contexts remain
read-only routing operations and do not gain continuation authority.

## Fixed execution scope

Before every child call, the driver asks IngestOperationRouting for a fresh validated
route and exact af-ingest-routing-input/v0.1 projection. Only these route and
artifact pairs may invoke af-source-progress:

| Bound artifact | Required fresh route | Accepted PASS |
| --- | --- | --- |
| conversion receipt | NEEDS_CANONICAL_MARKDOWN_PLACEMENT | SOURCE_INTAKE_READY |
| source intake | READY_FOR_SOURCE_REGISTRATION or READY_FOR_BOUNDARY_DOSSIER | BOUNDARY_DOSSIER_READY |
| boundary dossier | READY_FOR_EDITORIAL_HANDOFF | BOUNDARY_EDITORIAL_HANDOFF_READY |

The loop has a hard maximum of three PASS transitions. It never invokes a generic
auto mode. Any other route is rendered as the current gate without execution.

## Validation and binding

The driver accepts only af-source-progression-result/v0.1. It requires exact
operation UUID, revision, operation digest, routing-input digest, input binding,
transition, state, output roles, artifact kinds, owners, contract versions, portable
locators, byte counts, SHA-256 digests, and the source-progression non-mutation
contract. All declared files must exist beneath their declared component roots.

Only a validated PASS appends references through IngestOperationStore.persist! with
the prior revision and digest as optimistic-lock tokens. A zero exit with missing,
partial, corrupt, changed, or mismatched output is rejected. Pipeline GATE results
append nothing. On restart, pipeline's replay-safe seam validates and reuses
compatible existing outputs; the operation appends only the next missing references.

## Terminal handoff

After binding the linked editorial context and decisions ledger, the driver stops at
BOUNDARY_EDITORIAL_REVIEW and prints their shared directory as the authoritative
review workspace. Later resumes validate those bound bytes and return the same gate
without invoking pipeline progression.

This driver never creates candidates or editorial decisions, assigns Adventure IDs,
approves a freeze, applies/imports a freeze, prepares or executes scoring, performs
inference, changes provider capacity, binds successor metadata, adopts a catalog, or
promotes catalog roles.
