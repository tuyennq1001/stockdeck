import test from 'node:test';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
const Renderer=require('../../../StockDeck/Resources/CustomPineChart.js');

// Explicit chart-API fixtures for testing independent script lifecycle, not market data.
function fixture(){
  const chart={groups:[[]],height:600,panes(){return this.groups.map(group=>({paneIndex:()=>this.groups.indexOf(group),
    getStretchFactor:()=>group.factor??1,setStretchFactor:value=>{group.factor=value},
    getHeight:()=>this.height*(group.factor??1)/this.groups.reduce((sum,g)=>sum+(g.factor??1),0)}));},
    addSeries(type,options,index=0){while(this.groups.length<=index)this.groups.push([]);const group=this.groups[index];
      const series={options,data:[],getPane:()=>chart.panes()[chart.groups.indexOf(group)],applyOptions(value){Object.assign(this.options,value)},setData(value){this.data=value}};
      group.push(series);return series;},
    removeSeries(series){const group=this.groups.find(group=>group.includes(series));assert.ok(group,'series removed once');group.splice(group.indexOf(series),1);if(!group.length&&this.groups.indexOf(group)>0)this.groups.splice(this.groups.indexOf(group),1);}};
  const api={LineSeries:'line',createSeriesMarkers(series,markers){const primitive={markers,setMarkers(value){this.markers=value}};series.markers=primitive;return primitive;}};
  const candles=chart.addSeries('candles',{});
  const payload={symbol:'AAPL',interval:'1D',bars:[{time:'2026-01-02',open:100,high:103,low:99,close:102}]};
  const renderer=new Renderer(chart,api,candles);
  const point={time:1767312000000,value:101,shape:true,color:'#FFA500',markerShape:'triangleup',position:'belowbar'};
  const item=id=>({id,title:'same title',symbol:'AAPL',interval:'1D',status:'loaded',overlay:true,timeMap:{1767312000:'2026-01-02'},plots:[{plotID:'same plot',title:'same plot',style:'line',points:[point]}]});
  return{chart,renderer,payload,candles,item,point};
}

