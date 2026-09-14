# AdventureFinder Work Fast-Path Prompting Playbook v0.1

Purpose: make ChatGPT Work tasks finish quickly, stay inside scope, and hand back small, reviewable patches instead of turning environment gaps into architecture or setup projects.

Use this file as a reusable prompt-writing source for AdventureFinder refactors, repo maintenance, narrow migrations, and other patch-oriented Work tasks.

## 1. Default operating rule

For narrow Work tasks, the primary deliverable is the requested patch or artifact.

Work-side testing is opportunistic, not mandatory.

If Work's cloud environment is missing a repository, toolchain, package, runtime, private dependency, fixture tree, or system utility:

> **Environment gaps are validation items to defer, not problems to solve.**

Do not install, reconstruct, synthesize, bootstrap, or recreate missing tooling or repositories unless the task explicitly requires it.

The authoritative validation environment is usually David's local Mac, where the full AdventureFinder workspace exists.

## 2. Fast-path task shape

A good fast-path Work prompt should explicitly provide:

1. Exact repositories allowed to change
2. Expected starting SHAs
3. Exact files or narrow surfaces likely to change
4. Pre-classified live vs historical references
5. Explicit out-of-scope repositories and concepts
6. Minimal valid tests
7. Patch names and delivery format
8. Stop condition

Do not ask Work to rediscover architecture already known from prior steps.

## 3. Mandatory anti-scope-creep language

Include this block, or equivalent language, in narrow tasks:

> This is a narrow patch task, not an architecture investigation.
>
> Do not broaden the task.
>
> Do not inspect unrelated repositories unless a changed file explicitly requires it.
>
> Do not reconstruct missing repositories, modules, fixtures, CLIs, tests, or project infrastructure.
>
> Do not install or bootstrap missing runtimes, package managers, gems, Python environments, system tools, or other toolchains merely to run tests.
>
> If a requested validation cannot run in the existing Work environment, record it as deferred to my local Mac and continue to patch generation.
>
> Patch generation is the primary deliverable; Work-side testing is opportunistic.
>
> Once the requested edits, available validation, `git diff --check`, and patch generation are complete, stop immediately and return the handoff.

## 4. Environment-gap rule

Use this exact rule when private repos or toolchains may be unavailable:

> **Environment gaps are not problems to solve.**
>
> If an intact required repository cannot be cloned, use exact GitHub file contents at the verified commit only for the named edits. Do not synthesize a partial project to imitate a checkout.
>
> If the normal test suite cannot run without additional environment construction, do not construct that environment. Run only tests that are already valid, then defer the authoritative suite to my Mac.

This is especially important for private GitHub repositories, Ruby/Bundler availability, Python virtualenvs, Homebrew/system utilities, large fixture trees, model runtimes, and paid cloud infrastructure.

## 5. Validation hierarchy

### Tier 1 — always do if possible
- verify exact starting SHA
- inspect only named files
- `git diff --check`
- `git status --short`
- targeted grep/audit for the migration seam
- `git apply --check` against a fresh clone/checkpoint
- syntax/static checks that require no setup

### Tier 2 — run when the intact repo and runtime already exist
- focused affected tests
- repository-local deterministic suite

### Tier 3 — usually defer to David's Mac
- full AdventureFinder cross-repo workspace gate
- `af-doctor --strict`
- tests requiring private sibling repos
- tests requiring environment setup not already present
- tests requiring Homebrew/system prerequisites
- real inference

### Never as a debugging technique unless explicitly requested
- paid APIs
- RunPod/provider resources
- hosted inference
- rented compute

## 6. Time discipline

For a narrow rename/refactor patch, Work should not spend substantial time on discovery after the scope has been pre-classified.

Add:

> Do no further research after the named files are understood.
>
> Do not optimize for maximum validation coverage inside Work.
>
> Optimize for a correct, minimal patch that can be authoritatively validated locally.
>
> If a validation prerequisite is missing, defer it rather than spending time repairing the environment.

Useful completion trigger:

> When the requested files are edited, `git diff --check` is clean, the targeted stale-reference audit has zero live failures, and the patches are generated, return immediately.

## 7. Pre-classify references before Work

Recommended categories:
- `LIVE_CURRENT_REFERENCE` — must change
- `CURRENT_DOCUMENTATION` — must change
- `FROZEN_HISTORICAL_PROVENANCE` — leave unchanged
- `COMPATIBILITY_IDENTIFIER` — intentionally preserve
- `STALE_LIVE_REFERENCE` — must be zero after migration

Then tell Work:

> This classification is authoritative for the task. Do not repeat a broad discovery phase.

