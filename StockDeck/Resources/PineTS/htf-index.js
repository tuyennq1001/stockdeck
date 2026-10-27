function __PATCH_NAME__(myOpen, myClose, opens, closes, lookahead = false, realtime = false) {
  // Provider contract: strictly ordered, non-overlapping HTF candles.
  let low = 0, high = opens.length - 1, match = -1;
  while (low <= high) {
    const mid = (low + high) >>> 1;
    if (opens[mid] <= myOpen) { match = mid; low = mid + 1; }
    else high = mid - 1;
  }
  if (match < 0 || !(myOpen < closes[match])) return -1;
  return lookahead || realtime || myClose >= closes[match] ? match : match - 1;
}
