# BD-04F offline composition proof

Run from AdventureFinder with current sibling checkouts and their installed Ruby
bundle dependencies:

```sh
export WLO_REPO_ROOT="$(cd ../workload-orchestrator && pwd)"
export LOW_REPO_ROOT="$(cd ../local-ollama-workers && pwd)"
export RPOF_REPO_ROOT="$(cd ../runpod-ollama-fleet && pwd)"
RUBYOPT="-r$PWD/test/support/offline_network_guard.rb" \
  ruby -Ilib test/integration/capability_composition_test.rb
```

Without all three roots this integration test explicitly skips. With them, it
uses the real AF frozen-plan resolver and WLO-owned capability contract, then
passes the exact artifact bytes to separate LOW and RPOF subprocesses. Neither
provider imports the other's implementation or the WLO parser.

The fixtures are temporary production-shaped v0.3 plans with a selected pool
and a decoy pool. They do not modify production plans. Two independently frozen
plans vary AF batch, plan, pool, alias and labels while preserving all runtime
requirements. The test compares generic bytes and fingerprints, FO-11 identities,
controller generations, launch counts, bring-up stage calls and retained budget
bytes. RPOF uses its real campaign, controller supervisor, budget accounting,
lifecycle, bring-up reconciler and retained state, with fake OS, guardian and
runtime observations. LOW uses its real explicit bootstrap CLI, evidence store
and observational worker source, with fake Ollama/hardware observations.

A second case varies model, full digest, exact context, exact residency, and GPU
presence/value independently. Both independent parsers must produce the same
fingerprint as WLO, and each change must change the FO-11 identity. The existing
provider suites additionally falsify prefix digests, coerced booleans, larger
observed contexts, runtime mismatches and invalid provenance fields.

The authoritative AFW/WLO v0.3 plan contract currently permits only true
residency when specified. AF preflight preserves this policy. Generic v0.1
capability requests permit both exact booleans; the runtime-variation test
constructs these generic artifacts separately, rather than treating a false
residency fixture as a valid frozen plan. LOW accepts an exact false runtime.
RPOF's capacity-campaign v0.1 policy also requires true, so it rejects that
otherwise-valid generic variation. No plan or campaign policy is broadened.

The cross-repository probe also reads temporary historical FO-10 v0.2 controller
requests and FO-11 AF-shaped state while retaining the real finite budget. It
compares every retained file byte before/after these reads, including the binding
and parent ledger. Historical compatibility is additionally covered by RPOF's `campaign_controller_supervisor_test.rb`,
`worker_bringup_identity_test.rb` and `worker_bringup_reconciler_test.rb`.
Their retained readers are distinct from new generic input. The historical
`model_requirement` and `model_requirement_sha256` field names remain recorded
format names; generic values contain only the generic contract/fingerprint.
Run the full provider suites as well as this composition test before closeout.

The operator acceptance harness supplies its own offline guard. Run it without
an additional guard in `RUBYOPT` to avoid duplicate-load warnings:

```sh
env -u RUBYOPT bin/af-operator-acceptance
```
