# Workspace policy

The `adventure-finder` repository is an orchestration and documentation layer over
independent component repositories under a separate non-Git container.

It is deliberately **not**:

- the canonical home of AMC data;
- the canonical home of AdventureFinder specifications;
- the canonical source corpus;
- the scoring or matching implementation;
- an evidence archive;
- a Git submodule superproject;
- a package manager; or
- a replacement for repository-local tests.

## Authority

The workspace may document where authority lives and verify that local copies are
present, but it must not silently create a second authority.

In particular:

- `af-xlsx-files-data/PROJECT_STATE.yml` owns moving AMC role state.
- `md-specification-files` owns accepted semantic specifications.
- `af-source-md-data` owns the private canonical Markdown corpus and source registry.
- Individual implementation repositories own their code and local test suites.

Generated workspace snapshots are reproducibility aids only. They do not advance or
redefine any AdventureFinder authority.

## Git safety

`af-sync`:

1. runs `git fetch --prune`;
2. checks the worktree;
3. skips pull when dirty;
4. skips pull on detached HEAD;
5. skips pull when no upstream exists; and
6. otherwise uses `git pull --ff-only`.

It never resets, stashes, commits, merges, rebases, force-updates, or pushes.

## Clone policy

Normal bootstrap includes the current/default repositories from `repos.yml`.

Bootstrap clones public `dtnorris/af-pipeline` over HTTPS into `af-pipeline`
and selects the manifest's exact revision. Its setup uses the public pipeline's
`bin/setup` with the public owner roots and pins listed in
`af-pipeline/config/public_owners.tsv`. Prepare those owner checkouts and export
their selectors before running bootstrap with `--setup`. The workspace suite
dispatcher retains the logical key `af-data-pipeline` for pipeline code.
Private `dtnorris/af-pipeline-data` uses the retained local `af-data-pipeline`
path with no code setup or test role. For a retained checkout, the operator
updates its fetch and push origins after verifying repository identity.

For historical operator acceptance scenarios that require donor code, set
`AF_DATA_PIPELINE_ROOT` to the disposable checkout of the historical pin.
The public split-pipeline test in CI uses the catalog front door and
independently allocated synthetic stores.

`llm-response-data` is intentionally shallow-cloned (`--depth 1`) because its Git
history is large and normal AdventureFinder work generally needs the current evidence
tree, not every historical object. Unshallow it only when the question actually requires
Git-history traversal.

Archived and experimental repositories are documented but opt-in through `--all`.

## Filesystem contract

The normal and intended production front doors stay at
`/Users/davidnorris/code/adventure-finder` and
`/Users/davidnorris/code/adventure-finder-production`. `AF_PROJECT_ROOT` selects
`/Users/davidnorris/code/adventure-finder-components`; both normal and retained
production components use that same parent. `--all` includes project-adjacent
repositories from the front-door parent, or explicit `--adjacent-root` /
`AF_ADJACENT_ROOT`, without placing them in the component workspace.

Paths do not authorize relocation. Preserve frozen production identities, ignored
state and guardian authority through the FS-04/FS-05 migration prerequisites.
