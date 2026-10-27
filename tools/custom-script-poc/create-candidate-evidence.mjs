import {readFile,writeFile,readdir} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';

const json=async file=>JSON.parse(await readFile(file,'utf8'));
const hash=async file=>createHash('sha256').update(await readFile(file)).digest('hex');
const baseline=await json('../../docs/custom-script-poc-evidence.json');
const validation=await json('local/candidate/validation.json');
const native=await json('local/candidate/native-comparison.json');
const benchmark=await json('local/candidate/benchmark.json');
const manifest=await json('local/candidate/patch-manifest.json');
assert.equal(benchmark.runtime,validation.runtime);
assert.deepEqual(Object.keys(validation.results),['dca','risk']);
for(const name of ['dca','risk']) {
  assert.equal(validation.results[name].sourceSHA256,baseline.validation.results[name].sourceSHA256);
  assert.equal(validation.results[name].bars,baseline.validation.results[name].bars);
}
const statistics=values=>{
  const sorted=values.filter(Number.isFinite).sort((a,b)=>a-b);
  return sorted.length?{samples:sorted.length,min:sorted[0],median:sorted[Math.floor(sorted.length/2)],
    p95:sorted[Math.ceil(sorted.length*0.95)-1],max:sorted.at(-1)}:null;
};
const performance=benchmark.results.map(row=>{
  assert.equal(row.runs.length,10);
  return {name:row.name,instances:row.instances,coldTotal:row.runs.length,
    coldSuccesses:row.runs.filter(run=>run.code===0&&run.output?.ok).length,
    coldTimeouts:row.runs.filter(run=>run.timedOut).length,
    wallMsIncludingFailures:statistics(row.runs.map(run=>run.wallMs)),
    replayMsCompletedOnly:statistics(row.runs.map(run=>run.output?.replayMs)),
    cpuMsCompletedOnly:statistics(row.runs.map(run=>run.cpuMs)),
    warmCacheAndEncodingMs:statistics(row.warmRun.output?.warmMs||[]),
    warmSeriesTimedOut:row.warmRun.timedOut,
    peakRSSMiBReported:statistics([...row.runs,row.warmRun].map(run=>run.peakRSSBytes==null?null:run.peakRSSBytes/1024/1024)),
    cpuRSSUnavailableSamples:row.runs.filter(run=>run.peakRSSBytes==null).length,
    warmSeriesReplayMs:row.warmRun.output?.replayMs,outputCharacters:row.warmRun.output?.outputCharacters};
});
assert.equal(performance.length,6);
const harnessLog=await readFile('local/candidate/harness-tests.log','utf8');
const tests=Number(harnessLog.match(/ℹ tests (\d+)/)?.[1]);
const failures=Number(harnessLog.match(/ℹ fail (\d+)/)?.[1]);
assert.ok(tests>=18);assert.equal(failures,0);
const appTestLog='/tmp/stockdeck-custom-script-candidate-tests.log';
const appBuildLog='/tmp/stockdeck-custom-script-candidate-build.log';
assert.match(await readFile(appTestLog,'utf8'),/Executed 616 tests, with 0 failures/);
assert.match(await readFile(appBuildLog,'utf8'),/Launching StockDeck DEV/);
const artifacts={};
async function capture(directory='.') {
  for(const entry of await readdir(directory,{withFileTypes:true})) {
    if(['local','node_modules'].includes(entry.name))continue;
    const file=directory==='.'?entry.name:directory+'/'+entry.name;
    if(entry.isDirectory())await capture(file);
    else artifacts[file]=await hash(file);
  }
}
await capture();
for(const file of ['local/candidate/validation.json','local/candidate/native-comparison.json',
  'local/candidate/benchmark.json','local/candidate/patch-manifest.json','local/candidate/harness-tests.log',
  'local/candidate/pinets.browser.js','local/candidate/pinets.es.mjs','local/jsc-runner',
  'local/btc-usd-daily.json','local/btc-usd-hourly.json'])artifacts[file]=await hash(file);
for(const [file,index] of [['local/btc-usd-daily.json',0],['local/btc-usd-hourly.json',1]]) {
  // The immutable baseline manifests are copied below; validate their content hashes too.
  const manifest=await json(file.replace('.json','.manifest.json'));
  assert.deepEqual(manifest,baseline.datasets[index]);
  assert.equal(artifacts[file],manifest.sha256);
}
const riskThree=performance.find(row=>row.name==='risk-daily-5000'&&row.instances===3);
const report={createdAt:new Date().toISOString(),
  authorization:'User approved POC with ok thử đi and continuation with tiếp đi; no commit/push/release acceptance',
  baselineEvidenceSHA256:await hash('../../docs/custom-script-poc-evidence.json'),
  baselineCommit:baseline.baselineCommit,machine:baseline.machine,
  runtime:{version:validation.runtime,base:'pinets@0.13.0',license:baseline.runtime.license,
    installedIntoApp:false,patchManifest:manifest},datasets:baseline.datasets,
  validation,native,performance,baselinePerformance:baseline.performance,
  protocol:{...baseline.protocol,caveats:[
    'Same original Pine source bytes, immutable data, tolerance, scenario sizes and 5-second cold watchdog as baseline',
    'Thirty cached calls reuse unchanged context; live update checks use explicit test-only arithmetic fixtures',
    'Only primary-context live EMA/stdev/var/plot tail and once-per-bar alert retention are regression tested; MTF live contexts remain unverified',
    'RSS is measured helper peak, not a hard cap or total app memory; failures retain unavailable CPU/RSS as null',
    'No OS sandbox, complete arbitrary-source preflight, StockDeck IPC/renderer, FPS or same-input TradingView export',
    'Full PineTS compatibility and distribution-license suitability are not established by these two examples']},
  checks:{stockdeckSwiftTests:{tests:616,failures:0,logSHA256:await hash(appTestLog)},
    stockdeckDevBuild:{success:true,logSHA256:await hash(appBuildLog)},
    pocHarnessTests:{tests,failures,logSHA256:artifacts['local/candidate/harness-tests.log'],
      scope:'candidate semantics, parser differential fixtures, lookup boundaries, primary live tail, output naming and baseline/watchdog guards'}},
  verdict:{dcaNumeric:validation.results.dca.pass?'PASS independent reference on captured dataset':'FAIL',
    riskNumeric:validation.results.risk.pass?'PASS independent reference on captured D/W dataset':'FAIL',
    nativeNumeric:Object.values(native).every(row=>row.ok&&row.numericAgainstIndependentReference.pass&&row.numericAgainstNode.pass)?'PASS reference and Node tolerance':'FAIL',
    threeRiskColdBudget:riskThree.coldSuccesses===10?'PASS 10/10 within unchanged 5-second watchdog':'FAIL or incomplete',
    tradingViewParity:validation.tradingViewParity,productionIsolation:'NOT COMPLETE',chartFPS:'NOT RUN',
    nextStage:'M1 remains incomplete: license route, production isolation/preflight, TradingView oracle and app integration gates pending'},
  artifacts};
await writeFile('../../docs/custom-script-candidate-evidence.json',JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify({verdict:report.verdict,performance},null,2));
