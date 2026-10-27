import {readFile} from 'node:fs/promises';
const report = JSON.parse(await readFile('local/validation.json', 'utf8'));
for (const result of Object.values(report.results)) {
  for (const key of ['buy', 'sell']) if (result[key]) {
    const indices = result[key].mismatches;
    result[key].mismatchCount = indices.length;
    result[key].firstMismatches = indices.slice(0, 12);
    delete result[key].mismatches;
  }
  if (result.barColorMismatches) {
    result.barColorMismatchCount = result.barColorMismatches.length;
    delete result.barColorMismatches;
  }
}
console.log(JSON.stringify(report, null, 2));
const output = JSON.parse(await readFile('local/dca-output.json', 'utf8'));
console.log('Actual colored candle samples:', JSON.stringify(output.plots['Màu nến DCA'].data.filter(x => x.options?.color).slice(0, 3)));
