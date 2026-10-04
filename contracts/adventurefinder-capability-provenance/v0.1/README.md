# AdventureFinder capability provenance v0.1

Status: public AdventureFinder provenance contract for
`adventurefinder-capability-provenance/v0.1`.

AdventureFinder owns this document. WLO separately owns the referenced generic
`ollama-capability-request/v0.1` runtime contract. This provenance document
records how an operator alias and frozen AFW plan selected one generic
capability artifact; it does not redefine or duplicate that artifact's runtime
requirements.

## Document shape

The root object contains exactly:

| Field | Requirement |
| --- | --- |
| `contract_version` | Exact string `adventurefinder-capability-provenance/v0.1`. |
| `operator_alias` | Exact AdventureFinder operator alias used for resolution. |
| `batch_handle` | Exact operator batch handle. |
| `production_batch_id` | Registered AdventureFinder production-batch identity. |
| `plan_id` | Exact frozen AFW plan identity. |
| `plan_sha256` | Lowercase SHA-256 of the exact frozen AFW plan bytes. |
| `pool_id` | Exact AFW pool selected by the alias. |
| `capability_request` | Immutable identity of the separate generic artifact. |

`capability_request` contains exactly:

| Field | Requirement |
| --- | --- |
| `contract_version` | Exact generic contract version `ollama-capability-request/v0.1`. |
| `fingerprint` | WLO-defined semantic fingerprint of normalized runtime requirements. |
| `artifact_sha256` | Lowercase SHA-256 of the exact generic capability-request artifact bytes. |

All scalar identity strings are nonempty and trimmed. Both digests are exact
lowercase 64-hex values. Unknown or missing fields are invalid.

## Boundary

The provenance document does not contain model, model digest, context length,
GPU-residency requirement, GPU ID, provider, fleet, campaign, budget, worker,
generation, or endpoint data. Runtime capability semantics remain exclusively
in the separately identified WLO artifact. Consequently, changing only this
AdventureFinder provenance cannot change the generic semantic fingerprint.
