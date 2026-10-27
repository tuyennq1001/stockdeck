import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {parse} from 'acorn';
import {full} from 'acorn-walk';
await mkdir('local/vendor-inspect',{recursive:true});
const map=JSON.parse(await readFile('node_modules/pinets/dist/pinets.min.browser.js.map','utf8'));
for(let i=0;i<map.sources.length;i++) {
  if(/findSecContextIdx|runSecondary|Context.class|Series.ts|namespaces\/ta\/.*(ema|macd|stdev)|namespaces\/request\/utils|namespaces\/utils|namespaces\/Plots|rollingWindow|nonNaWindow|parseArgsForPine/.test(map.sources[i])) {
    await writeFile('local/vendor-inspect/'+map.sources[i].replaceAll('../','').replaceAll('/','_'),map.sourcesContent[i]);
  }
}
const code=await readFile('node_modules/pinets/dist/pinets.min.browser.js','utf8');
const functions=[];
full(parse(code,{ecmaVersion:'latest'}),node=>{
  if(node.type==='FunctionDeclaration') {
    const text=code.slice(node.start,node.end);
    if((text.includes('prevInitSum')&&text.includes('currentEma'))
      || (text.includes('remaining_options')&&text.includes('new Array')&&text.length<5000))
      functions.push({name:node.id.name,length:text.length,text});
  }
});
console.log(JSON.stringify(functions.sort((a,b)=>a.length-b.length),null,2));
