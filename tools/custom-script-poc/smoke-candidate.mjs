import {readFile,writeFile} from 'node:fs/promises';
import {runNative} from './supervisor.mjs';
import {weeklyBars} from './market-data.mjs';
const bars=JSON.parse(await readFile('local/btc-usd-daily.json','utf8')).slice(-5000);
await writeFile('local/candidate/smoke-job.json',JSON.stringify({mode:'benchmark',bars,timeframe:'D',instances:3,
  datasets:{D:bars,W:weeklyBars(bars)},source:await readFile('local/risk-metric.pine','utf8')}));
const result=await runNative('local/candidate/smoke-job.json',10000);
await writeFile('local/candidate/smoke.json',JSON.stringify(result,null,2));
console.log(JSON.stringify({ok:result.output?.ok,wallMs:result.wallMs,replayMs:result.output?.replayMs,
  rssMiB:result.peakRSSBytes/1024/1024},null,2));
