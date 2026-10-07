# AdventureFinder ingest operation v0.1

Status: contract definition and executable document/revision proof for
`adventurefinder-ingest-operation/v0.1` (IG-05A). Persistence, read-only routing
composition, and the public start/resume entry are implemented by their separate
AdventureFinder layers. The historical `bin/af-catalog INPUT.pdf` form remains a
non-operation compatibility path.

One operation coordinates one explicitly selected digital-book PDF toward the
next meaningful operator review gate. Its UUID is not a source ID, Adventure ID,
workload ID or content hash. Two deliberate operations may reference identical
bytes; filename similarity never establishes identity or duplicate intent.

## Authority

| Fact | Authority | Operation representation |
| --- | --- | --- |
| Operator intent, operation identity and administrative lifecycle | AdventureFinder, on David's explicit instruction | Frozen input/catalog bindings, one-time choices, revisions and status |
| Source identity, edition, pagination authority, publisher | David plus frontier semantic decisions | Explicit attributed declaration; unset until supplied, not inferred from a path or receipt |
| Validated source evidence, source registration and provenance | Component-owned source artifacts, validated through pipeline's public interfaces | Digest-bound references; declarations are claims, not proof of registration |
| Conversion and page eligibility | Converter receipt and its referenced evidence | Reference to receipt; no copied page eligibility flags |
| Boundaries, parentage, Adventure IDs and approval | David/frontier decisions in pipeline-owned boundary/editorial artifacts | References; corresponding future-choice placeholders remain null |
| Catalog contents and transformations | Catalog artifacts and pipeline's validated provenance/apply artifacts | Exact frozen base catalog; successors never replace this base binding |
| Scoring/execution policy selection | Explicit operator intent against the selected policy definition | Policy ID, version, definition digest and selected values; no execution authority |
| Runtime capabilities, Levels, qualification and editorial acceptance | Their existing component contracts | No new defaults, overrides or alternate acceptance rules |
| Next route/gate | Fresh public pipeline router result over validated evidence | Optional advisory observation, never authoritative operation status |

The coordinator MUST NOT copy component facts into independently mutable truth.
In particular, a cached `READY_FOR_AFW_WORKLOAD_BUILD` is neither approval nor
permission to run anything. Selecting policy grants no execution, retry,
recovery, provider, paid-capacity, inference, scoring, WLO, RPOF or Ollama action.

## Exact document shape

`AdventureFinderWorkspace::IngestOperation.validate!` is the executable shape
validator. Unknown/missing fields fail closed. Documents are JSON objects with
string keys; nulls are explicit. Identity strings are nonempty, trimmed and
control-free. Digests are lowercase SHA-256. Timestamps use valid UTC
`YYYY-MM-DDTHH:MM:SSZ`, with seconds and no fractional part.

| Top-level field | Creation / binding rule |
| --- | --- |
| `contract_version` | Required exact version above; immutable |
| `operation_id` | Required lowercase UUIDv4, generated once; immutable |
| `created_at` | Required timestamp; immutable |
| `revision` | Required nonnegative integer, initially 0 |
| `previous_revision_sha256` | Required null at revision 0; thereafter digest of the previous canonical operation document |
| `input` | Required `{kind: "digital_book_pdf", content: CONTENT}`; PDF byte identity is frozen at creation |
| `source_declaration` | Required keys `source_id`, `edition`, `pagination_authority`, `publisher`; each null or CHOICE |
| `base_catalog` | Required exact catalog bytes plus selection provenance, frozen at creation; never a symbolic live head |
| `policy` | Required null or POLICY; null means not selected, not a default policy |
| `artifacts` | Required ordered array, initially empty; append-only references, never embedded component facts |
| `future_choices` | Required keys `boundaries`, `parentage`, `adventure_ids`, `approval`, all null in this version |
| `coordination` | Required `{status, route_observation}`; initially `created` and null |

`CONTENT` has exactly `sha256`, `bytes` (positive integer), and `locator`.
`locator` has exactly `root` and `path`. The input PDF and base catalog must
exist, be readable and have their actual bytes hashed before creation; a
placeholder digest is not a valid production binding. The synthetic fixtures
in `test/ingest_operation_test.rb` prove document shape, not real evidence.

`CHOICE` has exactly `value` (identity string), `selected_by` (attributed identity
string) and `selected_at` (timestamp). All four source choices may be unset at
creation. An explicit later David/frontier choice changes null to CHOICE in a
new revision; it never silently replaces an existing choice. Source registration
requires the applicable source identity to be supplied and reconciled with
validated source evidence. Edition/pagination/publisher must be supplied before
any boundary or catalog action that depends on them. Unset is a review gate,
not permission to extract semantics from filenames, paths, shell memory or chat.
If public component evidence conflicts with a declaration, stop for explicit
repair; neither side silently overwrites the other.

