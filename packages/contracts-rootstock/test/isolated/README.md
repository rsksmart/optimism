# Isolated tests

Tests in this directory mutate **process-global** state and must not run in
the parallel suite. Forge executes test functions concurrently within a single
invocation, so a global write here would be clobbered by — and leak into —
unrelated suites, producing intermittent failures that look unrelated to the
change that caused them.

Run them in their own single-threaded forge invocation, and exclude them from
the main run:

```sh
# main suite
forge test --no-match-path 'test/isolated/*'

# isolated suite
forge test --threads 1 --match-path 'test/isolated/*'
```

`.github/workflows/rsk-contracts-test.yml` does exactly this in two steps.
Note that `threads` in `foundry.toml` does not serialize the test runner — the
flag has to be passed on the command line.

## What lives here and why

- `RSKDeployOPChainBondEnvParsing.t.sol` — uses `vm.setEnv` to check that
  `RSKDeployOPChain.initBond()` parses `RSK_DISPUTE_GAME_INIT_BOND_WEI`. There
  is no `vm.unsetEnv` cheatcode, so the value cannot be restored, only
  overwritten; that is why the whole file is quarantined instead of relying on
  a cleanup step.

Everything that can be tested without touching the environment belongs in
`test/` instead. For the init-bond feature that is
`test/RSKDeployOPChainBondEnv.t.sol`, which overrides the virtual `initBond()`
through a harness and therefore exercises the full deploy wiring with no
global writes at all.
