This is the current responsibility map. AFW binds scoring evidence; the pipeline
prepares review packages and retains human editorial authority before AMC promotion.
See [the composed operator runbook](docs/operator-runbook.md) for public commands.

```text
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                         ADVENTUREFINDER WORKSPACE / CONTROL PLANE                       │
│  adventure-finder                                                                       │
│  repo manifest • af-status • af-test • af-doctor • sync/snapshot                        │
└─────────────────────────────────────────────────────────────────────────────────────────┘
                                              │
                                              │ coordinates / verifies
                                              ▼

┌────────────────────────────── SOURCE + SPECIFICATION LAYER ──────────────────────────────┐
│                                                                                          │
│  OWNED / LICENSED SOURCE MATERIAL                       NORMATIVE SPECIFICATIONS         │
│                                                                                          │
│  PDFs / scans / images ──► image-to-pdf-converter       md-specification-files           │
│             │                                             │                              │
│             └────────────► pdf-to-llm-md-converter        ├─ AFAO scoring ontology       │
│                                                           ├─ ABDS boundary rules         │
│  Publisher / reference metadata                           ├─ AFADS data rules            │
│             │                                             ├─ AFQIS query interpretation  │
│             │                                             └─ AFMRS matching/ranking      │
│             ▼                                                                            │
│  Physical books / legitimate digital purchases                                           │
│                         │                                                                │
│                         ▼                                                                │
│              md-for-llm-book-content                                                     │
│              ├─ canonical LLM-edition Markdown                                           │
│              └─ source_registry.yml                                                      │
│                         │                                                                │
└─────────────────────────┼────────────────────────────────────────────────────────────────┘
                          │
                          ▼

┌──────────────────────────── INGESTION + CATALOG LAYER ──────────────────────────────────-┐
│                                                                                          │
│                         af-data-pipeline                                                 │
│                                                                                          │
│     source intake / registration                                                         │
│                │                                                                         │
│                ▼                                                                         │
│     boundary discovery + dossiers                                                        │
│                │                                                                         │
│                ▼                                                                         │
│     human/editorial boundary adjudication                                                │
│                │                                                                         │
│                ▼                                                                         │
│     frozen canonical Adventure IDs / page boundaries                                     │
│                │                                                                         │
│                ▼                                                                         │
│     deterministic AMC successor construction                                             │
│                │                                                                         │
│                ▼                                                                         │
│                     af-xlsx-data-sources                                                 │
│                     CANONICAL PROJECT STATE: PROJECT_STATE.yml                           │
│                     Adventure Master Catalog (AMC)                                       │
│                     metadata + boundaries + accepted assessments                         │
│                                                                                          │
└─────────────────────────┬────────────────────────────────────────────────────────────────┘
                          │
                          │ scoring-ready Adventure IDs / source spans / missing fields
                          ▼

┌──────────────────────── ADVENTUREFINDER WORKLOAD LAYER ──────────────────────────────────┐
│                                                                                          │
│                  af-workloads (AFW)                                                      │
│                  scoring intent and evidence binding                                     │
│                                                                                          │
│  OWNS ADVENTUREFINDER MEANING                                                            │
│                                                                                          │
│  ├─ choose Adventure IDs / dimensions                                                    │
│  ├─ qualified model + scoring-profile policy                                             │
│  ├─ production workload + qualification / result interpretation                          │
│  ├─ scoring-workload snapshots + human qualification adjudication                        │
│  ├─ exact source / AMC / ontology provenance                                             │
│  └─ compile work into generic executable jobs                                            │
│                                                                                          │
│  workloads/<id>/                                                                         │
│  ├─ snapshot.yml                                                                         │
│  ├─ case_index.csv                                                                       │
│  └─ execution-plan.json (v0.3 logical plan)                                              │
│  build/workloads/<id>/cases/... (generated; runtime/preflight alongside)                 │
│                                                                                          │
│                         │ opaque argv/env + logical pools; dynamic registry placement    │
│                         ▼                                                                │
└─────────────────────────┼────────────────────────────────────────────────────────────────┘
                          │
                          ▼

┌──────────────────────────── GENERIC EXECUTION LAYER ─────────────────────────────────────┐
│                                                                                          │
│                  workload-orchestrator (WLO)                                             │
│                                                                                          │
│  KNOWS NOTHING ABOUT ADVENTUREFINDER SEMANTICS                                           │
│                                                                                          │
│  ├─ schedule jobs                                                                        │
│  ├─ worker pools / concurrency                                                           │
│  ├─ readiness                                                                            │
│  ├─ resume / failure state                                                               │
│  ├─ logs + execution provenance                                                          │
│  ├─ audited retries / circuit breakers                                                   │
│  └─ generic execution; provider capacity admission remains external                      │
│                                                                                          │
│                  │                                    │                                  │
│          DEFAULT / $0 PATH                     REMOTE REGISTRY PUBLISHER                 │
│                  │                                    │                                  │
│                  ▼                                    ▼                                  │
│        local worker / Ollama                 runpod-ollama-fleet (RPOF)                  │
│                                               ├─ RunPod lifecycle                        │
│                                               ├─ GPU / pod selection                     │
│                                               ├─ Ollama/bootstrap/cache                  │
│                                               ├─ tunnels / routing                       │
│                                               ├─ leases + cost safeguards                │
│                                               └─ replacement / recovery                  │
│                                                        │                                 │
│                                                        ▼                                 │
│                                               remote Ollama workers                      │
│                                                                                          │
│  NOTE: WLO runs commands locally against LOW/RPOF registry-selected endpoints.           │
│  RPOF independently admits bounded paid capacity; WLO owns no provider dispatch.         │
│                                                                                          │
└─────────────────────────┬────────────────────────────────────────────────────────────────┘
                          │ executes
                          ▼

┌────────────────────────────── SCORING EXECUTION ─────────────────────────────────────────┐
│                                                                                          │
│                    AFW scoring / qualification job adapters (local commands)             │
│                             │                                                            │
│                             ▼                                                            │
│                    af-cli-scoring-utility (AFSU)                                         │
│                                                                                          │
│  OWNS ONE ASSESSMENT                                                                     │
│  ├─ prompt construction                                                                  │
│  ├─ frozen dimension rubric/profile                                                      │
│  ├─ source submission                                                                    │
│  ├─ model invocation against the selected Ollama endpoint                                │
│  ├─ strict structured-output validation                                                  │
│  └─ score + confidence + evidence                                                        │
│                                                                                          │
└─────────────────────────┬────────────────────────────────────────────────────────────────┘
                          │
                          │ raw scoring evidence
                          ▼

┌────────────────────── EVIDENCE + ADJUDICATION / PROMOTION LOOP ──────────────────────────┐
│                                                                                          │
│  llm-response-data                       af-data-pipeline                                │
│  durable raw/audit evidence  ◄──────────► production ingest                              │
│                                          validation / circuit breakers                   │
│                                                   │                                      │
│                                                   ▼                                      │
│                                          frontier/manual adjudication                    │
│                                                   │                                      │
│                                                   ▼                                      │
│                                          deterministic AMC apply                         │
│                                                   │                                      │
│                                                   ▼                                      │
│                                      successor canonical AMC                             │
│                                                   │                                      │
│                                                   └────────► af-xlsx-data-sources        │
│                                                                                          │
└───────────────────────────────────────────┬──────────────────────────────────────────────┘
                                            │
                                            │ accepted catalog artifact
                                            ▼

┌────────────────────────────── CONSUMPTION LAYER ─────────────────────────────────────────┐
│                                                                                          │
│                 ┌──────────────────────────┴──────────────────────────┐                  │
│                 │                                                     │                  │
│                 ▼                                                     ▼                  │
│       af-frontier-pack                                    af-cli-query-matcher           │
│       deterministic packaging                             AFQIS / AFMRS path             │
│       for frontier-model use                              filtering / weighting / ranking│
│                 │                                                     │                  │
│                 ▼                                                     ▼                  │
│       Frontier ChatGPT                                    deterministic candidate        │
│       ├─ explore library                                  lists / comparisons            │
│       ├─ compare adventures                                           │                  │
│       ├─ rediscover material                                          │                  │
│       ├─ reason across catalog                                        │                  │
│       └─ inspect source/evidence                                      │                  │
│                 │                                                     │                  │
│                 └──────────────────── USER / DAVID ───────────────────┘                  │
│                                                                                          │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```
