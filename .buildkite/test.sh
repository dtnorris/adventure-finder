#!/usr/bin/env bash

set -euo pipefail
unset BUNDLE_GEMFILE BUNDLE_LOCKFILE BUNDLE_PATH BUNDLE_FROZEN BUNDLE_DEPLOYMENT
export BUNDLE_IGNORE_CONFIG=1
ruby --version
bundle --version
source_commit="$(git rev-parse HEAD)"
results="$PWD/.ci-results"
mkdir -p "$results"
ci_root="$(mktemp -d /private/tmp/af-ci.XXXXXX)"
trap 'if [ -d "$ci_root/adventure-finder/coverage" ]; then cp -R "$ci_root/adventure-finder/coverage" "$results/coverage"; fi; rm -rf "$ci_root"' EXIT
export TMPDIR="$ci_root"
export GEM_HOME="$ci_root/gems"
export GEM_PATH="$GEM_HOME:$(ruby -e 'puts Gem.default_path.join(File::PATH_SEPARATOR)')"

git clone --no-hardlinks --no-checkout . "$ci_root/adventure-finder"
git -C "$ci_root/adventure-finder" checkout --detach "$source_commit"
git -C "$ci_root/adventure-finder" remote set-url origin git@github.com:dtnorris/adventure-finder.git

while read -r repository revision; do
  git clone --no-checkout "git@github.com:dtnorris/$repository.git" "$ci_root/$repository"
  git -C "$ci_root/$repository" checkout --detach "$revision"
done <<'COMPONENTS'
af-data-pipeline 7fa228c5b85b1a4a3e578a0be90c54e65e27c1e2
af-evidence d3b98b6a4820b2426da82f1001049f42074ab2d9
af-workloads-data 136f47d059351b7532acd953745328da8da8d0fc
workload-orchestrator fb069208e8f46ff2bf99e980c906aed5c0962be6
local-ollama-workers 74a9fbaa96191ab515147dbcd281fc86670b8409
af-cli-scoring-utility c1eba7d59796f1c6a5fb0bfb5a80d14d2c671aed
runpod-ollama-fleet adeae552b1a4f76c889f6c219cf72b98e2df6397
COMPONENTS

git clone --no-checkout https://github.com/dtnorris/af-workloads.git "$ci_root/af-workloads"
git -C "$ci_root/af-workloads" checkout --detach c9d67354880aa5d07b7b3b26969417e423d3f23b
git clone --no-checkout https://github.com/dtnorris/af-scorer.git "$ci_root/af-scorer"
git -C "$ci_root/af-scorer" checkout --detach fdd620850b24a5b801eb68391ca3e98c22d4b28a
git clone --no-checkout https://github.com/dtnorris/af-specification-md.git "$ci_root/af-specification-md"
git -C "$ci_root/af-specification-md" checkout --detach 394a44c2c2052ce2eeb6d28cd7647ad8a50acfcf
export AF_PUBLIC_SPEC_ROOT="$ci_root/af-specification-md"
git clone --no-checkout https://github.com/dtnorris/af-xlsx-files.git "$ci_root/af-xlsx-files"
git -C "$ci_root/af-xlsx-files" checkout --detach 425f0d66ca8bac7636f3f54845448d9d55b0129c
git clone --no-checkout https://github.com/dtnorris/af-source-md.git "$ci_root/af-source-md"
git -C "$ci_root/af-source-md" checkout --detach a44019961e822b19a727e3562c2ecda4cfe0a7bd
export AF_XLSX_FILES_ROOT="$ci_root/af-xlsx-files" AF_SOURCE_MD_ROOT="$ci_root/af-source-md"

platform="$(ruby -e 'puts Gem::Platform.local')"
for repository in adventure-finder af-data-pipeline af-evidence af-workloads-data af-scorer workload-orchestrator local-ollama-workers af-cli-scoring-utility runpod-ollama-fleet; do
  cd "$ci_root/$repository"
  git rev-parse HEAD
  if [ "$repository" != af-scorer ]; then
    cp Gemfile.lock Gemfile.lock.ci-original
    BUNDLE_FROZEN=false bundle lock --add-platform "$platform"
    ruby -rbundler -e 'v = ARGV.map { |p| Bundler::LockfileParser.new(File.read(p)).specs.map { |s| [s.name, s.version.to_s] }.uniq.sort }; abort "Dependency versions changed" unless v[0] == v[1]' Gemfile.lock.ci-original Gemfile.lock
  fi
  BUNDLE_FROZEN=true bundle install
done

cd "$ci_root/adventure-finder"
export AF_PROJECT_ROOT="$ci_root"
export AF_DATA_PIPELINE_ROOT="$ci_root/af-data-pipeline"
export AF_AFW_SOURCE_ROOT="$ci_root/af-workloads"
export AF_AFW_ROOT="$ci_root/af-workloads"
export AF_TEST_HISTORICAL_AFW_ROOT="$ci_root/af-workloads-data"
export WLO_REPO_ROOT="$ci_root/workload-orchestrator"
export LOW_REPO_ROOT="$ci_root/local-ollama-workers"
export AF_SCORER_ROOT="$ci_root/af-cli-scoring-utility"
export RPOF_REPO_ROOT="$ci_root/runpod-ollama-fleet"
unset RUNPOD_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY GOOGLE_API_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
unset AF_STATE_ROOT AF_DATA_PIPELINE_DATA_ROOT AF_AFW_DATA_ROOT AFW_DATA_ROOT
export RUBYOPT="-r$PWD/test/support/offline_network_guard.rb"
export BUNDLE_FROZEN=true
# Historical cases use their separately pinned donor. The split proof uses the
# public owner and its own scorer and disposable store.
bundle exec rake TESTOPTS='--exclude=/StagedConfigurationTest/' 2>&1 | tee "$results/full-suite.log"
unset AF_TEST_HISTORICAL_AFW_ROOT
export AF_TEST_PUBLIC_AFW_ROOT="$AF_AFW_ROOT" AF_SCORER_ROOT="$ci_root/af-scorer" AF_TEST_SPEC_ROOT="$AF_PUBLIC_SPEC_ROOT"
export AF_TEST_EVIDENCE_ROOT="$results/public-workload"
bundle exec ruby -r "$PWD/test/support/subprocess_environment" -Ilib:test test/integration/bug02c_boundary_continuation_test.rb 2>&1 | tee "$results/public-front-door.log"
bundle exec ruby -r "$PWD/test/support/subprocess_environment" -Ilib:test test/integration/staged_configuration_test.rb 2>&1 | tee "$results/public-workload.log"
