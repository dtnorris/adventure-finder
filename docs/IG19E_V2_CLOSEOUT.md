# IG-19E — V2 ingestion closeout evidence (2026-10-17)

**Status:** Clean-local synthetic three-decision ingestion journey **PASS**. Full IG-19E
closeout **not yet certified** while front-door documentation remains unintegrated
and the remaining cross-owner wording is unresolved. The 21 AdventureFinder default-suite
skips are disclosed; determine whether they affect required acceptance before
asking for another run. This document is evidence, not ACT lifecycle authority
or production scoring approval.

## Operator-visible clean-local outcome

The existing synthetic, offline public-entry journey
`acceptance/bug02c_continuous_journey.rb` finished in **114.3 s** (exit 0) at
AdventureFinder `8ea6fe8abdcc71b17abac9ccc9fc7ed11b850898`. Exactly **11 WLO
jobs** completed on their first attempt, with **11 AFW evidence receipts** and no
failed/pending jobs. The pipeline's standing authority finalized **6 eligible metrics**;
**5 cases** remained deferred/unsupported. There were zero individual human
acceptances and zero IG-16B machine acceptances. The staged and scored successors
had distinct paths and hashes. The final package was ready for explicit approval,
and approval promoted only `catalog_head`. Exact preapproval and postpromotion
replays passed, with fixture Git index/refs/objects unchanged.

**Human decision episodes: 3** — (1) source, base and staged-scoring intent at
start; (2) boundary editorial review/approval, including successor-version
intent; (3) exact final package approval. No mandatory per-score decision,
intermediate staged-catalog adoption, manual workload step, or red-cell preview
was observed on this clean path. Git commit/push remains an optional separate
operator persistence action, not an automatic side effect. **Provider/inference
calls and additional paid cost were $0** in this fixture run.

## Exact tested head set

| Owner | Composed evidence head | Notes |
| --- | --- | --- |
| adventure-finder | `8ea6fe8abdcc71b17abac9ccc9fc7ed11b850898` | Complete journey, matrices, restart/promotion, default suite |
| af-data-pipeline | `fceffd6fa5b29ff28d234475f59193c9b393fcd3` | Runtime-tested; documentation-only F3 advanced to `fdeb83e3832eb52f2432e5987ddb6f9efcb3b665` afterward |
| af-workloads | `0e988210860e95ae9810f64924795f405e1d54f7` | Native default suite passed after fixture environment isolation |
| workload-orchestrator | `78afbcdb5635242ff5b8fc1dab7e7742b2b588ec` | Native default suite passed with canonical macOS TMPDIR |
| local-ollama-workers | `7a169b788fcff0d6fa4c2a41fe6349abb23b703e` | Native default suite passed |
| af-cli-scoring-utility | `c1eba7d59796f1c6a5fb0bfb5a80d14d2c671aed` | Native default suite passed |

Other inspected supporting refs: af-xlsx-data-sources
`b4e4b45f24b1da819dcc76cce618b4015ddfb3df` and optional RPOF
`8ae771fef266668816231209f4ac326fadfe4bda` (offline fixture only).
These are reported identities, not permission to use paid infrastructure.

## Composed acceptance and regression outcomes

| Gate | Observed result | Verdict |
| --- | --- | --- |
| Continuous public-entry V2 journey | 11/11 jobs, 11 receipts, 6 standing accepted, 5 deferred, 3 decisions, verified promotion/replay, 114.3 s | PASS |
| IG-19A/B/C/D composed matrices (`acceptance/ig19d_validation.rb matrices`) | 11 tests, 820 assertions, 0 failures/errors/skips, 72.6 s wrapper | PASS |
| IG-19D dedicated restart/promotion (`focused`) | 5 tests, 274 assertions, 0 failures/errors/skips, 17.0 s | PASS |
| AFDP default offline suite | 525 tests, 4,648 assertions, 0 failures/errors/skips, 36.5 s | PASS at `fceffd6f` |
| AFW default offline suite | 254 tests, 4,820 assertions, 0 failures/errors/skips, 13.5 s test duration | PASS (sanitized fixture environment) |
| WLO default offline suite | 438 tests, 3,994 assertions, 0 failures/errors/skips, 11.6 s test duration | PASS (canonical TMPDIR) |
| LOW default offline suite | Exit 0; native tests and 17-file test lint/18-file production lint green; exact test count not retained in supplied tail | PASS, total not reported |
| Scorer default offline suite | 319 tests, 2,440 assertions, 0 failures/errors/skips, 0.97 s | PASS |
| AdventureFinder default offline suite | 454 tests, 6,555 assertions, 0 failures/errors, **21 skips**, 135.3 s; 83.45% line/62.09% branch coverage | PASS with skips **not yet classified** |