## 8. Patch-first delivery contract

For multi-repo work:

> Do not commit or push.
>
> Produce exactly one root-relative patch per changed repository.
>
> Each patch must pass `git apply --check` against the inspected starting commit.
>
> Do not combine multiple repository roots into one patch.
>
> Report the exact starting SHA, changed files, available tests, deferred tests, `git diff --check`, and remaining intentional legacy references.

Preferred naming:

```text
<repo>-<step>-<purpose>.patch
```

## 9. Distinguish “do not change” from “out of scope”

### Do not change
Names/files/interfaces that must remain intact because they are compatibility or frozen contract surfaces.

Example:
```text
LocalModelEvaluation
bin/lme
LME_*
historical evidence paths
frozen split contracts
```

### Out of scope
Neighboring repositories or workstreams Work should not inspect or modify at all.

## 10. Red-flag activity to interrupt immediately

Interrupt if Work starts:
- creating unrelated modules
- rebuilding a missing repo from GitHub files
- creating replacement Gemfiles or project configs
- installing Ruby/Bundler/Python/Homebrew tooling just for validation
- reviewing large unrelated architecture/spec trees
- “improving” historical docs
- running full workspace tests when told not to
- chasing unrelated warnings
- designing a more general abstraction
- broad cleanup after reference classification is already frozen

## 11. Standard intervention prompts

### Scope correction
> Stop the reconstruction/discovery work immediately. The scope is already frozen. Touch only the explicitly named files and produce the requested patch. Do not create or recreate unrelated modules, CLIs, fixtures, tests, or project infrastructure.

### Environment correction
> Do not install or reconstruct toolchains in Work. If the requested tests cannot run in the existing environment, record them as deferred to my Mac. Continue with `git diff --check`, targeted audit, patch generation, and handoff.

### Hurry-up / completion
> Scope is already frozen. Do not do further discovery. Finish only the specified repo patches, run only validation that is already available without setup, generate the downloadable patches, and return the handoff now. Do not broaden the task.

### Patch contamination check
> Before returning, show the changed-file list for each patch. If any file is outside the enumerated scope, stop and remove that change unless it is strictly necessary and explicitly justified.

## 12. Reusable fast-path prompt skeleton

```text
# <Project> — <Task> FAST PATH

This is a narrow patch task, not an architecture investigation.

## Repositories allowed to change
<repo 1>
<repo 2>

Expected starting SHAs:
<repo 1>: <sha>
<repo 2>: <sha>

If a required repo/commit is unavailable, STOP or defer that repo. Do not reconstruct it.

## Goal
<one-paragraph exact goal>

## Pre-classified scope

CHANGE:
- <file/surface>

LEAVE HISTORICAL:
- <file/surface>

PRESERVE COMPATIBILITY:
- <identifier>

OUT OF SCOPE:
- <repo/concept>

This classification is authoritative. Do not repeat broad discovery.

## Environment rule

Environment gaps are validation items to defer, not problems to solve.

Do not install, reconstruct, synthesize, or bootstrap missing repos/toolchains merely to run tests.

Patch generation is the primary deliverable; Work-side testing is opportunistic.

## Required edits
<exact edit 1>
<exact edit 2>

## Validation

Always:
- verify SHA
- targeted grep/audit
- git diff --check
- patch apply-check

Run focused/full repo tests only if the intact checkout and required runtime already exist.

Otherwise explicitly defer those tests to my Mac.

Do not run the full cross-repo workspace gate in Work unless explicitly requested.

## Delivery

Do not commit or push.

Produce one root-relative patch per changed repo.

Return:
- starting SHA
- changed files
- tests actually run
- validations deferred
- diff-check result
- remaining intentional legacy refs
- patch links
- exact local apply commands

Once these are complete, stop. Do not perform additional research.
```

## 13. AdventureFinder-specific defaults

Unless the task says otherwise:
- David's Mac is the authoritative full-workspace validation environment.
- Full `bin/af-workspace test` and `bin/af-workspace doctor --strict` should usually run locally after patches are applied.
- Work should not contact RunPod or paid APIs for refactor validation.
- Frozen architecture/spec contracts are not rewritten during implementation migrations unless the task explicitly versions the contract.
- Historical evidence names are provenance, not cleanup targets.
- One root-relative patch per repository.
- No auto-commit/push.

## 14. North-star test for whether Work should do more

Before allowing Work to broaden a task, ask:

> Will this extra work materially improve the requested AdventureFinder artifact or confidence in this specific patch, beyond what David's local validation can provide more cheaply?

If not, defer or skip it.

The objective is information gained per unit of time and cost, not maximal activity inside Work.
