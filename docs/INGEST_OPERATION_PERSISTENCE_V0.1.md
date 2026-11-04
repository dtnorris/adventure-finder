# Durable ingest-operation persistence v0.1

`AdventureFinderWorkspace::IngestOperationStore` is the AdventureFinder-owned
durability boundary for the `adventurefinder-ingest-operation/v0.1` contract. It
records operator intent and cross-component coordination only. Pipeline artifacts,
catalogs, converted sources, and owner decisions remain in their owning repositories;
an operation stores their contract version, content identity, and portable locator.

The default store is
`$AF_ADVENTURE_FINDER_ROOT/output/ingest-operations/v0.1` (or the running front-door
checkout when that variable is unset). A caller may provide another store root. Each
operation directory contains immutable, consecutively numbered JSON revisions plus a
small versioned store record. Revision zero is published by directory rename; later
revisions are fsynced and atomically renamed while holding an operation lock. There is
no mutable “current” pointer: the last complete consecutive revision is current.

With `AF_STATE_ROOT` selected, public commands and the default-root helper use
`$AF_STATE_ROOT/output/ingest-operations/v0.1`. The directory must already exist;
invalid selection refuses without a fallback store. An explicit library `root:`
continues to select that caller's store directly. The
[front-door state contract](CATALOG_INGEST_FRONT_DOOR_V0.1.md#external-adventurefinder-coordination-state)
defines ownership, refusal rules, the complete backup set and same-path replacement.

Absolute roots are runtime configuration, not operation-document identity.
External context v0.3 separately retains a physical state-directory binding;
it adds no fields to operation v0.1 and changes no portable locator semantics.
The caller supplies a mapping for the contract roots it uses (`input`, `front_door`,
`pipeline`, `converter`, `source`, and `catalog`). This preserves the existing
`AF_PROJECT_ROOT`, `AF_ADVENTURE_FINDER_ROOT`, `AF_DATA_PIPELINE_ROOT`, and
`AF_PDF_CONVERTER_ROOT` override boundary: a higher-level front door resolves those
settings and passes the resulting explicit roots. It must not infer semantic source,
edition, pagination, publisher, boundary, parentage, Adventure ID, or approval values.

## Library invocation

```ruby
require "adventure_finder_ingest_operation_store"

store = AdventureFinderWorkspace::IngestOperationStore.new(
  roots: {"input" => input_root, "catalog" => catalog_root}
)
operation = store.create(
  operation_id: operator_retained_uuid,
  created_at: operator_retained_utc_timestamp,
  input_locator: {"root" => "input", "path" => "book.pdf"},
  base_catalog_locator: {"root" => "catalog", "path" => "catalog.xlsx"},
  catalog_selected_by: "David"
)

# A new process reconstructs and revalidates the same context.
inspection = store.inspect(operation.fetch("operation_id"))
store.validate!(operation.fetch("operation_id"))
```

Creation hashes the referenced bytes before publishing revision zero. Repeating the
same creation is a no-write replay; a reused operation ID with different content or
choices is `CONFLICT`. `persist!` requires the expected current revision and document
digest, validates the complete IG-05A revision rules, revalidates every referenced
byte sequence, and appends exactly one revision. Exact replay returns the existing
revision without changing its bytes.

Inspection is read-only. It validates store metadata, the complete revision chain,
portable locator containment, and every bound content digest and byte count. Its
versioned report distinguishes:

- `ABSENT`: no operation has ever been published for that ID;
- `INTENTIONALLY_UNBOUND`: a valid created operation has no component artifacts yet;
- `MISSING_BOUND_ARTIFACT`: a previously bound input, catalog, project state, or
  component artifact is no longer present;
- `STALE_INPUT`: referenced bytes no longer match their frozen identity;
- `CORRUPT_EVIDENCE`: malformed/missing store data, unsafe roots, or an invalid chain;
- `INCOMPATIBLE_VERSION`: an unknown store or operation contract; and
- `CONFLICT`: a colliding creation, stale writer, or forbidden immutable change.

The inspection report exposes component-owned facts only as references. It does not
copy an artifact body into coordination state, make route observations editable facts,
authorize execution, assign editorial decisions, or imply promotion. Pipeline route
composition remains a separate public-interface consumer. The operator-facing
`bin/af-catalog start` and `resume` commands use this store without moving persistence,
component validation, or routing authority into the command layer.

Explicit successor-version intent uses the separate, append-only
[`adventurefinder-successor-version-authorization/v0.1`](SUCCESSOR_VERSION_AUTHORIZATION_V0.1.md)
store. It binds the stable operation/base identity without changing this contract,
rewriting any v0.1 revision, or making an AdventureFinder-owned authorization look
like a component artifact. A valid historical operation with no authorization remains
valid and reports that the authority is not yet bound when requested.