The first AFW wrapper run failed because injected AFW/scorer/pipeline environment roots
overrode a test-specific fixture; a second run with a guard outside AFW failed a
physical-boundary assertion. A sanitized guarded disposable AFW checkout passed.
WLO's first wrapper run failed 21 test setups because `/var` is a symlink to
`/private/var` and WLO correctly requires real paths. A canonical TMPDIR
produced a green full run without changing WLO validators. These were **class A
fixture/environment issues**, not reproduced V2 product defects; the original
all-component wrapper commands are **not** claimed green.

AdventureFinder's 21 conditional skips have not been independently mapped to
individual tests/reasons in the supplied output; **no skipped behavior is
claimed tested**. If a skipped test covers a mandatory IG-19E invariant, that
gate must be rechecked before full closeout. Other runtime/coverage differences
between F1 and the later run are not treated as directly comparable.

## Optional branches, limitations, and scope

**Optional residual-frontier path:** F1 landed the synthetic public-component
seam (`test/integration/frontier_continuation_pipeline_seam_test.rb`) covering
explicit `FRONTIER` deferral, real AFDP prepare/apply/verify with synthetic
source-referenced return, a separate derived package, refusal to reuse original
approval, one fresh approval, invalid-return refusal, decline, and no chaining.
The F1 focused test report states 31 tests/481 assertions with zero skips.
The front door does **not** create or route the optional request automatically:
operators must explicitly prepare the AFDP v0.2 component-tool packet and
structured return. No actual frontier-model output, autonomous routing or paid
inference was tested. This is a **separate optional path**, not an additional
mandatory decision on the clean-local journey.

**IG-16B:** Standing-directive acceptance is not human editorial acceptance or
machine-quality adjudication. IG-16B machine-policy acceptance remains unavailable
without the exact qualifying IG-12B evaluation and explicit application authority.
Zero such acceptances were asserted throughout this journey.

**Other deliberate limits:** source registration and ambiguous segment identity
may need editorial intervention; page-envelope exclusions, unsupported dimensions,
missing/stale LOW capability, incomplete WLO attempts, hard evidence conflicts,
source HOLD/REJECT and unavailable remote capacity remain fail-closed. A validated
terminal gap is not permission to treat an unfinished execution as complete.
RPOF is an independent, optional, paid-capacity path; no remote provisioning or
unbounded paid resource is covered or authorized here.

## Documentation and final disposition

AFDP's canonical V2 standing-versus-manual documentation landed on `main` in
`fdeb83e3832eb52f2432e5987ddb6f9efcb3b665` (F3 COMPLETE). AdventureFinder
front-door wording corrections accompany this report; these are documentation
changes only. AFW `docs/operator-runbook.md`, "Bind scoring evidence" (near the
`prepare-review` handoff), still presents the manual review route without
explicitly qualifying it against V2 standing ingestion. **Owner: AFW**; exact
cross-owner documentation disposition remains open. It must not be silently
counted as resolved by this AdventureFinder-only patch.

The public clean-local operator north star is **met for deterministic synthetic
offline mechanics**: 3 decisions, no repeated mandatory operator information,
no automatic Git persistence, no paid inference. That finding says nothing
about real book-conversion quality, model-scored semantic accuracy, personal
library authorization, autonomous remote provisioning or frontier quality.
**Overall IG-19E COMPLETE is not asserted by this report** until the remaining
documentation owner discrepancy has been disposed of, the front-door patch is
integrated, and operator/ACT acceptance is recorded. Review skip applicability
only where a skipped test is the sole evidence for a mandatory requirement. No repository publication or
ACT state transition is part of this candidate.