`POLICY` has exactly `policy_id`, `policy_version`, `definition_sha256`,
`selected_values` (nonempty JSON object with finite numbers), `selected_by` and
`selected_at`. ID/version identify an explicit policy definition whose exact
bytes match the digest; no policy name or values are synthesized here. Its own
public policy contract must validate the values before binding. The operation
validator checks structure, not policy semantics. Selection may occur at
creation or bind once later, but must be explicit before downstream workload
planning. It remains inert even if a selected value looks like an action.
Corrections to an already bound choice or policy require a new operation linked
by operator records, not an in-place identity change. This version has no
cross-operation adoption or automatic migration mechanism.

## Frozen base catalog

`base_catalog` contains exactly `content: CONTENT` and `selection`.
`selection` contains exactly `method`, `selected_by`, `selected_at` and
`project_state`:

- `method: "explicit"`: David selects an exact catalog; `project_state` is null.
- `method: "catalog_head"`: read the selected catalog root's public
  `PROJECT_STATE.yml`, require `adventurefinder-project-state/v0.2`, resolve its
  `catalog_head`, and verify its SHA-256 and byte count when supplied. Bind the
  actual catalog SHA-256 and bytes. `project_state` is exactly
  `{contract_version: "adventurefinder-project-state/v0.2", content: CONTENT}`
  identifying the manifest bytes used for this selection. Retain access to that
  exact historical evidence, not a mutable substitute. A byte-for-byte retained
  evidence copy is provenance, not a new independently editable catalog head.

Selection provenance and catalog identity are immutable together. A later
moving `catalog_head` neither updates this base nor invalidates otherwise
matching artifact-bound evidence. It can, however, make an **unfrozen next
action unsafe**: pipeline's current intake routing reads `PROJECT_STATE.yml`,
whereas later editorial/freeze artifacts bind base AMC hashes. Before consuming
an unfrozen route or command, coordination must verify the consulted head equals
the operation's frozen base. If it differs, stop with `STALE_INPUT`; do not
rewrite PROJECT_STATE, select a different operation base, or execute the command.
For artifact-bound routes, validate the artifact's base identity against this
operation instead. Output/successor catalogs remain separate component-owned
artifacts; they do not mutate `base_catalog`.

The existing router has no operation-specific frozen-catalog switch. No such
flag is invented here. Future routing composition must enforce this guard using
public artifacts/interfaces; if progress needs a new component seam, report
`NEEDS_JUDGMENT` rather than bypassing the guard. No synchronized component
change is necessary to define or validate this contract.

## Root model and relocation

Locators are root-relative, not identities. Allowed roots are:

| Locator root | Explicit resolution context |
| --- | --- |
| `input` | Operator-selected external input directory, explicitly supplied; never inferred from a previous shell |
| `front_door` | Detached `AF_ADVENTURE_FINDER_ROOT`; not the component root |
| `pipeline` | Explicit supported `AF_DATA_PIPELINE_ROOT`, else `AF_PROJECT_ROOT/af-data-pipeline` |
| `converter` | Explicit supported `AF_PDF_CONVERTER_ROOT` / router `--pdf-converter-root`, else component default |
| `source` | Explicit router `--source-root`, else `AF_PROJECT_ROOT/md-for-llm-book-content` |
| `catalog` | Explicit router `--catalog-root`, else `AF_PROJECT_ROOT/af-xlsx-data-sources` |

`AF_PROJECT_ROOT` remains the component parent. Preserve supported AFW/scorer
overrides (`AF_AFW_ROOT`, `AF_SCORER_ROOT`, `--afw-root`, `--scorer-repo`) when
later composition needs them; this contract introduces no new environment flags.
Root bindings are explicit invocation/deployment context, not semantic facts
stored in the operation. Never silently switch normal/production contexts.

Paths must be nonempty relative paths: no absolute paths, backslashes, colon,
empty segments, `.` or `..`. A future resolver must also enforce resolved-path
containment (including symlinks) within the explicitly selected root. Symlinked
root directories themselves are supported. This validator does not resolve paths.
Relocation is allowed only when the resolved file still matches both SHA-256
and byte count, and its owner validation/provenance still match. A locator
change is recorded as a revision, not a new semantic identity. A root mapping
change requires the same revalidation even when document bytes do not change.
No filename search or path-based content substitution is allowed.

## Artifact bindings and compatible progress

Each `artifacts` element has exactly `artifact_id` (unique local reference ID),
`kind`, `owner`, `contract_version`, `content: CONTENT`, `inputs` and `supersedes`.
`inputs` is a nonempty, duplicate-free list naming earlier artifact IDs or the
reserved bindings `input` and `base_catalog`. These are coordination provenance
links; component-owned internal source/catalog hashes must still agree with
them. A matching list does not prove component provenance.

Supported kind/owner/schema combinations are explicit in `IngestOperation::ARTIFACTS`:
converter-owned conversion receipt v0.1; pipeline-owned source intake v0.1,
boundary dossier v0.1/v0.2, editorial context v0.1, editorial decisions v0.1,
boundary freeze v0.1 and boundary-freeze apply report v0.1. These match the
current router's public input artifacts; unknown versions fail closed.
Source registries, canonical Markdown and catalog output facts stay behind their
owning public artifacts and validation, not new mutable operation fields.

