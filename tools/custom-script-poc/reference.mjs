// Independent reference; does not import PineTS or StockDeck's calculation functions.
// EMA seed follows TradingView v6's documented pine_ema example (first source value).
export function emaFirstValue(values, period) {
  let previous = NaN;
  const alpha = 2 / (period + 1);
  return values.map(value => {
    if (!Number.isFinite(value)) return NaN;
    previous = Number.isFinite(previous) ? alpha * value + (1 - alpha) * previous : value;
    return previous;
  });
}

export function dcaReference(bars) {
  const ema = emaFirstValue(bars.map(bar => bar.close), 200);
  let below = false, lastLow = NaN, lastHigh = NaN, crossIndex = NaN;
  const rows = [];
  for (let i = 0; i < bars.length; i++) {
    const bar = bars[i], previous = bars[i - 1];
    if (previous && ema[i] > bar.close && ema[i - 1] <= previous.close) below = true;
    if (bar.close > ema[i]) below = false;
    const lower = Math.min(bar.open, bar.close) - bar.low;
    const upper = bar.high - Math.max(bar.open, bar.close);
    const buy = below && bar.close > bar.open && lower > upper && bar.low < ema[i]
      && (!Number.isFinite(lastLow) || bar.low < lastLow);
    if (buy) lastLow = bar.low;
    if (bar.close > ema[i]) lastLow = NaN;
    if (previous && bar.close > ema[i] && previous.close <= ema[i - 1]) crossIndex = i;
    if (bar.close < ema[i]) crossIndex = NaN;
    const sell = bar.close < bar.open && bar.low > ema[i] && upper > lower
      && Math.abs(bar.close - bar.open) >= 0.5 * (bar.high - bar.low)
      && (!Number.isFinite(lastHigh) || bar.high >= lastHigh)
      && Number.isFinite(crossIndex) && i - crossIndex >= 200;
    if (sell) lastHigh = bar.high;
    if (bar.close < ema[i]) lastHigh = NaN;
    rows.push({time: bar.openTime, ema: ema[i], buy, sell,
      color: buy ? '#FF9800FF' : sell ? '#F2364580' : null});
  }
  return rows;
}

function meanAt(bars, index, period) {
  if (index < period - 1) return NaN;
  let sum = 0;
  for (let k = index - period + 1; k <= index; k++) sum += bars[k].close;
  return sum / period;
}

export function riskReference(daily) {
  // Deliberately independent aggregation, not the provider's weeklyBars helper.
  const weeks = [];
  for (const day of daily) {
    const date = new Date(day.openTime);
    const monday = day.openTime - ((date.getUTCDay() + 6) % 7) * 86400000;
    const last = weeks.at(-1);
    if (last?.openTime === monday) last.close = day.close;
    else weeks.push({openTime: monday, closeTime: monday + 7 * 86400000, close: day.close});
  }
  let weekIndex = -1;
  return daily.map((day, index) => {
    while (weeks[weekIndex + 1]?.closeTime <= day.closeTime) weekIndex++;
    const sma1460 = meanAt(daily, index, 1460);
    let variance = NaN;
    if (Number.isFinite(sma1460)) {
      let sumSquares = 0;
      for (let k = index - 1459; k <= index; k++) sumSquares += (daily[k].close - sma1460) ** 2;
      variance = sumSquares / 1460; // ta.stdev's default biased population estimate.
    }
    const time = day.openTime;
    const one = ((day.close - sma1460) / Math.sqrt(variance)) / (-38.12 * Math.log(time) + 1078.5);
    const two = (Math.log(day.close / meanAt(weeks, weekIndex, 20)) - 3.719 * Math.log(time) + 105)
      / (-6e-12 * time + 10.93);
    const three = (meanAt(daily, index, 50) / meanAt(weeks, weekIndex, 50))
      / (-12.55 * Math.log(time) + 355.15);
    return {time, value: (one + two + three) / 3};
  });
}

export function compareNumbers(actual, expected) {
  const result = {samples: expected.length, finiteSamples: 0, finiteFailures: 0,
    naMismatches: 0, timeMismatches: 0, maxAbsoluteError: 0, firstFailures: []};
  for (let i = 0; i < expected.length; i++) {
    const a = actual[i], e = expected[i];
    const finiteActual = typeof a?.value === 'number' && Number.isFinite(a.value);
    const finiteExpected = Number.isFinite(e.value);
    let failed = false;
    if (a?.time !== e.time) { result.timeMismatches++; failed = true; }
    if (finiteActual !== finiteExpected) { result.naMismatches++; failed = true; }
    if (finiteExpected) result.finiteSamples++;
    if (finiteExpected && finiteActual) {
      const difference = Math.abs(a.value - e.value);
      result.maxAbsoluteError = Math.max(result.maxAbsoluteError, difference);
      if (difference > 1e-8 + 1e-6 * Math.abs(e.value)) { result.finiteFailures++; failed = true; }
    }
    if (failed && result.firstFailures.length < 5) result.firstFailures.push({index: i, actual: a?.value, expected: e.value});
  }
  result.lengthMismatch = actual.length !== expected.length;
  result.pass = !result.lengthMismatch && !result.naMismatches && !result.finiteFailures && !result.timeMismatches;
  return result;
}
