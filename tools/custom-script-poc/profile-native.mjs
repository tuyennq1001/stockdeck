import {readFile,writeFile} from 'node:fs/promises';
import {parse} from 'acorn';
import {full} from 'acorn-walk';
import {weeklyBars} from './market-data.mjs';
import {runNative} from './supervisor.mjs';
const code=await readFile('local/candidate/pinets.browser.js','utf8');
const edits=[];
full(parse(code,{ecmaVersion:'latest'}),node=>{
  if(node.type!=='FunctionDeclaration') return;
  const text=code.slice(node.start,node.end);
  let label;
  if(text.includes('`stdev_')) label='stdev';
  else if(text.includes('`sma_')) label='sma';
  else if(text.includes('_prevIdx')) label='security';
  else if(text.includes('Avoid per-argument signature arrays')) label='parameterParser';
  if(!label||text.length>12000) return;
  const original='__profileOriginal_'+node.id.name;
  const renamed=text.replace('function '+node.id.name+'(','function '+original+'(');
  const record=`globalThis.__pocProfile ||= {}; const p=globalThis.__pocProfile['${label}'] ||= {calls:0,totalMs:0}; p.calls++; p.totalMs+=Date.now()-start;`;
  const wrapper=label==='parameterParser'
    ? `function ${node.id.name}(...args){const start=Date.now();try{return ${original}(...args);}finally{${record}}}`
    : `function ${node.id.name}(ctx){const fn=${original}(ctx);return (...args)=>{const start=Date.now();const result=fn(...args);if(result?.then)return result.then(x=>{${record}return x;});${record}return result;};}`;
  edits.push({node,text:renamed+'\n'+wrapper});
});
let profiled=code;
for(const edit of edits.sort((a,b)=>b.node.start-a.node.start)) profiled=profiled.slice(0,edit.node.start)+edit.text+profiled.slice(edit.node.end);
await writeFile('local/candidate/profile.browser.js',profiled);
const bars=JSON.parse(await readFile('local/btc-usd-daily.json','utf8')).slice(-5000);
await writeFile('local/candidate/profile-job.json',JSON.stringify({bars,timeframe:'D',source:await readFile('local/risk-metric.pine','utf8'),
  mode:'benchmark',datasets:{D:bars,W:weeklyBars(bars)}}));
const result=await runNative('local/candidate/profile-job.json',10000,'local/candidate/profile.browser.js');
await writeFile('local/candidate/native-profile.json',JSON.stringify(result,null,2));
console.log(JSON.stringify({profile:result.output?.profile,replayMs:result.output?.replayMs,edits:edits.length},null,2));
