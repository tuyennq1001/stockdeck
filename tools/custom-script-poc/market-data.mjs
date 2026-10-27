// Input is captured public spot data. This provider performs no network I/O.
export function weeklyBars(daily) {
  const groups = new Map();
  const weekMs = 7 * 86400000;
  for (const bar of daily) {
    const date = new Date(bar.openTime);
    const daysSinceMonday = (date.getUTCDay() + 6) % 7;
    const start = bar.openTime - daysSinceMonday * 86400000;
    if (!groups.has(start)) groups.set(start, {...bar, openTime: start, closeTime: start + weekMs});
    else {
      const group = groups.get(start);
      group.high = Math.max(group.high, bar.high);
      group.low = Math.min(group.low, bar.low);
      group.close = bar.close;
      group.volume += bar.volume;
    }
  }
  return [...groups.values()];
}

export function offlineProvider(daily, hourly = []) {
  const datasets = {D: daily, '1D': daily, W: weeklyBars(daily), '1W': weeklyBars(daily),
    '60': hourly, '1H': hourly};
  const requests = [];
  return {
    requests,
    configure() {},
    async getSymbolInfo() {
      // Only metadata known for the captured exchange instrument. No invented company fields.
      return {tickerid: 'BITSTAMP:BTCUSD', main_tickerid: 'BITSTAMP:BTCUSD', ticker: 'BTCUSD',
        prefix: 'BITSTAMP', root: 'BTC', type: 'crypto', basecurrency: 'BTC', currency: 'USD',
        timezone: 'Etc/UTC', session: '24x7'};
    },
    async getMarketData(ticker, timeframe, limit, from, to) {
      requests.push({ticker, timeframe, limit, from, to});
      if (!['BTCUSD', 'BITSTAMP:BTCUSD'].includes(ticker)) throw new Error('Uncaptured symbol');
      if (!datasets[timeframe]?.length) throw new Error(`Uncaptured interval ${timeframe}`);
      let bars = datasets[timeframe].filter(bar => (from == null || bar.closeTime > from)
        && (to == null || bar.openTime < to));
      if (limit != null) bars = bars.slice(-limit);
      return bars;
    },
  };
}
