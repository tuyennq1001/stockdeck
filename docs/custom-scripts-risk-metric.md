# Risk Metric diagnosis — 2026-10-27

The installed source matches the structure of [Risk Metric combined by pommesUNDwurst](https://www.tradingview.com/script/ozoOkwKL-Risk-Metric-combined/): daily SMA/stdev over 1,460 candles, daily SMA50 and weekly SMA20/SMA50. It declares `overlay=false` and belongs in its own pane. The source was read from the local script library, without modifying it or its saved attachment state. Its SHA-256 is `0ae3b47a3e520d351610615e688973a2bdbc2bdd489916acd70caeb3f21f8025`.

## Confirmed causes

1. The chart bridge selected `maxPoints` as the daily `request.security()` source whenever long history existed. That cache can contain **monthly** candles. On the weekly V chart, the resulting D dataset contained only 121 monthly records instead of 2,512 actual daily candles. The bundled helper returned zero finite Risk values. Passing the actual daily source produced 220 finite weekly Risk values with the same installed script. This binding is fixed; long-range chart candles and daily security data now retain their separate resolutions.
2. The development cache for BTC-USD and BTCUSDT contains only 1,000 daily candles. Even with the correct D source, this is below the script's 1,460-candle lookback. Native execution using those real cached BTC candles returned zero finite Risk values. Correcting the daily binding cannot create missing history. This change does **not** add historical-data pagination or fabricate candles; BTC still needs a longer actual daily dataset before this script can produce Risk values.
3. The source uses five `fill()` regions. The current helper deliberately emits no fill points and the chart renderer does not draw that plot style. The Risk line and thresholds are supported, but the colored regions are not yet implemented.
4. A separate daily-V replay found 1,053 finite Risk points, including 41 points whose source color is white. The latest value was `0.9303420454296458`, with source color `#FFFFFF`; the source selects white when Risk is at least 0.8. On a light chart this hides the curve and its legend value while the fixed red Sell Limit at 0.8 remains visible. This is a display problem distinct from missing history or warmup.

## Execution check

Using the same installed source with the existing immutable real Bitstamp BTCUSD capture (5,540 D candles, SHA-256 `d715394871f1ab90adb9d96e25bf82991729e84a07237fb2b1601bcf4be3aebd`), the app's bundled helper completed:

| Main interval | Outcome | Finite Risk values returned | Approximate helper time |
| --- | --- | ---: | ---: |
| D | Success | 2,500 (display tail limit) | 2.26 s |
| W | Success | 583 of 792 weekly records | 1.44 s |

These are diagnostic runs, not a guarantee for every symbol/timeframe. The source's formulas and warmup were preserved. No third-party source or market history is included in this report. Comparison with an identical TradingView export remains unverified.

## UI

The toolbar Scripts entry uses a document/code icon with an accessible Scripts label and tooltip. A plot without numeric/state values now keeps a `—` in its script legend, with a tooltip to check historical data and the timeframe. Empty plots are not silently omitted or converted to zero.

Source white now renders as slate `#475569` on a light chart, retaining its alpha. Dark charts retain source white. Explicit saved Style colors take precedence. The rule is shared by Pine rendering and the legend, applies by source color rather than script name, and does not alter source, numeric results or original plot colors. OS theme changes repaint the chart without rerunning Pine.

A native WebKit replay using the real cached V candles and bundled-helper output verified that the Risk series still contains 1,053 points, its latest value stays `0.9303420454296458`, and its displayed color is `#475569`. The separate Sell Limit remains red at exactly 0.8. The real WebKit regression test also verifies the visible Risk color reaches canvas pixels, its legend uses the same color, and a dark-theme repaint restores white. The generic JavaScript tests cover alpha, alternate white encodings, other colors, explicit Style overrides and unchanged numeric values. This does not add `fill()` rendering or establish parity with a TradingView export.

Regression coverage checks that an All-range chart can use monthly primary candles while D and W security datasets derive from the actual daily source. The real WebKit test checks the Scripts icon, menu routing and the missing-plot placeholder.

The Style sheet previously exposed seven unnamed helper keys (`#0`–`#6`) before named plots, with unlabeled width steppers. They are real flat plots from the source, not script inputs. They now appear in a collapsed auxiliary-level section, labeled by their actual values. Sell Limit, Neutral, Buy Limit and Risk retain their source names and order. Risk's five source colors are editable in a separate palette, source line widths are retained, and transparency is labeled and preserved. The color picker accepts RGB strings as well as hex, instead of falling back to a system text color. No calculation-parameter editor or fill renderer has been added.
