import {readFile,writeFile} from 'node:fs/promises';
import {weeklyBars} from './market-data.mjs';
import {runNative} from './supervisor.mjs';
import {resultDirectory,runtimeLabel} from './runtime-config.mjs';

const dcaSource=await readFile(process.argv[2],'utf8');
const riskSource=await readFile('local/risk-metric.pine','utf8');
const daily=JSON.parse(await readFile('local/btc-usd-daily.json','utf8'));
const hourly=JSON.parse(await readFile('local/btc-usd-hourly.json','utf8'));
const results=[];
for(const [name,source,bars,timeframe] of [
  ['dca-hourly-5000',dcaSource,hourly.slice(-5000),'60'],
  ['dca-hourly-10000',dcaSource,hourly,'60'],
  ['risk-daily-5000',riskSource,daily.slice(-5000),'D'],
]) {
  for(const instances of [1,3]) {
    const runs=[];
    const job={mode:'benchmark',source,bars,timeframe,instances,warmRepeats:0,
      datasets:{D:timeframe==='60'?daily:bars,W:weeklyBars(timeframe==='D'?bars:daily),'60':bars}};
    for(let i=0;i<10;i++) {
      await writeFile(`${resultDirectory}/benchmark-job.json`,JSON.stringify(job));
      const result=await runNative(`${resultDirectory}/benchmark-job.json`);
      runs.push(result);
      // Keep failed samples and continue. No successful-sample-only denominator.
    }
    // Thirty cached calls are separate requests, not one five-second user job.
    // A series-level guard bounds the benchmark; cold requests retain the 5s watchdog.
    await writeFile(`${resultDirectory}/benchmark-job.json`,JSON.stringify({...job,warmRepeats:30}));
    const warmRun=await runNative(`${resultDirectory}/benchmark-job.json`,35000);
    const row={name,instances,runs,warmRun};
    results.push(row);
    await writeFile(`${resultDirectory}/benchmark.json`,JSON.stringify({runtime:runtimeLabel,host:'Swift helper / JavaScriptCore',
      dataset:'captured Bitstamp public spot candles',scope:'engine + output encoding only; no chart render',
      watchdogMs:5000,warmSeriesGuardMs:35000,runsPerScenario:10,warmSamplesPerScenario:30,results},null,2));
    const rss=[...runs,warmRun].map(x=>x.peakRSSBytes).filter(Number.isFinite);
    const warm=warmRun.output?.warmMs||[];
    console.log(JSON.stringify({name,instances,success:runs.filter(x=>x.code===0&&x.output?.ok).length,
      timeouts:runs.filter(x=>x.timedOut).length,
      coldMaxMs:Math.max(...runs.map(x=>x.wallMs)),
      peakRSSMiB:rss.length?Math.max(...rss)/1024/1024:null,
      warmSamples:warm.length,
      warmMaxMs:warm.length?Math.max(...warm):null}));
  }
}
