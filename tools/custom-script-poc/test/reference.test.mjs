import test from 'node:test';
import assert from 'node:assert/strict';
import {emaFirstValue, compareNumbers} from '../reference.mjs';
import {weeklyBars, offlineProvider} from '../market-data.mjs';

// All numbers in this file are explicit arithmetic TEST FIXTURES, never market data.
test('canonical EMA starts with first source value and uses alpha=2/(period+1)',()=>{
  assert.deepEqual(emaFirstValue([10,20,30],3),[10,15,22.5]);
});
test('numeric comparison distinguishes missing data, tolerance and timestamps',()=>{
  assert.equal(compareNumbers([{time:1,value:10.000001}],[{time:1,value:10}]).pass,true);
  assert.equal(compareNumbers([{time:1,value:NaN}],[{time:1,value:10}]).naMismatches,1);
  assert.equal(compareNumbers([{time:2,value:10}],[{time:1,value:10}]).timeMismatches,1);
  assert.equal(compareNumbers([{time:1,value:NaN}],[{time:1,value:NaN}]).pass,true);
});
test('weekly grouping uses UTC Monday and spot OHLC aggregation',()=>{
  const monday=Date.UTC(2020,0,6);
  const bars=[0,1,7].map((day,i)=>({openTime:monday+day*86400000,closeTime:monday+(day+1)*86400000,
    open:10+i,high:20+i,low:5+i,close:15+i,volume:1}));
  const weeks=weeklyBars(bars);
  assert.equal(weeks.length,2);
  assert.deepEqual(weeks[0],{openTime:monday,closeTime:monday+7*86400000,open:10,high:21,low:5,close:16,volume:2});
});
test('offline provider fails closed for absent symbols and intervals',async()=>{
  const provider=offlineProvider([]);
  await assert.rejects(provider.getMarketData('ETHUSD','D'),/Uncaptured symbol/);
  await assert.rejects(provider.getMarketData('BTCUSD','5'),/Uncaptured interval/);
});
