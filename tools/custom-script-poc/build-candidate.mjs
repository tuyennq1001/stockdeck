import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import {parse} from 'acorn';
import {full} from 'acorn-walk';

const hash=text=>createHash('sha256').update(text).digest('hex');
const pkg=JSON.parse(await readFile('node_modules/pinets/package.json','utf8'));
assert.equal(pkg.version,'0.13.0','Patch recipe only audited against this exact version');
await mkdir('local/candidate',{recursive:true});
const manifest={base:'pinets@0.13.0',createdAt:new Date().toISOString(),patches:[
  'ema-first-source-seed','allocation-reduced-parameter-parser','binary-search-htf-index',
  'scalar-plot-options-without-series-allocation','incremental-window-stdev',
  'live-tail-output-replacement'],artifacts:{}};
for(const [input,output,type] of [
  ['pinets.min.browser.js','pinets.browser.js','script'],
  ['pinets.min.es.js','pinets.es.mjs','module'],
]) {
  const code=await readFile('node_modules/pinets/dist/'+input,'utf8');
  const ast=parse(code,{ecmaVersion:'latest',sourceType:type});
  const matches=[],parsers=[],lookups=[],plotOptionMethods=[],stdevs=[],tailMethods=[];
  full(ast,node=>{
    if(node.type==='MethodDefinition'&&node.key.name==='extractPlotOptions') plotOptionMethods.push(node);
    if(node.type==='MethodDefinition'&&node.key.name==='updateTail') tailMethods.push(node);
    if(node.type==='FunctionDeclaration') {
      const text=code.slice(node.start,node.end);
      if(text.includes('prevInitSum')&&text.includes('currentEma')) matches.push(node);
      if(text.includes('remaining_options')&&text.includes('new Array')&&text.length<5000) parsers.push(node);
      if(node.params.length===6&&text.length<600&&text.includes('return-1')&&text.includes('for(')) lookups.push(node);
      if(text.includes('`stdev_')&&text.length<3000) stdevs.push(node);
    }
  });
  assert.equal(matches.length,1,'Expected unique audited EMA factory');
  assert.equal(parsers.length,1,'Expected unique argument parser');
  assert.equal(lookups.length,1,'Expected unique HTF index lookup');
  assert.ok(plotOptionMethods.length>=1&&plotOptionMethods.length<=3,'Expected audited plot-option readers');
  for(const method of plotOptionMethods) {
    const body=code.slice(method.start,method.end);
    assert.ok(body.length<400&&body.includes('.from(')&&body.includes('.get(0)'),
      'Unexpected plot-option reader shape; review before patching');
  }
  assert.equal(stdevs.length,1,'Expected unique standard-deviation factory');
  assert.equal(tailMethods.length,1,'Expected unique live-tail method');
  const node=matches[0];
  const series=new Set();
  full(node,child=>{
    if(child.type==='MemberExpression'&&child.property.name==='from'&&child.object.type==='Identifier') series.add(child.object.name);
  });
  assert.equal(series.size,1);
  const template=await readFile('patches/ema.js','utf8');
  const replacement=template.replaceAll('__PATCH_NAME__',node.id.name).replaceAll('__SERIES__',[...series][0]);
  const parser=parsers[0];
  const bindings={__PATCH_NAME__:parser.id.name,__SERIES__:[...series][0]};
  full(parser,child=>{
    if(child.type==='MemberExpression'&&child.object.type==='Identifier') {
      if(child.property.name==='remaining_options') bindings.__TYPE_CHECK__=child.object.name;
      if(child.property.name==='has') bindings.__SCALAR_TYPES__=child.object.name;
    }
    if(child.type==='ArrowFunctionExpression'&&child.body.type==='LogicalExpression'
      &&child.body.left.type==='BinaryExpression'&&child.body.left.operator==='instanceof'
      &&child.body.right.type==='CallExpression') bindings.__SCALAR_HELPER__=child.body.right.callee.name;
  });
  for(const name of ['__TYPE_CHECK__','__SCALAR_TYPES__','__SCALAR_HELPER__']) assert.ok(bindings[name],name);
  const parserTemplate=await readFile('patches/params.js','utf8');
  let parserReplacement=parserTemplate;
  for(const [key,value] of Object.entries(bindings)) parserReplacement=parserReplacement.replaceAll(key,value);
  const lookup=lookups[0];
  const lookupTemplate=await readFile('patches/htf-index.js','utf8');
  const plotTemplate=await readFile('patches/plot-options.js','utf8');
  const stdev=stdevs[0];
  const windows=[];
  full(stdev,child=>{
    if(child.type==='CallExpression'&&child.callee.type==='Identifier'&&child.arguments.length===4) windows.push(child.callee.name);
  });
  assert.equal(new Set(windows).size,1,'Expected audited nonNaWindow dependency');
  const stdevTemplate=await readFile('patches/stdev.js','utf8');
  const stdevReplacement=stdevTemplate.replaceAll('__PATCH_NAME__',stdev.id.name)
    .replaceAll('__SERIES__',bindings.__SERIES__).replaceAll('__NON_NA_WINDOW__',windows[0]);
  const edits=[{node,text:replacement},{node:parser,text:parserReplacement},
    {node:lookup,text:lookupTemplate.replaceAll('__PATCH_NAME__',lookup.id.name)},
    ...plotOptionMethods.map(method=>({node:method,text:plotTemplate.replaceAll('__SERIES__',bindings.__SERIES__)})),
    {node:stdev,text:stdevReplacement}];
  const tail=tailMethods[0];
  const contextName=tail.value.params[0].name;
  const rollbacks=[];
  full(tail,child=>{
    if(child.type==='CallExpression'&&child.callee.type==='MemberExpression'
      &&child.callee.property.name==='rollbackDrawings') rollbacks.push(child);
  });
  assert.equal(rollbacks.length,1,'Expected audited rollback location');
  const rollback=rollbacks[0],from=rollback.arguments[0].name;
  const trim=`{const start=this.openTime[${from}];for(const [key,plot] of Object.entries(${contextName}.plots||{})){
    const style=plot.options?.style;
    if(style==='label'||style==='drawing_line'||style==='drawing_box'||style==='linefill'||style==='drawing_polyline'||style==='table'||!Array.isArray(plot.data))continue;
    while(plot.data.length&&plot.data[plot.data.length-1].time>=start)plot.data.pop();
  }}`;
  edits.push({node:{start:rollback.start,end:rollback.start},text:trim});
  if(type==='module') {
    edits.find(edit=>edit.node===parser).text+='\n'+code.slice(parser.start,parser.end)
      .replace('function '+parser.id.name+'(','function __stockdeckBaselineParams(');
    edits.find(edit=>edit.node===lookup).text+='\n'+code.slice(lookup.start,lookup.end)
      .replace('function '+lookup.id.name+'(','function __stockdeckBaselineHTF(');
  }
  let candidate=code;
  for(const edit of edits.sort((a,b)=>b.node.start-a.node.start)) candidate=candidate.slice(0,edit.node.start)+edit.text+candidate.slice(edit.node.end);
  if(type==='module') candidate+='\nexport const __pocInternals={parseArgs:'+parser.id.name+
    ',baselineParseArgs:__stockdeckBaselineParams,lookup:'+lookup.id.name+
    ',baselineLookup:__stockdeckBaselineHTF,Series:'+bindings.__SERIES__+'};\n';
  parse(candidate,{ecmaVersion:'latest',sourceType:type});
  await writeFile('local/candidate/'+output,candidate);
  manifest.artifacts[output]={baseSHA256:hash(code),patchedFactorySHA256:hash(code.slice(node.start,node.end)),
    patchSHA256:{ema:hash(template),params:hash(parserTemplate),htfIndex:hash(lookupTemplate),plotOptions:hash(plotTemplate),stdev:hash(stdevTemplate)},candidateSHA256:hash(candidate)};
}
await writeFile('local/candidate/patch-manifest.json',JSON.stringify(manifest,null,2));
console.log(JSON.stringify(manifest,null,2));
