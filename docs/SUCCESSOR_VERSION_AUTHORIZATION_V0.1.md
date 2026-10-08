# Successor-version authorization v0.1

AdventureFinder owns the operator intent that selects a successor catalog version;
pipeline owns deterministic successor creation. The
`adventurefinder-successor-version-authorization/v0.1` contract records that intent
without choosing a version, applying a boundary freeze, or changing a catalog.
Successor-version authority is independent of scoring/execution policy: no value in
`policy.selected_values` is interpreted as this authorization.

Bind an explicit value to an existing durable operation with:

```bash
bin/af-catalog bind-successor-version OPERATION-UUID \
  --successor-version 7.5.2 \
  --selected-by David
```

The version must contain two or more dot-separated numeric components. This is syntax
validation only. AdventureFinder does not infer an increment from the base catalog,
the current catalog head, a filename, or any policy value. The command validates the
complete operation and all bound bytes first, records the selection time in UTC, and
does not invoke pipeline or any downstream action.

## Frozen authority

One authorization freezes exactly:

- its contract version;
- the ingest operation contract version, operation ID, and creation timestamp;
- the frozen base catalog SHA-256 and byte count;
- the explicitly selected successor version;
- the selecting operator identity and UTC selection timestamp; and
- `authorization_id`, the SHA-256 of canonical sorted-key compact JSON for every
  preceding field (the document with `authorization_id` omitted).

The operation revision digest is deliberately not frozen. A legitimate later
component artifact may advance the operation while the operation/base identity stays
the same. A different operation or frozen base cannot reuse the authorization.

The default private store is
`$AF_ADVENTURE_FINDER_ROOT/output/ingest-authorities/successor-version/v0.1`.
It is separate from `output/ingest-operations/v0.1`: binding authority does not append
an operation artifact, rewrite a revision, or alter which converter/pipeline artifact
is routed. Existing `adventurefinder-ingest-operation/v0.1` histories therefore
remain valid with no migration. Absence is `UNBOUND`; once an authority directory
exists, missing, corrupt, incompatible, stale, or provenance-conflicting bytes fail
closed rather than reverting to unbound.

An identical bind is a no-write replay. A different version or selector for the same
operation/base is `SUCCESSOR_VERSION_AUTHORITY_CONFLICT`.

## Public consumer handoff

A later IG-09C pipeline consumer can request the public AdventureFinder projection:

```bash
bin/af-catalog successor-version-authority OPERATION-UUID --json
```

The result has contract
`adventurefinder-successor-version-authorization-projection/v0.1` and embeds the
validated authorization document. A consumer verifies the projection and authority
contract versions, recomputes `authorization_id`, and matches the operation ID and
frozen base SHA-256/byte count to its own input before using `successor_version`.
Consumers do not inspect AdventureFinder's private persistence layout.

This projection does not redefine pipeline's `af-ingest-routing-input/v0.1`, which
continues to omit successor-version authority. It is a separate, compatible producer
seam for a later pipeline-owned consumer contract. It grants no approval, execution,
retry, recovery, promotion, or adoption authority. Shared `catalog_head`,
`matcher_authorized_baseline`, and `production_dependency_floor` roles are untouched.
