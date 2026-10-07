# Durable ingest-operation routing composition v0.1

`AdventureFinderWorkspace::IngestOperationRouting` is the AdventureFinder-owned,
read-only composition between a validated durable operation and the pipeline-owned
`af-ingest-routing-input/v0.1` seam. It is a reusable library entry for the later IG-06
front door; it is not a second operator command and never advances ingestion.

The composer loads and validates the complete operation through
`IngestOperationStore`, selects the final append-only artifact binding (not a discovered
file or newest timestamp), resolves that binding through the store's configured roots,
and invokes the pipeline's public `bin/af-ingest-next --operation-input ... --json`
interface. It never loads pipeline implementation code or writes pipeline state.

```ruby
require "adventure_finder_ingest_operation_store"
require "adventure_finder_ingest_routing"

store = AdventureFinderWorkspace::IngestOperationStore.new(
  roots: {
    "input" => input_root,
    "catalog" => catalog_root,
    "converter" => converter_root,
    "pipeline" => pipeline_root,
    "source" => source_root
  }
)
composer = AdventureFinderWorkspace::IngestOperationRouting.new(
  store: store,
  project_root: ENV.fetch("AF_PROJECT_ROOT"),
  front_door_root: ENV.fetch("AF_ADVENTURE_FINDER_ROOT"),
  pipeline_root: ENV.fetch("AF_DATA_PIPELINE_ROOT"),
  source_root: source_root,
  catalog_root: catalog_root
)
result = composer.compose(operation_id)
composer.render(result)
```

## Projection and authority

The projection contains only contract-authorized values:

- exact operation ID, revision, and canonical document digest;
- the selected artifact's bound digest and byte count;
- explicitly selected source ID, edition, pagination authority, and publisher, or
  `null` when the operation has not bound them;
- the exact frozen base catalog and its explicit/catalog-head provenance; and
- inert policy identity and selected values, when present.

The v0.1 operation has no canonical-Markdown choice field, so the composer emits that
optional projection member as `null`; it does not parse component artifacts to invent
or duplicate that fact. Pipeline remains responsible for validating the routed
artifact, its public schema, and any component-owned provenance it carries.

An operation with no artifact returns `NEEDS_FIRST_COMPONENT_ARTIFACT` without calling
pipeline. An editorial context without a later, explicitly linked decisions artifact
returns `NEEDS_EDITORIAL_DECISIONS_ARTIFACT`. Otherwise, the pipeline route determines
the gate: `NEEDS_*` is human review, `READY_*` is an operator action, and `BLOCKED_*`
remains blocked. Evidence, human-review text, warnings, and next-command observations
are retained in the ephemeral composition result.

The operation projection is a temporary invocation file. Any occurrence of its path in
pipeline output is replaced with `<operation-input>` before returning; no reusable
command is executed or persisted. IG-06 must rerun composition and provide its own
current projection when it eventually presents an operator action.

## Failure and replay behavior

Missing/corrupt operation data, changed bound bytes, incompatible artifact versions,
unsafe roots, incomplete editorial bundles, pipeline contract failures, component
identity conflicts, and operation advancement during inspection all return a versioned
`REJECTED` result with an owning subsystem, stable code where the public seam supplies
one, and a diagnostic message. Nothing is repaired, rebound, retried, or executed.

Identical operation and component bytes produce the same operation digest, routing
input digest, pipeline state, and gate after process restart. A moved live catalog head
does not silently replace an explicitly frozen operation base. Stages for which the
pipeline requires the live head to equal that base continue to fail closed under the
pipeline's `STALE_OPERATION_BASE` policy.
