/* Per-script rendering. Input order also defines deterministic candle-color precedence. */
class StockDeckPineChart {
  static compare(a,b) { return a.time < b.time ? -1 : a.time > b.time ? 1 : 0; }
  constructor(chart, api, candles, {dark = true} = {}) {
    this.chart = chart; this.api = api; this.candles = candles; this.records = new Map();
    this.dark = dark; this.palette = new Map();
  }
  setDarkMode(dark) { this.dark = dark; this.palette.clear(); }
  displayColor(source, overrides = {}) {
    if (typeof overrides[source] === 'string') return overrides[source];
    if (this.dark || typeof source !== 'string') return source;
    if (this.palette.has(source)) return this.palette.get(source);
    const normalized = source.trim().toLowerCase();
    let color = source, match;
    // Source white is invisible on a light chart. Keep alpha and saved Style choices intact.
    if (normalized === 'white') color = '#475569';
    else if ((match = normalized.match(/^#ffffff([0-9a-f]{2})?$/))) color = '#475569' + (match[1] || '');
    else if ((match = normalized.match(/^#fff([0-9a-f])?$/))) color = '#475569' + (match[1] ? match[1].repeat(2) : '');
    else if ((match = normalized.match(/^rgba?\(\s*255\s*,\s*255\s*,\s*255\s*(?:,\s*([\d.]+)\s*)?\)$/))) {
      color = match[1] == null ? '#475569' : `rgba(71, 85, 105, ${match[1]})`;
    }
    if (this.palette.size >= 256) this.palette.clear();
    this.palette.set(source, color);
    return color;
  }
  remove(id) {
    const record = this.records.get(id);
    if (!record) return;
    record.markers?.setMarkers([]);
    for (const series of record.series.values()) this.chart.removeSeries(series);
    if (record.anchor) this.chart.removeSeries(record.anchor);
    this.records.delete(id);
  }
  clear() { for (const id of [...this.records.keys()]) this.remove(id); }
  paneKey(index) {
    for (const [id, record] of this.records) if (record.anchor?.getPane().paneIndex() === index) return `Pine:${id}`;
    return null;
  }
  constrainPaneSizes(focusMode = false) {
    if (focusMode) return false;
    const panes = this.chart.panes();
    if (panes.length < 2) return false;
    const priceFactor = panes[0].getStretchFactor();
    let sumOther = 0;
    for (let index = 0; index < panes.length; index++) {
      if (!this.paneKey(index)) sumOther += panes[index].getStretchFactor();
    }
    let limit = Math.min(priceFactor / 4, sumOther * 0.25);
    for (let index = 1; index < panes.length; index++) {
      if (!this.paneKey(index)) limit = Math.min(limit, panes[index].getStretchFactor());
    }
    let changed = false;
    for (const record of this.records.values()) {
      if (!record.anchor) continue;
      const pane = record.anchor.getPane();
      if (pane.getStretchFactor() > limit + 0.001) {
        pane.setStretchFactor(limit); changed = true;
      }
    }
    return changed;
  }
  update(indicators, payload, showCandles, {paneLayout = {}, focusMode = false} = {}) {
    const active = indicators.filter(item => item.status === 'loaded' && item.symbol === payload.symbol && item.interval === payload.interval);
    const keep = new Set(active.map(item => item.id)), overlayMarkers = [], barColors = new Map();
    const intraday = /h$|m$/.test(payload.interval), barTimes = new Set(payload.bars.map(bar => String(bar.time)));
    for (const id of [...this.records.keys()]) if (!keep.has(id)) this.remove(id);
    for (const item of active) {
      if (this.records.get(item.id)?.overlay !== item.overlay) this.remove(item.id);
      let record = this.records.get(item.id);
      if (!record) {
        record = { overlay: item.overlay, series: new Map(), anchor: null, markers: null };
        if (!item.overlay) record.anchor = this.chart.addSeries(this.api.LineSeries,
          {color:'transparent',lineVisible:false,lastValueVisible:false,priceLineVisible:false,crosshairMarkerVisible:false}, this.chart.panes().length);
        this.records.set(item.id, record);
        const savedFactor = paneLayout[`Pine:${item.id}`];
        const scale = Number.isFinite(paneLayout.Price) && paneLayout.Price > 0 ? this.chart.panes()[0].getStretchFactor() / paneLayout.Price : 1;
        if (record.anchor && Number.isFinite(savedFactor) && savedFactor > 0) record.anchor.getPane().setStretchFactor(savedFactor * scale);
      }
      const timeFor = point => {
        const raw = Number(point.time);
        // The helper emits milliseconds. Exact secondary lookup also accepts legacy seconds.
        const mapped = item.timeMap?.[String(Math.floor(raw / 1000))] ?? item.timeMap?.[String(Math.floor(raw))];
        if (mapped == null) return null;
        const time = intraday ? Number(mapped) : mapped;
        return barTimes.has(String(time)) ? time : null;
      };
      const keys = new Set(), paneMarkers = [];
      let anchorPoints = null;
      for (const plot of item.plots || []) {
        const key = String(plot.plotID || plot.title), colors = plot.displayColorOverrides || {}, visible = plot.displayVisible !== false;
        const colorFor = point => this.displayColor(point.color || plot.color || '#16816d', colors);
        if (plot.style === 'line' || plot.style === 'hline') {
          keys.add(key);
          let series = record.series.get(key);
          const color = this.displayColor(plot.color || '#16816d', colors);
          if (!series) {
            series = this.chart.addSeries(this.api.LineSeries, {color,priceLineVisible:false}, record.anchor ? record.anchor.getPane().paneIndex() : 0);
            record.series.set(key, series);
          }
          const values = new Map();
          if (visible) for (const point of plot.points || []) {
            const time = timeFor(point);
            if (time != null && Number.isFinite(point.value)) values.set(String(time), {time,value:point.value,color:colorFor(point)});
          }
          const points = [...values.values()].sort(StockDeckPineChart.compare);
          series.applyOptions({color,lineWidth:Math.max(1, Math.min(4, plot.displayLineWidth || plot.lineWidth || 2))});
          series.setData(points);
          if (visible && !anchorPoints && points.length) anchorPoints = points;
        }
        if (!visible || !['shape','barcolor'].includes(plot.style)) continue;
        for (const point of plot.points || []) {
          const time = timeFor(point);
          if (time == null) continue;
          if (plot.style === 'barcolor' && point.color) barColors.set(String(time), colorFor(point));
          if (plot.style === 'shape' && point.shape) {
            const shape = (plot.displayMarkerShape || point.markerShape || '').toLowerCase();
            const marker = {time, color:colorFor(point),
              position:(plot.displayPosition || point.position || '').toLowerCase().includes('above') ? 'aboveBar' : 'belowBar',
              shape:/down/.test(shape) ? 'arrowDown' : /square/.test(shape) ? 'square' : /circle/.test(shape) ? 'circle' : 'arrowUp'};
            (item.overlay ? overlayMarkers : paneMarkers).push(marker);
          }
        }
      }
      for (const [key, series] of record.series) if (!keys.has(key)) { this.chart.removeSeries(series); record.series.delete(key); }
      if (record.anchor) {
        record.anchor.setData(anchorPoints || [...new Map(paneMarkers.map(marker => [String(marker.time),{time:marker.time,value:0}])).values()]
          .sort(StockDeckPineChart.compare));
        paneMarkers.sort(StockDeckPineChart.compare);
        if (record.markers) record.markers.setMarkers(paneMarkers);
        else if (paneMarkers.length) record.markers = this.api.createSeriesMarkers(record.anchor, paneMarkers);
      }
    }
    if (showCandles) this.candles.setData(payload.bars.filter(bar => [bar.open,bar.high,bar.low].every(Number.isFinite)).map(bar => {
      const color = barColors.get(String(bar.time));
      return color ? {...bar,color,wickColor:color,borderColor:color} : bar;
    }));
    this.constrainPaneSizes(focusMode);
    overlayMarkers.sort(StockDeckPineChart.compare);
    return overlayMarkers;
  }
}
if (typeof module !== 'undefined') module.exports = StockDeckPineChart;
