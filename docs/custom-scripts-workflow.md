# Custom scripts on Superchart

## Using scripts

1. Open the **Scripts** document/code icon → **Quản lý scripts…** on the chart toolbar, beside **Indicators** and on the same row as D/W/M. Hovering the icon shows its Scripts label. When no symbol is selected, use **Quản lý scripts…** in the empty chart area. Import a UTF-8 `.pine`/`.txt` file, or paste/edit source and choose **Lưu**. File import saves directly to the library; it does not run the script.
2. Choose a saved script from **Scripts**. It is attached and executed immediately. A checkmark identifies attached scripts; selecting a checked script detaches it through the same removal action as its legend. Select it again to reattach. Repeated clicks are blocked while native state is updating, so one action cannot create duplicates.
3. Each attached script has one legend row. **Style** changes plot visibility, colors, marker shape/location and line width. The delete icon removes that script from the chart while retaining its library entry.

The ordered attachment list survives app restarts and applies to every symbol in Superchart. Deleting a library entry also detaches it. Editing an attached source preserves its UUID and reruns that script. Style preferences use the UUID and plot identity; existing source-hash preferences migrate on first use.

Style lists named plots first in their source order. Unnamed flat lines are grouped under a collapsed auxiliary-level section and labeled with their actual returned value, without renaming their saved plot IDs. Other unnamed outputs receive readable generic labels. Multiple source colors can be edited through a collapsed palette. RGB/hex colors and opacity survive editing; transparency is shown explicitly. Line width starts from the script's declared width, and restoring defaults clears only display overrides. Style preparation runs outside the UI thread. These controls change rendering; an Inputs editor for calculation parameters remains unsupported.

The shared script Style sheet is 480 points wide and at most 400 points tall (240–330 points for fewer outputs). The content scrolls while its title and action buttons remain fixed. Marker controls wrap onto their own row so smaller sheets retain usable plot names and pickers.

## Execution and data

- The chart and runner use `LightweightChartMath.aggregate` for the same source candles and interval. Supported chart intervals are 5m, 30m, 1h, 4h, 6h, D, W, M, 3M, 6M and 1Y.
- Intraday source candles come from the existing Superchart intraday loader/cache. A missing intraday source reports an error; daily candles are never substituted.
- `request.security()` remains limited to the current symbol and captured datasets available in that execution context. Missing datasets and cross-symbol requests fail explicitly.
- Daily security data always comes from the actual daily series, independently of long-range chart history that may be monthly. An existing dataset can still be too short for a script's lookback. Missing plot values appear as `—` in the legend; they are never replaced with zero. See [the Risk Metric diagnosis](custom-scripts-risk-metric.md) for a reproduced example and the current unsupported fill regions.
- Symbol, interval, source or candle-data changes invalidate previous results. Hover, scrolling and Style changes do not execute Pine again.
- At most two helpers execute simultaneously. Cancelled helpers retain their queue slot until they terminate and are reaped; each helper has a five-second execution limit. Source remains limited to 128 KB, input to 20,000 aggregated candles and display to the latest 2,500 points per plot. These bounds do not establish complete Pine Script compatibility.
- Each helper's launch, polling and reaping stay on one background thread. This avoids an observed Foundation `waitUntilExit` hang after a short-lived helper had exited when an async task resumed on another thread. Pipe I/O runs separately; cancellation reaches the owner thread and does not release a workspace slot before reaping finishes.
- Removing the last attached script also cancels the debounced preparation task and its background worker. Cancellation is checked between timeframe aggregation steps and while converting candles. Prepared Pine datasets and results are released; late results are rejected. Subsequent symbol/interval/data changes do not prepare or execute Pine until a script is attached again. Shared chart data/cache remains available to the chart.
- Installing a library entry only stores its source. An attached script uses a short-lived helper on relevant changes; it does not continuously execute after a result. A Style checkbox hides a plot without stopping computation. Remove the script from the legend to stop the entire script; its source and Style remain available for reattachment.
- Invalid/missing OHLC is reported rather than synthesized from close. A failing script keeps its legend row with its error and retry action; other scripts continue independently.

## Rendering rules

Series and panes are scoped by script UUID and plot identity. Each `overlay=false` script owns its pane; removing or clearing it releases its series, markers and pane. Existing chart markers remain present with Pine markers.

In the normal chart layout a custom pane's stretch factor is capped at the smaller of one built-in indicator pane and one quarter of the price pane's factor. This keeps each custom pane at no more than 20% of total chart height without mixing saved fractional weights with the library's default weight of 1. Smaller user sizes are retained; custom pane ratios are saved under a `Pine:<script UUID>` layout key. The explicit pane-focus control may temporarily enlarge a selected pane; restoring the full chart reinstates normal limits. Legends reposition after pane layout and window-size changes without running Pine again.

Source white adapts to slate on light charts so a line cannot disappear against the background; transparency is retained and dark charts keep white. Saved Style colors override this adaptation. Plot values and original source colors are unchanged. The same rule is used for the script legend, and changing the OS theme repaints without running a helper.

If several attached scripts color the same candle, the last attached script providing a color wins, independent of completion order. Removing or hiding that color plot recomputes candle colors from the remaining scripts. UTF-8 source/plot names pass through the native/WebKit bridge without reinterpreting them as Latin-1.

## Verification

- `swift test`: workspace persistence, migration, edits/deletion, bounded scheduling, cancellation during preparation/debounce/queued execution, stale results, all timeframe mappings and process cancellation/timeout; also real WebKit toolbar menu actions through the native bridge, library updates, multiple scripts/panes and UTF-8.
- `node --test tools/custom-script-poc/test/chart-renderer.test.mjs`: independent series/panes, color precedence, marker overrides, context clearing and line-chart preservation using explicit test fixtures.
- `./dev.sh`: build, assemble, sign and launch the macOS development app.

Compatibility remains bounded by the bundled PineTS runtime and existing plot support. Alerts are computed but are not delivered as notifications. Style settings do not add an Inputs editor or a Visibility tab.

## Reproducible SMA measurement

After building with `./dev.sh`, run `STOCKDECK_PINE_BENCHMARK=1 swift test --filter PineSMABenchmarkTests` alone, without concurrent builds/tests. It requires the ignored real Bitstamp daily capture at `tools/custom-script-poc/local/btc-usd-daily.json`, verified against SHA-256 `d715394871f1ab90adb9d96e25bf82991729e84a07237fb2b1601bcf4be3aebd`. The test skips by default so normal tests do not depend on captured market data or benchmark timing.

The test compares SMA20 values across 5,540 actual candles and all 2,500 Pine output points. It measures Swift SMA math, Pine context preparation/encoding, cold native helper execution including startup/compilation/IPC/decoding, and chart updates separately. Both WebKit drawing scenarios receive the same candles and latest 2,500 SMA values. Payloads are preloaded before timing; synchronous JavaScript submission and `chart.takeScreenshot()` canvas flush/composition/copy are measured separately. Forcing a flush avoids suspended animation frames in a background test window; saved WebKit images are inspected to verify that candles and the SMA line actually painted. These are not pure GPU paint/FPS measurements. A Debug-build SMA math timing and a complete cold helper timing have different scopes; a ratio between them does not isolate Pine arithmetic performance.

The source-free report is written to `/tmp/stockdeck-sma-benchmark.json`; it includes individual samples, medians, maxima, capture hash and host information. See [the measured result](custom-scripts-sma-benchmark.md) for the latest run and its limits.
