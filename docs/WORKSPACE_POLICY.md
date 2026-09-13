# Workspace policy

The `adventure-finder` repository is an orchestration and documentation layer over
independent sibling repositories.

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

- `af-xlsx-data-sources/PROJECT_STATE.yml` owns moving AMC role state.
- `md-specification-files` owns accepted semantic specifications.
- `md-for-llm-book-content` owns the private canonical Markdown corpus and source registry.
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

`llm-response-data` is intentionally shallow-cloned (`--depth 1`) because its Git
history is large and normal AdventureFinder work generally needs the current evidence
tree, not every historical object. Unshallow it only when the question actually requires
Git-history traversal.

Archived and experimental repositories are documented but opt-in through `--all`.
