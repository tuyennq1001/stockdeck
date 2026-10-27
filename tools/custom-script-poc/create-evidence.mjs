import {readFile,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import os from 'node:os';
const execute=promisify(execFile);
const json=async file=>JSON.parse(await readFile(file,'utf8'));
const hash=async file=>createHash('sha256').update(await readFile(file)).digest('hex');
const validation=await json('local/validation.json');
for(const result of Object.values(validation.results)) {
  for(const field of ['buy','sell']) if(result[field]) {
    const values=result[field].mismatches;
    result[field].mismatchCount=values.length;
    result[field].firstMismatches=values.slice(0,12);
    delete result[field].mismatches;
  }
  if(result.barColorMismatches) {
    result.barColorMismatchCount=result.barColorMismatches.length;
    delete result.barColorMismatches;
  }
}
const benchmark=await json('local/benchmark.json');
const statistics=values=>{
  const sorted=values.filter(Number.isFinite).sort((a,b)=>a-b);
  return sorted.length?{samples:sorted.length,min:sorted[0],median:sorted[Math.floor(sorted.length/2)],
    p95:sorted[Math.ceil(sorted.length*0.95)-1],max:sorted.at(-1)}:null;
};
const performance=benchmark.results.map(row=>({name:row.name,instances:row.instances,
  coldTotal:row.runs.length,coldSuccesses:row.runs.filter(run=>run.code===0&&run.output?.ok).length,
  coldTimeouts:row.runs.filter(run=>run.timedOut).length,
  wallMsIncludingFailures:statistics(row.runs.map(run=>run.wallMs)),
  replayMsCompletedOnly:statistics(row.runs.map(run=>run.output?.replayMs)),
  cpuMsCompletedOnly:statistics(row.runs.map(run=>run.cpuMs)),
  warmCacheAndEncodingMs:statistics(row.warmRun.output?.warmMs||[]),
  warmSeriesTimedOut:row.warmRun.timedOut,
  peakRSSMiBReported:statistics([...row.runs,row.warmRun].map(run=>run.peakRSSBytes==null?null:run.peakRSSBytes/1024/1024)),
  cpuRSSUnavailableSamples:row.runs.filter(run=>run.peakRSSBytes==null).length,
  warmSeriesReplayMs:row.warmRun.output?.replayMs,
  outputCharacters:row.warmRun.output?.outputCharacters,
}));
const artifacts={};
for(const file of ['package.json','package-lock.json','jsc-job.js','jsc-runner.swift','reference.mjs','benchmark.mjs',
  'validate.mjs','supervisor.mjs','market-data.mjs','fetch-data.mjs','verify-native.mjs','compare-native.mjs',
  'create-evidence.mjs','test/runtime.test.mjs','test/reference.test.mjs','test/watchdog.test.mjs',
  'node_modules/pinets/dist/pinets.min.browser.js','local/jsc-runner','local/validation.json','local/benchmark.json',
  'local/native-comparison.json','local/harness-tests.log']) artifacts[file]=await hash(file);
const report={createdAt:new Date().toISOString(),approval:'User: ok thử đi — approved POC; no commit/push/release approval',
  baselineCommit:(await execute('git',['rev-parse','HEAD'])).stdout.trim(),
  machine:{cpu:os.cpus()[0].model,architecture:os.arch(),macOS:(await execute('sw_vers',['-productVersion'])).stdout.trim(),
    swift:(await execute('xcrun',['swiftc','--version'])).stdout.trim(),node:process.version},
  runtime:{version:'pinets@0.13.0',packageLockSHA256:artifacts['package-lock.json'],license:'AGPL-3.0-only; commercial option not purchased',
    installedIntoApp:false},
  datasets:[await json('local/btc-usd-daily.manifest.json'),await json('local/btc-usd-hourly.manifest.json')],
  validation,native:await json('local/native-comparison.json'),performance,
  protocol:{coldProcessesPerScenario:10,coldWatchdogMs:5000,warmCachedCallsPerScenario:30,
    warmSeriesOverallGuardMs:35000,scope:'helper process startup + runtime + normalization/JSON encoding; no chart rendering',
    caveats:['warm means same source/input/context; it does not measure new bars or context switches',
      'cold timeouts remain failures, CPU/RSS unavailable on killed time wrapper are not zero',
      'hourly 5000/10000 used for DCA, daily 5000 for Risk; no invented 10000-day BTC history',
      'preliminary benchmark discarded as protocol development: cache initialization and warm/cold grouping corrected before final matrix',
      'OS sandbox, hard memory cap, arbitrary user source policy and live rollback still unverified']},
  checks:{stockdeckSwiftTests:{tests:616,failures:0,logSHA256:await hash('/tmp/stockdeck-custom-script-baseline-tests.log')},
    stockdeckDevBuild:{success:true,logSHA256:await hash('/tmp/stockdeck-custom-script-baseline-build.log')},
    pocHarnessTests:{tests:9,failures:0,scope:'harness guards and explicit test fixtures; not a compatibility PASS'}},
  verdict:{nativeHost:'PASS limited trusted-source offline execution',dcaNumeric:'FAIL documented EMA reference',
    riskNumeric:'PASS on captured daily/weekly dataset only',threeRiskColdBudget:'FAIL: 10/10 requests exceed 5-second watchdog',
    tradingViewParity:'BLOCKED: no same-input TradingView numeric export',
    productionIsolation:'NOT RUN: no OS sandbox/hard memory cap/complete AST policy',
    chartFPS:'NOT RUN: not integrated into StockDeck',nextStage:'STOP at M1; resolve compatibility/performance/license before UI integration'},
  artifacts};
await writeFile('../../docs/custom-script-poc-evidence.json',JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify({verdict:report.verdict,performance},null,2));
