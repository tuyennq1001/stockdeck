import {mkdir} from 'node:fs/promises';
import path from 'node:path';
import {pathToFileURL} from 'node:url';

export const candidate = process.env.POC_RUNTIME === 'candidate';
export const resultDirectory = candidate ? 'local/candidate' : 'local';
await mkdir(resultDirectory,{recursive:true});
export const {PineTS} = candidate
  ? await import(pathToFileURL(path.resolve('local/candidate/pinets.es.mjs')).href)
  : await import('pinets');
export const nativeBundle = candidate
  ? 'local/candidate/pinets.browser.js' : 'node_modules/pinets/dist/pinets.min.browser.js';
export const runtimeLabel = candidate ? 'pinets@0.13.0 + StockDeck POC candidate' : 'pinets@0.13.0';