test('same plot names remain independent and removing one keeps the other',()=>{
  const f=fixture(),a=f.item('a'),b=f.item('b');f.renderer.update([a,b],f.payload,true);
  assert.equal(f.renderer.records.size,2);assert.equal(f.chart.groups[0].length,3);
  const other=f.renderer.records.get('b').series.get('same plot');
  f.renderer.update([b],f.payload,true);assert.equal(f.renderer.records.size,1);assert.equal(other.data[0].value,101);
  assert.equal(f.chart.groups[0].length,2);
});
test('separate panes survive earlier pane removal and builtin rebuilding',()=>{
  const f=fixture(),a={...f.item('a'),overlay:false},b={...f.item('b'),overlay:false};
  f.renderer.update([a,b],f.payload,true);assert.equal(f.chart.panes().length,3);
  f.renderer.update([b],f.payload,true);assert.equal(f.chart.panes().length,2);
  assert.equal(f.renderer.records.get('b').anchor.getPane().paneIndex(),1);
  f.renderer.clear();assert.equal(f.chart.panes().length,1);
  f.chart.addSeries('builtin',{},1);f.renderer.update([b],f.payload,true);
  assert.equal(f.renderer.records.get('b').anchor.getPane().paneIndex(),2);
});
test('custom pane uses at most one indicator slot with fractional saved weights',()=>{
  const f=fixture(),a={...f.item('risk'),overlay:false};
  f.chart.addSeries('rsi',{},1);f.chart.addSeries('macd',{},2);
  for(const [i,value]of [0.7,0.15,0.15].entries())f.chart.panes()[i].setStretchFactor(value);
  f.renderer.update([a],f.payload,true);
  const pane=f.renderer.records.get('risk').anchor.getPane();
  assert.equal(pane.getStretchFactor(),0.15);
  assert.ok(pane.getHeight()<=f.chart.panes()[1].getHeight());
  assert.ok(pane.getHeight()<=f.chart.height*0.2);
  assert.equal(f.renderer.paneKey(pane.paneIndex()),'Pine:risk');
});
test('small saved custom panes survive updates, rebuilding and viewport resize',()=>{
  const f=fixture(),a={...f.item('risk'),overlay:false};
  const options={paneLayout:{'Pine:risk':0.05}};
  f.renderer.update([a],f.payload,true,options);
  assert.equal(f.renderer.records.get('risk').anchor.getPane().getStretchFactor(),0.05);
  f.chart.height=1200;f.renderer.update([a],f.payload,true,options);
  assert.ok(f.renderer.records.get('risk').anchor.getPane().getHeight()<=f.chart.height*0.2);
  f.renderer.clear();f.renderer.update([a],f.payload,true,options);
  assert.equal(f.renderer.records.get('risk').anchor.getPane().getStretchFactor(),0.05);
});
test('oversized panes clamp after drag while explicit focus mode can enlarge a pane',()=>{
  const f=fixture(),a={...f.item('risk'),overlay:false},b={...f.item('other'),overlay:false};
  f.renderer.update([a,b],f.payload,true,{paneLayout:{'Pine:risk':20}});
  const pane=f.renderer.records.get('risk').anchor.getPane();
  assert.equal(pane.getStretchFactor(),0.25);
  pane.setStretchFactor(20);f.renderer.update([a,b],f.payload,true,{focusMode:true});
  assert.equal(pane.getStretchFactor(),20);
  f.renderer.constrainPaneSizes();assert.equal(pane.getStretchFactor(),0.25);
  f.renderer.update([b],f.payload,true);
  assert.equal(f.renderer.paneKey(1),'Pine:other');
  f.renderer.clear();assert.equal(f.renderer.paneKey(1),null);
});
test('last attached candle color wins, hidden and removed scripts restore earlier colors',()=>{
  const f=fixture(),a=f.item('a'),b=f.item('b');
  a.plots[0].style=b.plots[0].style='barcolor';b.plots[0].points=[{...f.point,color:'#FF0000'}];
  f.renderer.update([a,b],f.payload,true);assert.equal(f.candles.data[0].color,'#FF0000');
  b.plots[0].displayVisible=false;f.renderer.update([a,b],f.payload,true);assert.equal(f.candles.data[0].color,'#FFA500');
  f.renderer.update([],f.payload,true);assert.equal(f.candles.data[0].color,undefined);
});
test('markers, colors and line widths honor per-script overrides and exact timestamps',()=>{
  const f=fixture(),a=f.item('a');a.plots.push({...a.plots[0],plotID:'shape',style:'shape',displayPosition:'abovebar',displayMarkerShape:'circle',displayColorOverrides:{'#FFA500':'#123456'}});
  a.plots[0].displayLineWidth=4;
  let markers=f.renderer.update([a],f.payload,true);assert.equal(markers.length,1);assert.equal(markers[0].position,'aboveBar');assert.equal(markers[0].color,'#123456');assert.equal(markers[0].shape,'circle');
  assert.equal(f.renderer.records.get('a').series.get('same plot').options.lineWidth,4);
  a.timeMap={};markers=f.renderer.update([a],f.payload,true);assert.equal(markers.length,0);
});
test('source line width survives rendering, overrides and restoring defaults',()=>{
  const f=fixture(),a=f.item('a');a.plots[0].lineWidth=1;
  const width=()=>f.renderer.records.get('a').series.get('same plot').options.lineWidth;
  f.renderer.update([a],f.payload,true);assert.equal(width(),1);
  a.plots[0].displayLineWidth=4;f.renderer.update([a],f.payload,true);assert.equal(width(),4);
  delete a.plots[0].displayLineWidth;f.renderer.update([a],f.payload,true);assert.equal(width(),1);
});
test('symbol/interval mismatch and clear leave no stale Pine drawing or panes',()=>{
  const f=fixture(),a={...f.item('a'),overlay:false};f.renderer.update([a],f.payload,true);
  f.renderer.update([a],{...f.payload,symbol:'MSFT'},true);assert.equal(f.renderer.records.size,0);assert.equal(f.chart.panes().length,1);
  f.renderer.update([a],{...f.payload,interval:'1W'},true);assert.equal(f.renderer.records.size,0);
  f.renderer.update([a],f.payload,true);f.renderer.clear();assert.equal(f.chart.panes().length,1);
});
test('Pine updates never re-enable candles in a line chart',()=>{
  const f=fixture();f.candles.setData([]);f.renderer.update([f.item('a')],f.payload,false);assert.deepEqual(f.candles.data,[]);
});
test('pre-2001 millisecond timestamps use exact map lookup rather than magnitude guessing',()=>{
  const f=fixture(),a=f.item('a');
  f.payload.bars[0].time='1980-12-12';a.timeMap={'345427200':'1980-12-12'};
  a.plots[0].points=[{...f.point,time:345427200000}];
  f.renderer.update([a],f.payload,true);
  assert.equal(f.renderer.records.get('a').series.get('same plot').data[0].time,'1980-12-12');
});
test('source white remains visible in a light pane and theme changes preserve Risk values',()=>{
  const f=fixture(),a={...f.item('a'),overlay:false};
  a.plots[0].color='#FFFFFF';a.plots[0].points=[{...f.point,value:0.93,color:'#FFFFFF'}];
  f.renderer.setDarkMode(false);f.renderer.update([a],f.payload,true);
  const series=f.renderer.records.get('a').series.get('same plot');
  assert.equal(series.options.color,'#475569');assert.equal(series.data[0].color,'#475569');
  assert.equal(series.data[0].value,0.93);assert.equal(a.plots[0].points[0].color,'#FFFFFF');
  f.renderer.setDarkMode(true);f.renderer.update([a],f.payload,true);
  assert.equal(series.data[0].color,'#FFFFFF');assert.equal(series.data[0].value,0.93);
});
test('white contrast preserves transparency, other colors and explicit Style overrides',()=>{
  const f=fixture();f.renderer.setDarkMode(false);
  for(const color of ['#fff','#FFFFFF','white','rgb(255, 255, 255)'])assert.equal(f.renderer.displayColor(color),'#475569');
  assert.equal(f.renderer.displayColor('#ffffff1a'),'#4755691a');
  assert.equal(f.renderer.displayColor('#fff8'),'#47556988');
  assert.equal(f.renderer.displayColor('rgba(255, 255, 255, 0.4)'),'rgba(71, 85, 105, 0.4)');
  assert.equal(f.renderer.displayColor('#FF0000'),'#FF0000');
  assert.equal(f.renderer.displayColor('#FFFFFF',{'#FFFFFF':'#FFFFFF'}),'#FFFFFF');
  assert.equal(f.renderer.displayColor('#FFFFFF',{'#FFFFFF':'#123456'}),'#123456');
  const a=f.item('a');a.plots[0].points=[{...f.point,color:'#FFFFFF'}];a.plots[0].displayColorOverrides={'#FFFFFF':'#123456'};
  f.renderer.update([a],f.payload,true);
  assert.equal(f.renderer.records.get('a').series.get('same plot').data[0].color,'#123456');
});
