import {readFile, writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import os from 'node:os';
import {PineTS,resultDirectory,runtimeLabel} from './runtime-config.mjs';
import {offlineProvider} from './market-data.mjs';
import {dcaReference, riskReference, compareNumbers} from './reference.mjs';

const dcaPath = process.argv[2];
if (!dcaPath) throw new Error('Pass the path to the user-provided original DCA source');
const daily = JSON.parse(await readFile('local/btc-usd-daily.json', 'utf8'));
const report = {createdAt: new Date().toISOString(), runtime: runtimeLabel, node: process.version,
  platform: {model: os.cpus()[0].model, arch: os.arch(), macOS: os.release()},
  tolerance: {absolute: 1e-8, relative: 1e-6}, tradingViewParity: 'BLOCKED: no matching input/output export', results: {}};
for (const [name, filename] of [['dca', dcaPath], ['risk', 'local/risk-metric.pine']]) {
  const bytes = await readFile(filename);
  const provider = offlineProvider(daily);
  const engine = new PineTS(provider, 'BTCUSD', 'D', undefined, daily[0].openTime, daily.at(-1).closeTime);
  engine.setAlertMode('all'); // Test-only capture, no desktop/webhook notifications.
  const output = await engine.run(bytes.toString('utf8'));
  const result = {sourceSHA256: createHash('sha256').update(bytes).digest('hex'),
    bars: daily.length, providerRequests: provider.requests};
  if (name === 'dca') {
    const ref = dcaReference(daily);
    result.ema = compareNumbers(output.plots['Đường EMA200'].data, ref.map(row => ({time: row.time, value: row.ema})));
    for (const [field, title] of [['buy', 'Buy Signal Marker'], ['sell', 'Sell Signal Marker']]) {
      const actual = output.plots[title].data;
      result[field] = {expected: ref.filter(row => row[field]).length,
        actual: actual.filter(row => row.value === true).length,
        mismatches: ref.flatMap((row, i) => (actual[i]?.value === true) !== row[field] ? [i] : [])};
    }
    result.barColorMismatches = ref.flatMap((row, i) =>
      normalizeColor(output.plots['Màu nến DCA'].data[i]?.options?.color) !== row.color ? [i] : []);
    result.alerts = {imperative: output.alerts.filter(event => event.type === 'alert').length,
      conditions: output.alerts.filter(event => event.type === 'alertcondition').length,
      expectedConditions: ref.filter(row => row.buy || row.sell).length};
    result.pass = result.ema.pass && !result.buy.mismatches.length && !result.sell.mismatches.length
      && !result.barColorMismatches.length && result.alerts.imperative === 0
      && result.alerts.conditions === result.alerts.expectedConditions;
  } else {
    result.risk = compareNumbers(output.plots.Risk.data, riskReference(daily));
    result.pass = result.risk.pass;
  }
  await writeFile(`${resultDirectory}/${name}-output.json`, JSON.stringify({plots: output.plots, alerts: output.alerts}));
  report.results[name] = result;
}
await writeFile(`${resultDirectory}/validation.json`, JSON.stringify(report, null, 2));
console.log(JSON.stringify(report, null, 2));
if (Object.values(report.results).some(result => !result.pass)) process.exitCode = 2;

function normalizeColor(value) {
  if (value == null || (typeof value === 'number' && Number.isNaN(value))) return null;
  const hex = String(value).toUpperCase();
  return /^#[0-9A-F]{6}$/.test(hex) ? hex + 'FF' : hex;
}
