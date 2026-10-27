const __stockdeckSignaturePlans = new WeakMap();
function __PATCH_NAME__(args, signatures, types, override) {
  const flat = Array.isArray(signatures) && typeof signatures[0] === 'string';
  let single = flat ? signatures : null;
  if (!flat) {
    // The pinned namespaces keep immutable signature families. Prefix overloads bind
    // the same names/types and can be checked once against their longest signature.
    let plan = __stockdeckSignaturePlans.get(signatures);
    if (!plan) {
      let longest = [];
      for (const signature of signatures) if (signature.length > longest.length) longest = signature;
      const prefixOnly = signatures.every(signature => signature.every((name,index) => name === longest[index]));
      plan = {single: prefixOnly ? longest : null};
      __stockdeckSignaturePlans.set(signatures, plan);
    }
    single = plan.single;
  }
  const count = single ? 1 : signatures.length;
  const options = {};
  let named;
  // Avoid per-argument signature arrays and per-call closure creation.
  let invalid = 0;
  const invalidLarge = count > 31 ? new Array(count).fill(false) : null;
  for (let index = 0; index < args.length; index++) {
    const arg = args[index];
    if (arg === undefined) continue;
    if (__TYPE_CHECK__.remaining_options(arg)) {
      named = {};
      for (const key of Object.keys(arg)) {
        const value = arg[key], type = types[key];
        named[key] = type !== undefined && type !== 'series' && type !== 'any'
          && (value instanceof __SERIES__ || __SCALAR_HELPER__(value))
          ? __SERIES__.from(value).get(0) : value;
      }
      break;
    }
    for (let signature = 0; signature < count; signature++) {
      const inactive = invalidLarge ? invalidLarge[signature] : (invalid & (1 << signature)) !== 0;
      const name = inactive ? undefined : (single ? single[index] : signatures[signature][index]);
      if (name !== undefined) {
        const type = types[name];
        if (typeof arg === 'number' && Number.isNaN(arg) && (type === 'number' || type === 'series')) {
          options[name] = arg;
          continue;
        }
        const checker = __TYPE_CHECK__[type];
        const value = typeof checker === 'function' && !checker(arg) && __SCALAR_TYPES__.has(type)
          && (arg instanceof __SERIES__ || __SCALAR_HELPER__(arg))
          ? __SERIES__.from(arg).get(0) : arg;
        if (typeof checker === 'function' && checker(value)) {
          options[name] = value;
          continue;
        }
      }
      if (invalidLarge) invalidLarge[signature] = true;
      else invalid |= 1 << signature;
    }
  }
  // Preserve named arguments > positional arguments, and explicit override last.
  return Object.assign(options, named, override);
}
