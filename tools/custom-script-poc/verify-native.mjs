import {readFile,writeFile} from 'node:fs/promises';
import {weeklyBars} from './market-data.mjs';
import {runNative} from './supervisor.mjs';
import {resultDirectory} from './runtime-config.mjs';
const daily=JSON.parse(await readFile('local/btc-usd-daily.json','utf8'));
const results={};
for(const [name,filename] of [['dca',process.argv[2]],['risk','local/risk-metric.pine']]) {
  await writeFile(`${resultDirectory}/native-job.json`,JSON.stringify({source:await readFile(filename,'utf8'),
    bars:daily,timeframe:'D',datasets:{D:daily,W:weeklyBars(daily)}}));
  const native=await runNative(`${resultDirectory}/native-job.json`);
  await writeFile(`${resultDirectory}/native-${name}-output.json`,JSON.stringify(native));
  const node=JSON.parse(await readFile(`${resultDirectory}/${name}-output.json`,'utf8'));
  const differences=[];
  for(const [key,plot] of Object.entries(native.output?.plots||{})) {
    if(JSON.stringify(plot.data)!==JSON.stringify(node.plots[key]?.data)) differences.push(key);
  }
  results[name]={ok:native.output?.ok,wallMs:native.wallMs,cpuMs:native.cpuMs,peakRSSBytes:native.peakRSSBytes,
    comparedPlots:Object.keys(native.output?.plots||{}).length,plotsDifferentFromNode:differences,
    alertsEqual:JSON.stringify(native.output?.alerts)===JSON.stringify(node.alerts)};
}
await writeFile(`${resultDirectory}/native-validation.json`,JSON.stringify(results,null,2));
console.log(JSON.stringify(results,null,2));
