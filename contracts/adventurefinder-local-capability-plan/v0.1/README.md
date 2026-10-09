# AdventureFinder local capability plan v0.1

Status: public AdventureFinder planning contract for
`adventurefinder-local-capability-plan/v0.1`.

AdventureFinder owns the operation/workload binding and possible one-worker
sequence. WLO remains authoritative for `wlo-execution-plan/v0.3` validation and
the referenced `ollama-capability-request/v0.1` fields and fingerprints. This
contract does not replace the frozen plan or assert worker readiness.

## Document shape

The root contains:

| Field | Requirement |
| --- | --- |
| `contract_version` | Exact contract version above. |
| `operation` | Exact `operation_id`, `intent_id`, and `authority_id` from the successful staged-workload preparation. |
| `workload` | Exact workload/plan IDs, plan contract version, and lowercase SHA-256 of the frozen plan bytes. |
| `capabilities` | Distinct exact WLO capability requests in first-required-occurrence order. |
| `sequence` | One-based planning steps referencing capability fingerprints and complete pool/job mappings. |
| `accounting` | Exact capability, pool, and job counts. |
| `assumptions` | Stable statements delimiting sequence meaning and authority. |
| `planning_only`, `read_only` | Always `true`. |
| `readiness_observed`, `execution_authorized`, `provider_authorized`, `catalog_adoption_authorized` | Always `false`. |

Each `capabilities` entry contains the exact generic `capability_request`, its
WLO semantic `capability_fingerprint`, the SHA-256 of its canonical artifact
bytes, and one or more pool mappings. A pool mapping contains its exact
`pool_id`, ordered `required_labels`, and frozen jobs. Each job retains
`job_id`, optional `group_id`, and `depends_on_job_ids`. Operation, workload,
provider, pool, label, and job provenance never enters the generic capability
request.

Pools are grouped only when WLO produces the same fingerprint from every
normalized capability field: model, digest, context length, GPU-residency
requirement, and optional GPU identity. Labels remain pool constraints and do
not affect or weaken that equality. Pools and jobs retain frozen-plan order
within their mappings; the capability sequence is ordered by the first job
that requires each capability, followed by any unused declared pool in plan
order. `group_id` is retained as reporting/priority metadata, never interpreted
as a v0.3 barrier.

## Validation and boundary

The reader must validate the stored preparation result, exact plan path and
bytes, AFW snapshot plan hash, and staged operation/workload/authority binding.
Missing exact capability requirements, invalid WLO schemas, duplicate IDs,
unknown pool references, or stale bindings fail closed. V0.1 supports the
current independent-job forward-plan shape. Any nonempty job dependency is
explicitly refused because a safe one-pass capability sequence is not defined
by this version.

The output is a deterministic read-only projection. It does not inspect local
hardware, workers, model installations, endpoints, providers, or live state;
assign workers; load models; schedule or execute jobs; acquire capacity; or
authorize catalog adoption. An exact GPU identity or label that cannot be met
locally remains visible rather than being substituted.
