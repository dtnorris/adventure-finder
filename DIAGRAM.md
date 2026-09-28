```text
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                         ADVENTUREFINDER WORKSPACE / CONTROL PLANE                       │
│  adventure-finder                                                                       │
│  PROJECT_STATE.yml • repo manifest • af-status • af-test • af-doctor • sync/snapshot    │
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
│                     CANONICAL PROJECT STATE                                              │
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
│                  formerly the AFIO codebase                                              │
│                                                                                          │
│  OWNS ADVENTUREFINDER MEANING                                                            │
│                                                                                          │
│  ├─ choose Adventure IDs / dimensions                                                    │
│  ├─ qualified model + prompt/profile policy                                              │
│  ├─ production backlog semantics                                                         │
│  ├─ scoring-workload snapshots                                                           │
│  ├─ exact source / AMC / ontology provenance                                             │
│  └─ compile work into generic executable jobs                                            │
│                                                                                          │
│  workloads/<id>/                                                                         │
│  ├─ snapshot.yml                                                                         │
│  ├─ case_index.csv                                                                       │
│  ├─ execution-plan.json                                                                  │
│  └─ cases/...                                                                            │
│                                                                                          │
│                         │ opaque argv/env/worker/budget/output plan                      │
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
│  ├─ circuit breakers                                                                     │
│  └─ finite runtime / budget enforcement                                                  │
│                                                                                          │
│                  │                                    │                                  │
│          DEFAULT / $0 PATH                     OPTIONAL REMOTE PATH                      │
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
│  NOTE: the new AFW→WLO local path is the forward path; the paid RPOF seam remains        │
│  retained/legacy until the new architecture proves the remote integration end-to-end.    │
│                                                                                          │
└─────────────────────────┬────────────────────────────────────────────────────────────────┘
                          │ executes
                          ▼

┌────────────────────────────── SCORING EXECUTION ─────────────────────────────────────────┐
│                                                                                          │
│                    afw-score-job adapter                                                 │
│                             │                                                            │
│                             ▼                                                            │
│                    af-cli-scoring-utility (AFSU)                                         │
│                                                                                          │
│  OWNS ONE ASSESSMENT                                                                     │
│  ├─ prompt construction                                                                  │
│  ├─ frozen dimension rubric/profile                                                      │
│  ├─ source submission                                                                    │
│  ├─ model invocation                                                                     │
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
