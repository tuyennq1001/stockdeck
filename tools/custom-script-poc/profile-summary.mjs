import {readFile} from 'node:fs/promises';
const profile=JSON.parse(await readFile(process.argv[2],'utf8'));
const counts=new Map();
for(const sample of profile.samples||[]) counts.set(sample,(counts.get(sample)||0)+1);
const result=profile.nodes.map(node=>({samples:counts.get(node.id)||0,name:node.callFrame.functionName,
  file:node.callFrame.url,line:node.callFrame.lineNumber,column:node.callFrame.columnNumber}))
  .filter(x=>x.samples).sort((a,b)=>b.samples-a.samples);
console.log(JSON.stringify(result.slice(0,25),null,2));
const lines=(await readFile('node_modules/pinets/dist/pinets.min.es.js','utf8')).split('\n');
for(const row of result.filter(x=>x.file.endsWith('pinets.min.es.js')).slice(0,12)) {
  console.log(row.name+': '+lines[row.line]?.slice(Math.max(0,row.column-60),row.column+220));
}
