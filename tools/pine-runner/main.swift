import Foundation
import JavaScriptCore

struct Bar: Codable {
    let openTime: Double
    let closeTime: Double
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double?
}

struct Job: Codable {
    let symbol: String
    let timezone: String
    let currency: String
    let source: String
    let timeframe: String
    let bars: [Bar]
    let datasets: [String: [Bar]]
}

struct Result: Codable {
    let ok: Bool
    var error: String?
    var title: String? = nil
    var plots: [String: Plot]?
    var alertCount: Int? = nil
    var overlay: Bool? = nil
}

struct Plot: Codable {
    let style: String?
    let title: String?
    let color: String?
    let points: [Point]
    let sourceOrder: Int?
    let isUnnamed: Bool?
    let lineWidth: Int?
}

struct Point: Codable {
    let time: Double
    let value: Double?
    let color: String?
    let shape: Bool?
    let state: Bool?
    let position: String?
    let markerShape: String?
}

func emit(_ result: Result, status: Int32 = 0) -> Never {
    let data = (try? JSONEncoder().encode(result)) ?? Data("{\"ok\":false,\"error\":\"encoding failed\"}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
    exit(status)
}

guard let input = try? FileHandle.standardInput.readToEnd(), input.count <= 64_000_000,
      let job = try? JSONDecoder().decode(Job.self, from: input),
      !job.source.isEmpty, job.source.utf8.count <= 128_000,
      (1...20_000).contains(job.bars.count) else {
    emit(Result(ok: false, error: "Input vượt giới hạn hoặc không hợp lệ."), status: 64)
}

let bundle = Bundle.module
guard let runtimeURL = bundle.url(forResource: "pinets.browser", withExtension: "js", subdirectory: "PineTS"),
      let runtime = try? String(contentsOf: runtimeURL, encoding: .utf8) else {
    emit(Result(ok: false, error: "Không tìm thấy PineTS runtime."), status: 66)
}

let context = JSContext()!
var output: String?
var exception: String?
context.exceptionHandler = { _, value in exception = value?.toString() }
let finish: @convention(block) (String) -> Void = { value in output = value }
context.setObject(finish, forKeyedSubscript: "__finish" as NSString)
context.setObject(String(data: input, encoding: .utf8), forKeyedSubscript: "__jobJSON" as NSString)
context.evaluateScript("globalThis.console={log(){},warn(){},error(){}};globalThis.performance={now:()=>Date.now()};")
context.evaluateScript(runtime)
if let exception { emit(Result(ok: false, error: String(exception.prefix(500))), status: 1) }
context.evaluateScript(#"""
(async()=>{
 try {
  const job=JSON.parse(__jobJSON),datasets=job.datasets;
  const normalize=tf=>({"1D":"D","1W":"W","1M":"M","1Y":"12M","Y":"12M"}[String(tf)]||String(tf));
  const canonical=s=>String(s).toUpperCase().split(':').at(-1).replace(/[-/]/g,'');
  const provider={async getSymbolInfo(){return {tickerid:job.symbol,main_tickerid:job.symbol,ticker:job.symbol,prefix:'',root:job.symbol,type:'stock',currency:job.currency,timezone:job.timezone,session:'24x7'};},async getMarketData(symbol,timeframe,limit,from,to){if(canonical(symbol)!==canonical(job.symbol))throw new Error('Chỉ hỗ trợ request.security() cho cùng symbol.');const data=datasets[normalize(timeframe)];if(!data)throw new Error('Không có dữ liệu cho timeframe '+timeframe);let selected=data.filter(bar=>(from==null||bar.closeTime>from)&&(to==null||bar.openTime<to));if(limit!=null)selected=selected.slice(-limit);return selected;}};
  const timeframe=job.timeframe,mainBars=job.bars;
  const engine=new PineTSLib.PineTS(provider,job.symbol,timeframe,undefined,mainBars[0].openTime,mainBars.at(-1).closeTime);engine.setAlertMode('all');
  const context=await engine.run(job.source), out={};
  const internal=new Set(['label','drawing_line','drawing_box','linefill','drawing_polyline','table']);
  for(const [sourceOrder,[name,plot]] of Object.entries(context.plots||{}).entries()){
   if(name.startsWith('__')||internal.has(plot.options?.style)) continue;
   const rawStyle=plot.options?.style||'line',style=rawStyle.startsWith('style_')?rawStyle.slice(6):rawStyle;
   const points=[];
    const data=style==='fill'?[]:(plot.data||[]).slice(-2500);
   for(const point of data){
    const state=typeof point.value==='boolean'?point.value:null,shape=state===true;
    const value=typeof point.value==='number'&&Number.isFinite(point.value)?point.value:null;
    const color=typeof point.options?.color==='string'?point.options.color:null;
    if(value!==null||color!==null||state!==null) points.push({time:point.time,value,color,shape,state,position:point.options?.location||null,markerShape:point.options?.shape||point.options?.style||null});
   }
   if(points.length>20000) throw new Error('Plot vượt 20.000 điểm.');
   const lineWidth=Number(plot.options?.linewidth);
   out[name]={style,title:plot.title||plot.options?.title||name,color:plot.options?.color||null,points,sourceOrder,isUnnamed:!(plot.title||plot.options?.title),lineWidth:Number.isFinite(lineWidth)&&lineWidth>0?Math.round(lineWidth):null};
  }
  const overlay=!/\boverlay\s*=\s*false\b/i.test(job.source);
  const title=job.source.match(/\bindicator\s*\(\s*["']([^"']+)["']/i)?.[1]||null;
  __finish(JSON.stringify({ok:true,title,plots:out,alertCount:(context.alerts||[]).length,overlay}));
 }catch(e){__finish(JSON.stringify({ok:false,error:String(e?.message||e).slice(0,500)}));}
})();
"""#)

let deadline = Date().addingTimeInterval(6.0)
while output == nil && exception == nil && Date() < deadline {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
}
if let exception { emit(Result(ok: false, error: String(exception.prefix(500))), status: 1) }
guard let output, output.utf8.count <= 4_000_000, let data = output.data(using: .utf8),
      let result = try? JSONDecoder().decode(Result.self, from: data) else {
    emit(Result(ok: false, error: "Script quá chậm hoặc output không hợp lệ."), status: 124)
}
emit(result, status: result.ok ? 0 : 1)
