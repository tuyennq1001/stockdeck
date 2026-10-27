(async () => {
  try {
    const job = JSON.parse(__pocJobJSON);
    const {PineTS} = PineTSLib;
    const internalStyles = new Set(['label','drawing_line','drawing_box','linefill','drawing_polyline','table']);
    const isOutput = ([, plot]) => !internalStyles.has(plot.options?.style);
    if (job.mode === 'hang-test') while (true) {} // Explicit test-only watchdog fixture.
    if (job.mode === 'capabilities') {
      __pocFinish(JSON.stringify({ok:true, globals:Object.fromEntries(
        ['fetch','XMLHttpRequest','WebSocket','process','require','webkit','readFile','load'].map(name=>[name,typeof globalThis[name]]))}));
      return;
    }
    const provider = {
      async getSymbolInfo() { return {tickerid:'BITSTAMP:BTCUSD',ticker:'BTCUSD',prefix:'BITSTAMP',
        type:'crypto',currency:'USD',basecurrency:'BTC',timezone:'Etc/UTC',session:'24x7'}; },
      async getMarketData(symbol, timeframe, limit, from, to) {
        if (!['BTCUSD','BITSTAMP:BTCUSD'].includes(symbol)) throw new Error('Uncaptured symbol');
        const data = job.datasets?.[timeframe];
        if (!data) throw new Error('Uncaptured timeframe '+timeframe);
        const selected = data.filter(bar=>(from==null||bar.closeTime>from)&&(to==null||bar.openTime<to));
        return limit==null?selected:selected.slice(-limit);
      }
    };
    const engines = [];
    const contexts = [];
    const before = performance.now();
    for(let i=0;i<(job.instances||1);i++) {
      const engine = job.datasets
        ? new PineTS(provider,'BTCUSD',job.timeframe,undefined,job.bars[0].openTime,job.bars.at(-1).closeTime)
        : new PineTS(job.bars);
      engine.setAlertMode('all');
      contexts.push(await (job.mode==='benchmark'?engine.update(job.source):engine.run(job.source)));
      engines.push(engine);
    }
    const replayMs = performance.now()-before;
    if (job.mode !== 'benchmark') {
      const result=contexts[0];
      const plots=Object.fromEntries(Object.entries(result.plots).filter(isOutput));
      __pocFinish(JSON.stringify({ok:true,ms:replayMs,bars:job.bars.length,plots,alerts:result.alerts}));
      return;
    }
    const normalize = context => Object.fromEntries(Object.entries(context.plots)
      .filter(isOutput).map(([key,plot])=>[key,{options:plot.options,
        data:plot.data.filter(point=>plot.options.style==='shape'?point.value===true:
          plot.options.style==='barcolor'?typeof point.options?.color==='string':Number.isFinite(point.value))
          .map(point=>({time:point.time,value:point.value,color:point.options?.color}))}]));
    const encodeStart=performance.now();
    let serialized=JSON.stringify(contexts.map(normalize));
    const encodeMs=performance.now()-encodeStart;
    const warm=[];
    for(let repeat=0;repeat<(job.warmRepeats||0);repeat++) {
      const start=performance.now();
      const cached=[];
      for(const engine of engines) cached.push(await engine.update(job.source));
      serialized=JSON.stringify(cached.map(normalize));
      warm.push(performance.now()-start);
    }
    __pocFinish(JSON.stringify({ok:true,bars:job.bars.length,instances:engines.length,replayMs,encodeMs,profile:globalThis.__pocProfile,
      outputCharacters:serialized.length,warmMs:warm,
      finitePoints:contexts.map(ctx=>Object.fromEntries(Object.entries(ctx.plots)
        .filter(isOutput).map(([key,plot])=>[key,plot.data.filter(x=>typeof x.value==='number'&&Number.isFinite(x.value)).length])))}));
  } catch (error) {
    __pocFinish(JSON.stringify({ok: false, error: String(error), stack: error.stack}));
  }
})();
