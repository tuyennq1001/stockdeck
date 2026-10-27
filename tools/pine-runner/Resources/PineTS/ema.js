function __PATCH_NAME__(context) {
  return (source, length, callId) => {
    const period = __SERIES__.from(length).get(0);
    if (!Number.isInteger(period) || period < 1) throw new Error('EMA length must be a positive integer');
    context.taState ||= {};
    const key = callId || `ema_${period}`;
    const state = context.taState[key] ||= {lastIdx: -1, committed: NaN, current: NaN};
    if (context.idx > state.lastIdx) {
      if (state.lastIdx >= 0) state.committed = state.current;
      state.lastIdx = context.idx;
    }
    const value = __SERIES__.from(source).get(0);
    // Ignore missing source observations, keeping the last valid EMA.
    if (value == null || Number.isNaN(value)) {
      state.current = state.committed;
      return Number.isFinite(state.current) ? context.precision(state.current) : NaN;
    }
    const alpha = 2 / (period + 1);
    state.current = Number.isFinite(state.committed)
      ? alpha * value + (1 - alpha) * state.committed : value;
    return context.precision(state.current);
  };
}
