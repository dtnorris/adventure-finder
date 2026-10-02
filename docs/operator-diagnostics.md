# Short operator diagnostics

`bin/af-doctor` resolves the checked-in FO-01 production contexts and delegates
classification to WLO or RPOF. It does not duplicate scheduler, readiness,
campaign, or provider semantics and does not mutate execution or provider state.

```bash
bin/af-doctor job 39 0946-openness
bin/af-doctor job 39 0946-openness --logs --lines 15
bin/af-doctor pod A2
bin/af-doctor pod A2 --logs --lines 15
bin/af-doctor fleet A
bin/af-doctor campaign A
```

Add `--json` for the complete structured result. Human diagnosis is bounded for
narrow terminals; log views default to the component limit and accept at most
200 lines.

Job short handles are defined by WLO: a canonical ID ending in
`-advNNNN-words` becomes `NNNN-<last-word>`. Full canonical IDs also work.
Resolution is exact within one plan and ambiguity fails closed. Pod handles are
the existing deterministic RPOF aggregate aliases (`A1`, `A2`, and so on) and
must resolve to one current retained worker identity.

For an unhealthy subject, the component returns one action identifier. The
workspace adds one short `af-doctor` command only when the cross-repository
mapping is deterministic. Healthy subjects have no action. Unknown evidence is
reported as unknown rather than guessed.

All inputs are retained evidence. Doctor and log commands do not clear pause,
acknowledge a breaker, retry work, publish registry state, refresh a guardian,
bootstrap a worker, perform inference, or create/delete provider capacity.
