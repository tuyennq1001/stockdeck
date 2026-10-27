import {mkdir, writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';

// Public market candles only. No account endpoints or credentials.
const directory = path.resolve('local');
await mkdir(directory, {recursive: true});
const end = Math.floor(Date.now() / 86400000) * 86400;
for (const [name, step, start] of [
  ['btc-usd-daily', 86400, 1314316800],
  ['btc-usd-hourly', 3600, end - 10000 * 3600],
]) {
  const points = new Map();
  const requests = [];
  for (let cursor = start; cursor < end; cursor += 1000 * step) {
    const stop = Math.min(end - step, cursor + 999 * step);
    const url = `https://www.bitstamp.net/api/v2/ohlc/btcusd/?step=${step}&limit=1000&start=${cursor}&end=${stop}&exclude_current_candle=true`;
    const response = await fetch(url, {signal: AbortSignal.timeout(30000)});
    if (!response.ok) throw new Error(`Bitstamp HTTP ${response.status}`);
    const body = await response.json();
    if (!body.data?.ohlc) throw new Error('Missing Bitstamp candles');
    requests.push({url, fetchedAt: new Date().toISOString(), count: body.data.ohlc.length});
    for (const row of body.data.ohlc) {
      const time = Number(row.timestamp);
      if (time < start || time >= end) continue;
      const bar = {openTime: time * 1000, closeTime: (time + step) * 1000,
        open: +row.open, high: +row.high, low: +row.low, close: +row.close, volume: +row.volume};
      if (!Object.values(bar).every(Number.isFinite) || bar.low > Math.min(bar.open, bar.close)
        || bar.high < Math.max(bar.open, bar.close)) throw new Error(`Invalid OHLC at ${time}`);
      points.set(time, bar);
    }
  }
  const bars = [...points.values()].sort((a, b) => a.openTime - b.openTime);
  const bytes = JSON.stringify(bars);
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  await writeFile(path.join(directory, `${name}.json`), bytes);
  await writeFile(path.join(directory, `${name}.manifest.json`), JSON.stringify({
    provider: 'Bitstamp public OHLC', symbol: 'BITSTAMP:BTCUSD', intervalSeconds: step,
    timezone: 'UTC', session: '24x7', adjustment: 'exchange spot OHLC, no adjustment applied',
    count: bars.length, first: bars[0]?.openTime, last: bars.at(-1)?.openTime,
    missingIntervals: bars.slice(1).filter((bar, i) => bar.openTime - bars[i].openTime !== step * 1000).length,
    sha256, requests,
  }, null, 2));
  console.log(JSON.stringify({name, count: bars.length, sha256}));
}
