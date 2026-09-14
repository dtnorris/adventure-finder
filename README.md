# AdventureFinder

The **workspace/front-door repository** for the AdventureFinder polyrepo project.

AdventureFinder's north star is to build the best possible artifact for David +
frontier ChatGPT to reason about and explore David's TTRPG adventure library. This
repository does not own that artifact's canonical truth. It makes the repositories
that *do* own it easier to understand, clone, inspect, synchronize, test, and reproduce.

## What this repository owns

Only cross-repository concerns:

- the map of AdventureFinder repositories and their responsibilities;
- safe multi-repo bootstrap/status/sync/test commands;
- lightweight environment/integrity checks;
- optional workspace commit snapshots; and
- future tests for genuinely cross-repository contracts.

It deliberately contains **no copied AMC workbook, book corpus, scoring semantics,
matching semantics, or model evidence**.

## Quick start

Assuming AdventureFinder repositories live under `/Users/davidnorris/code`:

```bash
cd /Users/davidnorris/code
git clone git@github.com:dtnorris/adventure-finder.git
cd adventure-finder

bin/af-doctor
bin/af-bootstrap
bin/af-status
bin/af-test
```

For a brand-new machine, clone and run each repository's lightweight setup command:

```bash
bin/af-bootstrap --setup
bin/af-doctor
bin/af-test
```

`--setup` delegates dependency installation to each repository's own setup command.
For mixed Ruby/Python converters, that includes creating or reusing a repository-local
`.venv` and installing the component-owned Python dependencies there. It intentionally
does **not** install Homebrew/system packages, download model assets, create cloud
resources, or run inference.

If HTTPS cloning is preferred:

```bash
AF_GIT_PROTOCOL=https bin/af-bootstrap
```

Override the normal workspace root:

```bash
AF_PROJECT_ROOT=/another/path bin/af-status
```

## Commands

### `bin/af-bootstrap`

Clone missing repositories into the workspace root.

Normal bootstrap includes current repositories marked `default: true` in `repos.yml`.
It does not modify repositories that are already present.

```bash
bin/af-bootstrap
bin/af-bootstrap --setup
bin/af-bootstrap --core
bin/af-bootstrap --all
```

The large `llm-response-data` evidence repository is shallow-cloned by default.
If a task truly needs its Git history:

```bash
cd /Users/davidnorris/code/llm-response-data
git fetch --unshallow
```

### `bin/af-status`

One cross-repo view of local state:

```bash
bin/af-status
```

It reports presence, lifecycle, branch, clean/dirty state, local ahead/behind counts
when an upstream is configured, and HEAD SHA. It does not fetch.

### `bin/af-sync`

Safely update current checkouts:

```bash
bin/af-sync
```

For each checkout it runs `git fetch --prune`. It only runs `git pull --ff-only`
when the worktree is clean, HEAD is attached to a branch, and an upstream exists.

It **never** resets, stashes, commits, merges, rebases, force-updates, or pushes.

### `bin/af-test`

Run the repository-owned test suite for each current/default code repository:

```bash
bin/af-test
```

Cross-repository commands deliberately run in a **non-login shell** so they inherit the
operator's active PATH (for example mise/asdf/Homebrew Ruby) instead of silently falling
back to macOS system Ruby. Converter test commands additionally prepend their own
`.venv/bin` when present so repo-local Python dependencies remain repo-local.

The default is sequential execution so failures remain easy to attribute and local
resource use stays modest. Use:

```bash
bin/af-test --fail-fast
```

when the first failure is sufficient evidence to stop.

Archived and experimental suites are intentionally excluded unless requested:

```bash
bin/af-test --all
```

### `bin/af-doctor`

Check the local workspace and important authorities:

```bash
bin/af-doctor
```

It checks required commands (including the resolved executable path and useful runtime
versions), reports missing runtime-specific commands, checks expected repository
checkouts, verifies the canonical source registry exists, and—when
`af-xlsx-data-sources` is present—reads the *live* `PROJECT_STATE.yml`, resolves
`catalog_head`, and verifies that workbook's byte size and SHA-256.

That last behavior is intentional: **never infer "the current AMC" from the numerically
largest filename or from a version copied into this README.**

Use strict mode when you want warnings (including optional converter dependencies) to
make the command fail:

```bash
bin/af-doctor --strict
```

### `bin/af-snapshot`

Record exact sibling-repository commits:

```bash
bin/af-snapshot
```

This writes a YAML record under `snapshots/` containing each present repository's exact
HEAD, branch, and dirty flag. Snapshots are gitignored by default: attach one to an
experiment or copy it into a durable evidence package only when it adds reproducibility
value.

A snapshot is **not** canonical project state and never replaces `PROJECT_STATE.yml`.

## Repository map

The machine-readable source of truth for this table is [`repos.yml`](repos.yml).

