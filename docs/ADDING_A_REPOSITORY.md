# Adding a repository to the workspace

`repos.yml` is the only repository inventory used by the workspace commands.

Add a repository when it has a real AdventureFinder responsibility or is worth retaining
as explicit historical/experimental context. Do not add an unrelated repository merely
because it happens to live under the same GitHub account.

Required fields:

```yaml
- name: repository-directory-name
  github: owner/repository-name
  role: One-sentence ownership statement.
  groups: [code]
  lifecycle: current
  visibility: private
  default: true
```

Optional fields:

```yaml
setup: bin/setup
test: bundle exec rake test
requires: [ruby, bundle, git]
optional_runtime_requires: [python3]
clone_depth: 1
notes:
  - Important operational caveat.
```

Prefer a repository-owned, idempotent `bin/setup` when setup is more than a single
package-manager command. Mixed-runtime repositories should create their Python virtual
environment inside that repository (normally `.venv`) and must not install Python
packages globally. The workspace only dispatches the declared setup command; the
component remains authoritative for how its dependencies are installed.

## Lifecycle

- `current`: participates in the current architecture.
- `experimental`: useful spike or experiment that is not a current dependency.
- `archived`: retained for reproducibility after its responsibility moved elsewhere.

Normal commands include only entries with `default: true`. `--all` includes every
manifest entry. `--core` selects entries tagged `core`.

## Test ownership

Cross-repo orchestration invokes each repository's own test command. Tests for a
repository's internal behavior stay in that repository.

Only genuinely cross-repository contracts belong in this umbrella repository. A future
cross-repo contract test should name the exact producer/consumer contract it verifies,
avoid LLM inference, and fail closed when an authority artifact is missing or ambiguous.

## Safety

Do not put secrets, API keys, private endpoint URLs, copyrighted source prose, generated
frontier bundles, or canonical AMC copies in this repository.

The workspace should point to authoritative sibling repositories rather than duplicating
their truth.
