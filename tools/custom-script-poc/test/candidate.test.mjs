import test from 'node:test';
import assert from 'node:assert/strict';
import {PineTS,__pocInternals} from '../local/candidate/pinets.es.mjs';
import {emaFirstValue} from '../reference.mjs';

// Every number below is an explicit arithmetic test fixture, never market data.
const candles=values=>values.map((close,i)=>({openTime:Date.UTC(2020,0,i+1),closeTime:Date.UTC(2020,0,i+2),
  open:close,high:close,low:close,close,volume:0}));

test('candidate EMA first-source seed, independent call sites and MACD share the correction',async()=>{
  const values=[1,3,5,7,4,2,10];
  const code='//@version=6\nindicator("fixture")\nplot(ta.ema(close,3),title="ema")\nplot(ta.ema(close*2,3),title="double")\n[m,s,h] = ta.macd(close,2,3,2)\nplot(m,title="macd")\nplot(s,title="signal")';
  const ctx=await new PineTS(candles(values)).run(code);
  const near=(actual,expected)=>actual.forEach((row,i)=>assert.ok(Math.abs(row.value-expected[i])<1e-8));
  near(ctx.plots.ema.data,emaFirstValue(values,3));
  near(ctx.plots.double.data,emaFirstValue(values.map(x=>x*2),3));
  const fast=emaFirstValue(values,2),slow=emaFirstValue(values,3),macd=fast.map((x,i)=>x-slow[i]);
  near(ctx.plots.macd.data,macd);
  near(ctx.plots.signal.data,emaFirstValue(macd,2));
});

test('candidate EMA ignores a missing source observation and does not reset the seed',async()=>{
  const code='//@version=6\nindicator("fixture")\nsrc = bar_index == 1 ? na : close\nplot(ta.ema(src,3),title="ema")';
  const ctx=await new PineTS(candles([1,3,5,7])).run(code);
  assert.deepEqual(ctx.plots.ema.data.map(x=>x.value),[1,1,3,5]);
});

test('optimized argument parser preserves baseline named/positional/type behavior',()=>{
  const {Series,parseArgs,baselineParseArgs}=__pocInternals;
  const values=[1,NaN,'title',true,null,undefined,new Series([1]),new Series(['text']),
    {color:'#123456',width:2},[1,2],{__value:NaN},
    {_plotKey:'line',title:'line',data:[],options:{}}];
  const signatures=[['value','title','color'],[['value'],['value','title'],['value','color','width']],
    Array.from({length:35},()=>['value','title','color'])];
  const types={value:'series',title:'string',color:'color',width:'number'};
  for(const sig of signatures) for(const a of values) for(const b of values) for(const c of values) {
    const args=[a,b,c];
    assert.deepEqual(parseArgs(args,sig,types,{width:9}),baselineParseArgs(args,sig,types,{width:9}));
  }
  assert.deepEqual(parseArgs([new Series([2]),{title:new Series(['named'])}],['value','title'],types),
    baselineParseArgs([new Series([2]),{title:new Series(['named'])}],['value','title'],types));
  const many=Array.from({length:35},(_,i)=>['value','name'+i]);
  const manyTypes={value:'series',...Object.fromEntries(many.map((sig)=>[sig[1],'string']))};
  assert.deepEqual(parseArgs([1,'label'],many,manyTypes),baselineParseArgs([1,'label'],many,manyTypes));
});

test('binary HTF mapping preserves baseline at gaps, close boundaries and live/lookahead modes',()=>{
  const {lookup,baselineLookup}=__pocInternals;
  const opens=Array.from({length:50},(_,i)=>i*10),closes=opens.map(x=>x+7);
  for(let open=-5;open<=510;open++) for(const close of [open,open+1,open+7,open+15])
    for(const lookahead of [false,true]) for(const realtime of [false,true])
      assert.equal(lookup(open,close,opens,closes,lookahead,realtime),
        baselineLookup(open,close,opens,closes,lookahead,realtime));
  assert.equal(lookup(0,1,[],[],false,false),-1);
});

