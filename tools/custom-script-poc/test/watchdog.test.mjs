import test from 'node:test';
import assert from 'node:assert/strict';
import {writeFile,rm} from 'node:fs/promises';
import {runNative} from '../supervisor.mjs';

test('external watchdog kills a stuck helper and another job still runs',async()=>{
  const filename=`local/watchdog-${process.pid}.json`;
  try {
    await writeFile(filename,JSON.stringify({mode:'hang-test'}));
    const hung=await runNative(filename,1000);
    assert.equal(hung.timedOut,true);
    assert.ok(hung.wallMs<5000);
    await writeFile(filename,JSON.stringify({mode:'capabilities'}));
    const next=await runNative(filename);
    assert.equal(next.output?.ok,true);
    assert.ok(Object.values(next.output.globals).every(x=>x==='undefined'));
  } finally {await rm(filename,{force:true});}
});

test('native output preserves user plot names beginning with double underscores',async()=>{
  const filename=`local/output-${process.pid}.json`;
  try {
    // Explicit arithmetic fixture; never presented as market data.
    const bars=[{openTime:1577836800000,closeTime:1577923200000,open:2,high:2,low:2,close:2,volume:1}];
    await writeFile(filename,JSON.stringify({source:'//@version=6\nindicator("fixture")\nplot(close,title="__custom")',bars}));
    const result=await runNative(filename);
    assert.equal(result.output?.ok,true);
    assert.equal(result.output.plots.__custom.data.length,1);
    assert.equal(result.output.plots.__custom.data[0].value,2);
  } finally {await rm(filename,{force:true});}
});