The first reference of a kind has null `supersedes`; a later reference of that
kind must name the most recent earlier reference of the same kind. Old bindings
cannot be removed, reordered, rehashed, or reassigned to another owner. A new
binding is compatible progress only after the owning public validator accepts
its schema/content and its source/base-catalog/parent provenance agrees with
the operation and earlier evidence. Dossier v0.1 to v0.2 may be appended when
those checks pass, not edited in place. If a component rewrites an artifact at
the same path, retain/relocate the original exact evidence before binding the
new bytes; a changed file alone is not advancement. Editorial context and
decisions are separate references validated together by the public router.

## Lifecycle, gates and replay

Administrative `status` is `created` (no artifacts yet), `open` (at least one
bound artifact), `paused` (operator coordination paused), or `closed` (archived
coordination intent, not catalog promotion or downstream success). Revision 0
must be `created` with no artifacts. `paused` can resume after evidence checks;
`closed` permits exact replay only. A closed operation cannot silently reopen.

Meaningful gates are freshly derived, not persisted as independent truth:

| Evidence / route condition | Operator gate |
| --- | --- |
| New operation, no bound artifact | Obtain conversion evidence; not a missing-file error |
| Page-review or conversion block | Review/repair converter-owned evidence |
| Missing source declaration or conflicting source evidence | David/frontier source identity, edition/pagination or publisher decision |
| Editorial review or draft freeze | David/frontier boundaries, parentage, Adventure IDs and explicit approval |
| Missing successor metadata / adoption review | Explicit catalog metadata and adoption decision under existing pipeline rules |
| AFW workload-build readiness | Handoff review only; no scoring or execution authorization |

Optional `route_observation` has exactly `artifact_id`, `router_state`,
`observed_at`, `basis_sha256`. It references a bound artifact, retains the raw
public router state string, and never stores executable commands or copied
component facts. `observation_basis` hashes operation ID, input, declarations,
base catalog, policy and artifact bindings, excluding locators. Changing a
binding invalidates a retained observation; clear it or replace it with a fresh
observation. Unknown router state strings remain uninterpreted observations,
never authorization. Even a matching observation must be recomputed from fresh
validated evidence before a next action: its hash cannot detect external file
mutation, moving roots or changed component code.

`validate_revision!(previous, current)` accepts exact replay as a no-op;
otherwise it requires revision +1, exact predecessor digest, unchanged frozen
bindings, one-time null-to-choice bindings and append-only artifact lineage.
The predecessor digest is SHA-256 of UTF-8 compact Ruby `JSON.generate` output
after recursively sorting object keys; array order is retained. It is a
coordination concurrency/replay token, not an artifact byte digest. Future
persistence must compare the expected revision/digest atomically before writing;
this class performs no locking, persistence, command retries or recovery.

On resume, verify the document and revision chain, resolve explicit roots,
rehash all bound evidence (including provenance), run owner validation through
public interfaces, reconcile identities, then ask the public router for its
current observation. Use read-only `af-ingest-next ARTIFACT --json` with the
applicable explicit roots, never `--auto`. Its JSON output currently has no
version envelope; do not invent one or import private implementation state.

| Finding | Required result; no automatic action |
| --- | --- |
| No artifact was ever bound | Normal initial state; do not fabricate a receipt |
| Previously bound artifact missing | `MISSING_BOUND_ARTIFACT`; pause and explicitly restore exact evidence or verified relocation, never restart as a new operation |
| Content digest/size differs or identity conflicts | `STALE_INPUT`; preserve old binding; explicit repair/new operation or validated append-only successor |
| Malformed/unreadable document or owner validation fails | `CORRUPT_EVIDENCE`; stop, preserve evidence and require explicit repair |
| Unsupported operation/artifact/policy contract | `INCOMPATIBLE_VERSION`; no best-effort coercion; explicit supported migration/new operation |
| Compatible new owner-validated evidence | Append a reference and invalidate old observations; no implied execution |

These are resume outcomes, not additional mutable component facts or implemented
router states. Repair of missing/corrupt evidence must restore the bound bytes;
changing immutable input/catalog/semantic choices requires a new operation.
Ordinary retries only repeat read-only observation; no automatic side-effect
retry follows from replay metadata. Existing IG-01 through IG-04 behavior stays
intact: the generic production AFW v0.3 handoff still requires explicit context
length 131072 and full GPU residency, no exact GPU ID, with existing runnable-ID,
page-eligibility, deferral, Levels, qualification and review rules unchanged.

## Executable proof and boundary

Run `ruby -Ilib:test test/ingest_operation_test.rb`, then the complete offline
`rake` suite. Tests include valid initial/bound examples, explicit later choices,
catalog provenance, malformed identities/versions, immutable conflicts,
relocation, append-only advancement, stale observations and replay. The validator
reads/writes no files and launches no commands. Shape-valid synthetic references
do not claim a public component validator was run. Actual artifact I/O checks,
the catalog-head guard, policy resolution and route/gate composition remain
obligations of later tasks, not implemented seams in IG-05A.
