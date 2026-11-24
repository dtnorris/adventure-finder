# Build and use a private Frontier pack

Use this route to read an existing accepted catalog alongside a separately selected
source library. The [Frontier Pack README](https://github.com/dtnorris/af-frontier-pack/blob/9af7921d2570f79d6f2146d900bedd396f14e5d3/README.md)
owns the build and reader contracts. The sequence below pins the public code and
ontology used together and leaves the workspace bootstrap and installed defaults
available for other workflows.

On a private host, have Git, Bash, Ruby 3.2 or newer with RubyGems, `unzip`, and
`shasum` on a trusted `PATH`, with HTTPS access to GitHub and RubyGems. Supply five
arguments with absolute paths for the first four:

1. An existing private directory in which to create a fresh workspace and pack.
2. The selected v0.2 `PROJECT_STATE.yml`, with its referenced workbooks available
   at the paths the state declares. Its `catalog_head` selects the accepted
   workbook. Frontier verifies the workbook pins for all three catalog roles.
3. The exact v0.1 source registry for the selected library.
4. The corresponding Markdown corpus root. Registry mappings resolve relative
   to this root.
5. An adventure ID from the accepted catalog with a source you own.

Keep the catalog and source inputs read-only and stable during the run. The fresh
workspace receives its own pack, receipts and source excerpt. The example uses
the public AdventureFinder revision shown below. Pass a sixth argument to record a
different exact published AdventureFinder revision, such as the one containing
this guide. Reuse the same revision and selected inputs for a repeat run.

Save the following Bash block locally as `private-frontier-pack.sh` and run it
on the private host with a clean environment:

```sh
env -i PATH="$PATH" /bin/bash /path/to/private-frontier-pack.sh \
  /private/runs /private/catalog/PROJECT_STATE.yml \
  /private/library/source_registry.yml /private/library ADV-XXXX
```

```bash
set -euo pipefail
umask 077
if [[ $# -lt 5 || $# -gt 6 || $1 != /* || $2 != /* || $3 != /* || $4 != /* ]]; then
  echo 'Usage: private-frontier-pack.sh /private/runs /catalog/PROJECT_STATE.yml /library/registry.yml /library/corpus ADV-ID [front-door-sha]' >&2
  exit 2
fi
catalog_state=$2
registry=$3
corpus=$4
adventure_id=$5
front_door_revision=${6:-d3f83f5692be60307571268d6d553160a1d35fe6}
[[ $front_door_revision =~ ^[0-9a-f]{40}$ ]]
[[ -r $catalog_state && -f $catalog_state && -r $registry && -f $registry && -d $corpus ]]
command -v git ruby unzip shasum >/dev/null
ruby -rrubygems -e 'abort "Ruby 3.2 or newer is required" if Gem::Version.new(RUBY_VERSION) < Gem::Version.new("3.2")'

run=$(mktemp -d "${1%/}/frontier.XXXXXX")
cd "$run"
run=$(pwd -P)
printf 'Private run and logs: %s\n' "$run"
exec > "$run/witness.log" 2>&1
export HOME="$run/home" TMPDIR="$run/tmp" GEM_HOME="$run/gems" GEM_PATH="$run/gems"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
mkdir "$HOME" "$TMPDIR" "$GEM_HOME"

# Fetch a public component anonymously and record its verified detached HEAD.
checkout() {
  local repository=$1 revision=$2 url="https://github.com/dtnorris/$1.git"
  git -c credential.helper= clone --no-checkout "$url" "$repository"
  git -C "$repository" -c advice.detachedHead=false checkout --detach "$revision"
  [[ $(git -C "$repository" rev-parse HEAD) == "$revision" ]]
  [[ -z $(git -C "$repository" status --porcelain) ]]
  printf '%s %s\n' "$url" "$revision"
}
checkout adventure-finder "$front_door_revision"
checkout af-frontier-pack 9af7921d2570f79d6f2146d900bedd396f14e5d3
checkout af-source-md a44019961e822b19a727e3562c2ecda4cfe0a7bd
checkout af-specification-md 394a44c2c2052ce2eeb6d28cd7647ad8a50acfcf
ruby -S gem install rexml --version 3.4.4 --no-document --clear-sources --source https://rubygems.org
ruby -rrexml/document -e 'puts "Ruby #{RUBY_VERSION}, REXML #{REXML::VERSION}"'
command -v unzip

export AF_SOURCE_MD_ROOT="$run/af-source-md" AF_FRONTIER_OUTPUT="$run/pack"
frontier="$run/af-frontier-pack/bin/af-frontier"
afao="$run/af-specification-md/AdventureFinder_Analysis_Ontology_AFAO_v1.6.1.md"
printf 'Catalog state: %s\nRegistry: %s\nCorpus: %s\n' "$catalog_state" "$registry" "$corpus"
shasum -a 256 "$catalog_state" "$registry" > inputs.before.sha256

# Build with the chosen registry and the fixed catalog, corpus and ontology.
build() {
  "$frontier" build --state "$catalog_state" --source-registry "$1" \
    --corpus-root "$corpus" --public-afao "$afao"
}
build "$registry"
"$frontier" doctor
cp "$AF_FRONTIER_OUTPUT/CURRENT" initial-current.json
refusal_exit=0
build "$run/missing-registry.yml" > refusal.log 2>&1 || refusal_exit=$?
[[ $refusal_exit -eq 1 ]]
grep -F 'ERROR: Source registry not found.' refusal.log
cmp initial-current.json "$AF_FRONTIER_OUTPUT/CURRENT"
"$frontier" doctor

build "$registry"
"$frontier" doctor
if cmp -s initial-current.json "$AF_FRONTIER_OUTPUT/CURRENT"; then
  echo 'Restored build did not select a new generation' >&2
  exit 1
fi
shasum -a 256 -c inputs.before.sha256
cat "$AF_FRONTIER_OUTPUT/CURRENT"
"$frontier" show "$adventure_id" --format json > adventure.json
"$frontier" source "$adventure_id" > source.json
"$frontier" source "$adventure_id" --emit > source.md
ruby -rjson -rdigest -e '
  source = File.realpath(JSON.parse(File.read("source.json")).fetch("path"))
  abort "Resolved source is outside the selected corpus" unless source.start_with?(File.join(File.realpath(ARGV.fetch(0)), ""))
  puts "Source SHA-256: #{Digest::SHA256.file(source).hexdigest}"
' "$corpus"
printf 'Build, refusal, rebuild and source read passed.\n'
```

Review `witness.log` privately. Confirm that the resolved workbook and registry
are the intended selections. `pack/CURRENT` records the selected generation and
its manifest SHA-256. The generation’s `manifest.json` records the workbook,
registry and pinned public ontology identities. `witness.log` records the source
file digest, and `inputs.before.sha256` records the original state and registry
digests. `initial-current.json` and `refusal.log` retain the negative control.

Use `adventure.json`, `source.json` and `source.md` to answer one specific prep
question. For example, ask what event starts the adventure and what the GM should
prepare before that scene. Open the selected Markdown file identified by
`source.json` and verify the cited passage and pages against it. Cite the owned
edition and page numbers for the part of the answer they support. Keep all inputs,
output, excerpts and the answer private. Share only redacted identities, hashes
and check results.
