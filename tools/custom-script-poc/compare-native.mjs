import {readFile,writeFile} from 'node:fs/promises';
import {compareNumbers,dcaReference,riskReference} from './reference.mjs';
import {resultDirectory} from './runtime-config.mjs';
const daily=JSON.parse(await readFile('local/btc-usd-daily.json','utf8'));
const report={};
for(const name of ['dca','risk']) {
  const native=JSON.parse(await readFile(`${resultDirectory}/native-${name}-output.json`,'utf8'));
  const node=JSON.parse(await readFile(`${resultDirectory}/${name}-output.json`,'utf8'));
  const key=name==='dca'?'Đường EMA200':'Risk';
  const expected=name==='dca'?dcaReference(daily).map(x=>({time:x.time,value:x.ema})):riskReference(daily);
  report[name]={ok:native.output?.ok,wallMs:native.wallMs,cpuMs:native.cpuMs,peakRSSBytes:native.peakRSSBytes,
    numericAgainstIndependentReference:compareNumbers(native.output.plots[key].data,expected),
    numericAgainstNode:compareNumbers(native.output.plots[key].data,
      node.plots[key].data.map(x=>({time:x.time,value:x.value==null?NaN:x.value}))),
    alertsEqual:JSON.stringify(native.output.alerts)===JSON.stringify(node.alerts)};
  if(name==='dca') report[name].signalsEqualToNode=['Buy Signal Marker','Sell Signal Marker','Màu nến DCA']
    .every(title=>JSON.stringify(native.output.plots[title].data)===JSON.stringify(node.plots[title].data));
}
await writeFile(`${resultDirectory}/native-comparison.json`,JSON.stringify(report,null,2));
console.log(JSON.stringify(report,null,2));
