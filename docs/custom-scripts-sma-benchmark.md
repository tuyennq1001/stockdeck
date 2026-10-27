# Custom Scripts: SMA20 measurement

Measured on 2026-10-26 at 14:06:53 UTC, Apple Silicon, macOS 27.0 (26A428), Swift Debug build with the bundled JavaScriptCore helper and WKWebView. This is a development measurement, not a release performance guarantee.

The input is the immutable Bitstamp BTCUSD daily capture: 5,540 real candles, SHA-256 `d715394871f1ab90adb9d96e25bf82991729e84a07237fb2b1601bcf4be3aebd`. All 2,500 emitted Pine SMA20 values match the native SMA calculation within `0.000001`. Both drawing scenarios use the same candles and latest 2,500 SMA points.

| Measured work | Median | Maximum | Samples |
| --- | ---: | ---: | ---: |
| Native Swift SMA20 math only | 0.74 ms | 0.86 ms | 30, after one warmup |
| Fresh Pine helper: startup, compile/run, IPC, output and decode | 277.68 ms | 340.43 ms | 10 independent processes |
| Built-in SMA: synchronous chart submission | 13.5 ms | 15 ms | 10, after two warmups |
| Pine SMA: synchronous chart submission | 17 ms | 19 ms | 10, after two warmups |
| Built-in SMA: forced canvas flush/composition/copy | 6 ms | 8 ms | 10 |
| Pine SMA: forced canvas flush/composition/copy | 4 ms | 6 ms | 10 |

Pine context preparation took 126.06 ms and job encoding took 43.00 ms in separate single measurements. Context preparation is shared by attached scripts for that symbol/data/interval; it is not included in the cold-helper row. The workspace debounce and native chart-payload preparation/encoding are also outside these timings.

The custom script has visible execution overhead from its separate helper and data conversion. The native row measures only arithmetic, so dividing it into the complete helper row would not isolate an engine-speed difference. Chart submission differs by 3.5 ms between the sample medians here; this does not establish a general result for other scripts. The canvas row includes `chart.takeScreenshot()` flushing pending drawing, compositing and copying to a new canvas. It is not pure GPU paint time or FPS, and its lower Pine sample median does not establish faster Pine rendering. Payloads were loaded into WebKit before timing, excluding native-to-WebKit transfer/JSON parsing. The retained canvas images were inspected and contain actual candles and the SMA line.

The benchmark exposed a real lifecycle defect: asynchronous `Process` ownership could reach `waitUntilExit` on a different thread after the child had exited and hang there. Launch, polling and reaping now stay on one background thread. A regression test verifies 40 consecutive short-lived children finish and are reaped, plus cancellation and forced termination cases. The measurement above uses that fix.

An installed library source does not execute. Attached scripts run on relevant context/source changes; helpers exit after calculation. Removing the last attachment cancels preparation, discards prepared Pine data and rejects late results. Hiding one plot in Style does not stop execution.

Reproduce with `./dev.sh`, then `STOCKDECK_PINE_BENCHMARK=1 swift test --filter PineSMABenchmarkTests` without concurrent builds/tests. The normal suite skips this measurement because the capture is local and ignored. [Raw samples and scope metadata](custom-scripts-sma-benchmark.json) contain no source code or price history. See [the workflow](custom-scripts-workflow.md) for capture requirements and execution limits.

Validation: full Swift suite 632 tests, one opt-in benchmark skipped and zero failures; that benchmark subsequently passed separately. All seven chart JavaScript tests, JavaScript syntax checks, the real WebKit menu/native-bridge integration, `./dev.sh` and `git diff --check` passed. Native mouse-driven acceptance in the launched app remains for the user; no commit was made.
