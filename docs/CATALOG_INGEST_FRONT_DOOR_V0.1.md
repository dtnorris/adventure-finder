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
  --policy-definition /path/to/exact-policy-definition \
  --policy-id POLICY-ID \
  --policy-version POLICY-VERSION \
  --policy-values '{"profile":"SELECTED PROFILE","execution":"SELECTED MODE"}' \
  --selected-by "OPERATOR"

bin/af-catalog resume OPERATION-UUID

bin/af-catalog bind-successor-version OPERATION-UUID \
  --successor-version 7.5.2 \
  --selected-by "OPERATOR"

bin/af-catalog successor-version-authority OPERATION-UUID --json
```

Start requires every semantic source declaration, an exact base catalog, and an
explicit scoring/execution policy selection. The policy-definition file is hashed as
the immutable definition identity; the ID, version, and nonempty JSON selected-values
object are recorded as inert operator intent. None of these values authorizes scoring,
inference, execution, retry, recovery, provider capacity, catalog mutation, commit, or
push. Boundaries, parentage, Adventure IDs, and approval remain explicitly unset.

The command generates and prints a lowercase UUIDv4 handle unless `--operation-id` is
supplied. The latter is useful for deliberate external identity assignment and exact
conflict tests; reusing a handle for different immutable input fails closed.

## Start behavior

Start hashes the PDF, catalog, and policy definition, creates revision zero through
`IngestOperationStore`, and persists a versioned local resume context. That context
contains absolute runtime root mappings only. It is not part of operation identity,
and the operation document retains only portable root-relative locators plus content
digests and byte counts.

After publishing the handle, start invokes the existing public `convert-cached` PDF
entry. A reported durable receipt is bound as a converter-owned artifact in revision
one, then the existing IG-05C2 composer invokes pipeline's public
`af-ingest-next --operation-input ... --json` interface and renders its gate. The
composer never uses `--auto` and never executes a returned command.

A reviewable nonzero converter result still binds and routes a reported receipt, then
returns the converter status. A missing receipt leaves the valid revision-zero
operation at `NEEDS_FIRST_COMPONENT_ARTIFACT`; resume does not retry conversion. A
pipeline rejection is rendered with pipeline ownership and remains a failure.

## Resume behavior

Resume accepts only the handle. It reloads the versioned root context, validates the
complete append-only operation history and every bound byte sequence, and recomputes
the current gate through `IngestOperationRouting`. It requires no prior shell history
or repeated input, catalog, component, or artifact paths.

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
