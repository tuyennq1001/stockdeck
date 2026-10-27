extractPlotOptions(options) {
  const result = {};
  for (const key in options) {
    const value = options[key];
    // Scalar options already are current-bar values; don't allocate a Series and array.
    result[key] = value === null || typeof value !== 'object'
      ? value : __SERIES__.from(value).get(0);
  }
  return result;
}
