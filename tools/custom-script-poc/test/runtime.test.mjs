import test from 'node:test';
import assert from 'node:assert/strict';
import {PineTS} from 'pinets';

// Explicit TEST-ONLY arithmetic fixtures.
const bars=[1,3,5,7].map((close,i)=>({openTime:Date.UTC(2020,0,i+1),closeTime:Date.UTC(2020,0,i+2),
  open:close,high:close,low:close,close,volume:0}));
test('probe detects pinned runtime EMA seed incompatibility rather than masking it',async()=>{
  const context=await new PineTS(bars).run('//@version=6\nindicator("fixture")\nplot(ta.ema(close,3),title="EMA")');
  const values=context.plots.EMA.data.map(x=>x.value);
  assert.equal(Number.isNaN(values[0]),true);
  assert.equal(Number.isNaN(values[1]),true);
  assert.equal(values[2],3); // SMA seed; canonical first-source EMA would be 3.5.
});
test('Pine v6 comparison to variable holding na is false',async()=>{
  const context=await new PineTS(bars).run('//@version=6\nindicator("fixture")\nvar int a = na\nplot(a != bar_index ? 1 : 0,title="comparison")');
  assert.deepEqual(context.plots.comparison.data.map(x=>x.value),[0,0,0,0]);
});
test('invalid source fails without poisoning a separate subsequent job',async()=>{
  await assert.rejects(new PineTS(bars).run('//@version=6\nindicator("fixture")\nx = )'));
  const context=await new PineTS(bars).run('//@version=6\nindicator("fixture")\nplot(close,title="close")');
  assert.deepEqual(context.plots.close.data.map(x=>x.value),[1,3,5,7]);
});
test('var assignment is persistent across complete historical replay',async()=>{
  const context=await new PineTS(bars).run('//@version=6\nindicator("fixture")\nvar int count = 0\ncount := count + 1\nplot(count,title="count")');
  assert.deepEqual(context.plots.count.data.map(x=>x.value),[1,2,3,4]);
});