test('candidate EMA maintains its state across paginated replay',async()=>{
  const values=Array.from({length:501},(_,i)=>i%11+1);
  const source='//@version=6\nindicator("fixture")\nplot(ta.ema(close,200),title="ema")';
  const full=await new PineTS(candles(values)).run(source);
  let last;
  for await(const page of new PineTS(candles(values)).run(source,undefined,73)) last=page;
  // Paginated plot output is cumulative; use timestamps to reject duplicate/missing bars.
  assert.deepEqual(last.plots.ema.data,full.plots.ema.data);
});

test('incremental stdev matches independent windows through na, changing period and sample bias',async()=>{
  const values=Array.from({length:1500},(_,i)=>100000+(i%17)*13+(i%5)*0.37);
  const source='//@version=6\nindicator("fixture")\nsrc = bar_index % 7 == 0 ? na : close\nlen = bar_index < 500 ? 20 : 50\nplot(ta.stdev(src,len),title="population")\nplot(ta.stdev(src,len,false),title="sample")';
  const context=await new PineTS(candles(values)).run(source);
  const observations=[];
  for(let i=0;i<values.length;i++) {
    if(i%7!==0) observations.push(values[i]);
    const length=i<500?20:50;
    for(const [key,bias] of [['population',true],['sample',false]]) {
      const actual=context.plots[key].data[i].value;
      if(observations.length<length) {assert.ok(Number.isNaN(actual));continue;}
      const window=observations.slice(-length);
      const mean=window.reduce((sum,x)=>sum+x,0)/length;
      const expected=Math.sqrt(window.reduce((sum,x)=>sum+(x-mean)**2,0)/(bias?length:length-1));
      assert.ok(Math.abs(actual-expected)<=1e-8+1e-6*Math.abs(expected),`${key} at ${i}: ${actual} vs ${expected}`);
    }
  }
});

test('incremental stdev does not invent variance for a constant series',async()=>{
  const source='//@version=6\nindicator("fixture")\nplot(ta.stdev(close,20),title="stdev")';
  const ctx=await new PineTS(candles(new Array(500).fill(1000000))).run(source);
  assert.ok(ctx.plots.stdev.data.slice(19).every(x=>x.value===0));
});

test('EMA/stdev and var state survive repeated live-tail updates and a newly appended bar',async t=>{
  let data=candles(Array.from({length:250},(_,i)=>100+(i%13)));
  let now=data.at(-1).openTime+12*3600000;
  t.mock.method(Date,'now',()=>now);
  const provider={async getSymbolInfo(){return {tickerid:'TEST',timezone:'Etc/UTC',session:'24x7'};},
    async getMarketData(symbol,timeframe,limit,from,to){return data.filter(x=>(from==null||x.closeTime>from)
      &&(to==null||x.openTime<=to)).map(x=>({...x}));}};
  const source='//@version=6\nindicator("fixture")\nvar int count = 0\ncount := count + 1\nplot(count,title="count")\nplot(ta.ema(close,200),title="ema")\nplot(ta.stdev(close,20),title="stdev")\nplot(close,title="__custom")\nalertcondition(close>0,title="fixture",message="fixture")';
  const createEngine=()=>{const engine=new PineTS(provider,'TEST','D');engine.setAlertMode('all');return engine;};
  const engine=createEngine();
  const context=await engine.run(source);
  for(const close of [90,120,105]) {
    data=data.map((bar,i)=>i===data.length-1?{...bar,close,low:Math.min(bar.open,close),high:Math.max(bar.open,close)}:bar);
    await engine.updateTail(context);
    const replay=await createEngine().run(source);
    for(const key of ['count','ema','stdev','__custom']) assert.deepEqual(context.plots[key].data,replay.plots[key].data);
    assert.deepEqual(context.alerts,replay.alerts);
  }
  const previous=data.at(-1);
  data=[...data,{...previous,openTime:previous.closeTime,closeTime:previous.closeTime+86400000,open:105,close:108,low:105,high:108}];
  now=data.at(-1).openTime+12*3600000;
  await engine.updateTail(context);
  const replay=await createEngine().run(source);
  for(const key of ['count','ema','stdev','__custom']) assert.deepEqual(context.plots[key].data,replay.plots[key].data);
  assert.deepEqual(context.alerts,replay.alerts);
});
