function __PATCH_NAME__(context) {
  return (source, lengthArg, ...rest) => {
    const callId = typeof rest[rest.length - 1] === 'string' ? rest.pop() : undefined;
    const length = __SERIES__.from(lengthArg).get(0);
    const biased = rest.length === 0 || !!__SERIES__.from(rest[0]).get(0);
    const key = callId || `stdev_${length}_${biased}`;
    const window = __NON_NA_WINDOW__(context, key, __SERIES__.from(source), length);
    if (!window) return NaN;
    const momentsKey = key + ':stockdeckMoments';
    const state = context.taState[momentsKey] ||= {lastIdx: -1, committed: null, current: null};
    if (context.idx > state.lastIdx) {
      if (state.lastIdx >= 0) state.committed = state.current;
      state.lastIdx = context.idx;
    }
    const previous = state.committed;
    const end = window.h.end;
    let mean, m2;
    if (previous && previous.length === length && previous.end === end) {
      mean = previous.mean; m2 = previous.m2;
    } else if (previous && previous.length === length && end === previous.end + 1 && end % 64 !== 0) {
      const entering = window.at(0), leaving = previous.oldest;
      mean = previous.mean + (entering - leaving) / length;
      m2 = previous.m2 + (entering - leaving) * (entering - mean + leaving - previous.mean);
    }
    // Periodic exact rebase controls floating-point drift; rebuild for changed windows/backfill.
    if (!Number.isFinite(m2) || m2 < 0 || mean === undefined) {
      mean = window.sum / length;
      m2 = 0;
      for (let i = 0; i < length; i++) m2 += (window.at(i) - mean) ** 2;
    }
    state.current = {mean, m2, end, length, oldest: window.at(length - 1)};
    return context.precision(Math.sqrt(m2 / (biased ? length : length - 1)));
  };
}