| Repository | Lifecycle | Responsibility |
| --- | --- | --- |
| `md-specification-files` | current | Normative AdventureFinder specifications and semantic contracts |
| `af-xlsx-data-sources` | current | Canonical AMC workbooks plus `PROJECT_STATE.yml` |
| `md-for-llm-book-content` | current/private | Canonical page-addressable source corpus plus `source_registry.yml` |
| `af-data-pipeline` | current | Deterministic ingestion handoffs, AMC mutation, review, and finalization |
| `af-cli-scoring-utility` | current | Source-grounded AFAO assessment/scoring evidence |
| `af-inference-orchestrator` | current | AFIO local/remote inference and scoring orchestration |
| `af-frontier-pack` | current | Deterministic frontier-model consumption bridge |
| `af-cli-query-matcher` | current/supporting | AFPS parsing and deterministic filtering/ranking |
| `pdf-to-llm-md-converter` | current | PDF → page-addressable Markdown |
| `image-to-pdf-converter` | current | Physical-book photos → normalized image-only PDF |
| `llm-response-data` | current/evidence | Historical/raw evidence archive; not authority |
| `5e-tools-corpus-converter` | experimental | Earlier local-5e.tools corpus-conversion spike |
| `af-corpus-ingester-basics` | archived | Superseded candidate-ingestion prototype |
| `af-matcher-cli` | archived | Completed direct-LLM recommendation experiment |

## Architecture

```text
owned published sources
        |
        +----------------------------+
        |                            |
        | PDF / born-digital         | photographed physical pages
        |                            |
        |                            v
        |                   image-to-pdf-converter
        |                            |
        +-------------+--------------+
                      |
                      v
            pdf-to-llm-md-converter
                      |
                      v
          md-for-llm-book-content
         (canonical Markdown corpus
          + source_registry.yml)
                      |
                      v
              af-data-pipeline
       deterministic intake / dossier
                      |
                      v
        David + frontier-model review
                      |
                      v
              af-data-pipeline
       frozen boundary -> successor AMC
                      |
                      v
             af-xlsx-data-sources
        (canonical AMC + PROJECT_STATE)
                 /            \
                v              v
 af-cli-scoring-utility    af-frontier-pack
          |                     |
          v                     v
af-inference-orchestrator frontier reasoning
          |
          v
   llm-response-data
   (evidence archive)
          |
          v
    af-data-pipeline
   review / acceptance
          |
          +-----------------------> canonical AMC

Supporting deterministic selection path:

natural-language request
        |
        v
af-cli-query-matcher
        |
        v
validated AFPS -> deterministic match/rank
```

This diagram describes responsibility and data flow, not Git dependency ownership.

## Authority and trust boundaries

AdventureFinder intentionally separates several kinds of truth.

**Specifications.** `md-specification-files` is the normative home of accepted
AdventureFinder semantics. Implementation repositories automate those contracts; they
do not silently redefine them.

**Catalog state.** `af-xlsx-data-sources/PROJECT_STATE.yml` is the authority for moving
roles such as `catalog_head`, `matcher_authorized_baseline`, and
`production_dependency_floor`. A frozen operation may intentionally retain an older
exact artifact.

**Source corpus.** `md-for-llm-book-content` is the private canonical Markdown corpus
and source-resolution authority. It contains copyrighted owned source material and must
remain private.

**Evidence.** `llm-response-data` preserves historical/raw evidence. Its filenames and
directory dates are not project-state authority.

**Generated frontier packs.** `af-frontier-pack` produces disposable derivatives for
reasoning. Those packs own no canonical truth.

## Why polyrepo rather than a monorepo or submodules?

The existing repositories have genuinely different responsibilities and lifecycles:
canonical data, private source material, specifications, deterministic pipeline code,
model orchestration, evidence, matching, and frontier consumption.

The workspace therefore coordinates them **without moving their contents**.

Git submodules are intentionally avoided. Day-to-day AdventureFinder work frequently
moves independent repositories forward, and submodule pointer churn would add another
state-management layer without improving the canonical data model. When an exact
cross-repo state matters, `bin/af-snapshot` records the commit set explicitly.

## Repository selection

Normal commands use entries with:

```yaml
default: true
```

Use `--core` for only the repositories tagged `core`, or `--all` to include retained
experimental/archived repositories.

The distinction matters: an old experiment should be easy to discover without being
accidentally treated as a current production dependency.

## Adding or changing a repository

See [`docs/ADDING_A_REPOSITORY.md`](docs/ADDING_A_REPOSITORY.md).

The important rule is simple: `repos.yml` documents ownership and orchestration. It
must not become another place where canonical AdventureFinder facts are manually
duplicated.

## Developing this workspace repo

The workspace CLI itself has no third-party runtime dependency beyond Ruby and Git.

Run its self-tests:

```bash
bin/test
```

or, when Rake is available:

```bash
rake test
```

The GitHub workflow tests only this repository's own orchestration code and manifest.
It does not attempt to clone private sibling repositories in CI.
