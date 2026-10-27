# Custom Scripts POC — development only

This harness evaluates an independently installed, pinned `pinets@0.13.0` using user-supplied Pine source and captured public Bitstamp BTC/USD candles. It does **not** add a feature or dependency to the StockDeck app bundle. No account endpoints, keys, desktop alerts, orders or uploads are used.

`local/` and `node_modules/` are ignored. Do not commit user source, third-party source, market exports, vendor bundles or helper binaries without resolving redistribution terms. PineTS currently declares AGPL-3.0-only and offers a separate commercial route. This experiment does not decide StockDeck's distribution license.

From this directory:

1. `npm ci --ignore-scripts --no-audit --no-fund`
2. `node fetch-data.mjs` captures immutable public D/H candles with provenance and SHA-256. Preserve the original snapshots to reproduce a report; refetching creates a different dataset.
3. Place the Risk Metric source in `local/risk-metric.pine`; use the original DCA attachment path as the argument below. No sample is silently substituted or modified.
4. `xcrun swiftc -O -framework JavaScriptCore jsc-runner.swift -o local/jsc-runner`
5. `npm test` tests the harness and explicit arithmetic fixtures. A passing harness test suite is **not** a passing Pine compatibility verdict; one test deliberately detects the pinned engine's EMA seed discrepancy.
6. `node validate.mjs /absolute/path/to/original-dca-source.txt` writes the independent numeric/signal results to `local/validation.json`; exit status 2 means a compatibility verdict failed, and is expected for the pinned baseline DCA discrepancy.
7. `node verify-native.mjs /absolute/path/to/original-dca-source.txt` captures native JavaScriptCore output; `node compare-native.mjs` compares it to the independent reference and Node output with tolerance.
8. `node benchmark.mjs /absolute/path/to/original-dca-source.txt` records ten fresh helper processes per scenario, then thirty cached calls in a separate helper. No synthetic market history is used to reach a desired bar count.
9. `node create-evidence.mjs` writes the shareable, source-free JSON summary to `docs/custom-script-poc-evidence.json` and captures toolchain/artifact provenance.

The parent watchdog kills the whole child process group at five seconds for each cold request. The thirty-call warm-series benchmark has a separate overall guard; each cached request is evaluated against its own one-second target. Failed/timeout samples stay in the denominator. A timeout may prevent `/usr/bin/time` from reporting RSS/CPU; those values are unavailable, not zero.

Measurements include compiler/execution/output normalization and encoding, plus cold process startup as recorded separately. They exclude chart painting, Swift bridge transfer and editor UI. The native helper has no JS file/network exports, but **is not an OS-sandboxed production runner**. Process killability does not establish complete security isolation, hard memory limits, incremental live semantics or TradingView parity.

The reference EMA follows the first-source seed in TradingView's documented `pine_ema` example; the pinned engine uses an SMA seed. A failed reference comparison must remain visible. The default baseline uses the original vendor package and never repairs user source.

## Private candidate experiment

The immutable first report/evidence remain in `docs/custom-script-poc-{report.md,evidence.json}`. The follow-up candidate has its own report/evidence and `local/candidate/` results. It changes runtime behavior, never the original DCA or Risk Pine source. Nothing is installed into the app.

`node build-candidate.mjs` parses the pinned browser/ES bundles, checks exact factory shapes, and applies the small recipes in `patches/`. It writes the candidate bundles and SHA-256 patch manifest under ignored `local/candidate/`; it does not modify `node_modules`. The build fails if the expected vendor shapes change. The recipe, pinned lockfile and source-free evidence make the private experiment reviewable. Distribution obligations remain unresolved; this is not approval to ship the modified engine.

Changes cover EMA seeding, argument binding allocations, HTF interval lookup, primitive plot-option reads, rolling standard deviation and plot-tail replacement on live recalculation. Alert event history and the runtime's once-per-bar deduplication remain intact. The HTF lookup assumes ordered, nonoverlapping provider intervals; a production adapter must enforce that contract. Signature caching relies on the pinned namespaces' immutable signature tables. Node-only test exports compare the old/new parsers and interval lookups; they are not in the browser bundle.

Run these commands from this directory, preserving the same immutable captures:

```sh
npm run candidate:build
POC_RUNTIME=candidate npm test
POC_RUNTIME=candidate node validate.mjs /absolute/path/to/original-dca-source.txt
POC_RUNTIME=candidate node verify-native.mjs /absolute/path/to/original-dca-source.txt
POC_RUNTIME=candidate node compare-native.mjs
POC_RUNTIME=candidate node benchmark.mjs /absolute/path/to/original-dca-source.txt
node create-candidate-evidence.mjs
```

The evidence command also expects the app test/build and candidate harness logs at the paths recorded in its source. `npm test` rebuilds the candidate first. Do not run tests/profilers alongside the final benchmark, and do not overwrite the original evidence with candidate results. `profile-native.mjs` and `smoke-candidate.mjs` are exploratory; their longer diagnostic guards do not change the five-second acceptance benchmark.

Primary-context live tests cover EMA/stdev/var state, plot timestamp replacement, an appended bar and alert retention. They do not establish multi-timeframe live parity, all alert frequencies or a native notification contract. Unchanged cached output timing is separate from new-bar work. Production source validation, OS sandbox, hard resource caps, licensing, TradingView same-input exports and StockDeck UI/FPS checks are still required.
