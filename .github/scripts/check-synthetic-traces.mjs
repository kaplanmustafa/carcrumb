// Every committed trace must be synthetic: all coordinates must stay inside the agreed
// synthetic area (41.0±0.1, 29.0±0.1). A real field trace renamed to synthetic_* fails here.
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const DIR = 'fixtures/traces';
const BOX = { lat: [40.9, 41.1], lon: [28.9, 29.1] };
let bad = 0;

function walk(value, visit) {
  if (Array.isArray(value)) value.forEach((v) => walk(v, visit));
  else if (value && typeof value === 'object') {
    visit(value);
    Object.values(value).forEach((v) => walk(v, visit));
  }
}

for (const name of readdirSync(DIR)) {
  if (!name.endsWith('.jsonl') && !name.endsWith('.json')) continue;
  const lines = readFileSync(join(DIR, name), 'utf8').split(/\r?\n/).filter(Boolean);
  lines.forEach((line, i) => {
    walk(JSON.parse(line), (o) => {
      const { latitude: lat, longitude: lon } = o;
      if (lat === undefined && lon === undefined) return;
      if (!(lat >= BOX.lat[0] && lat <= BOX.lat[1] && lon >= BOX.lon[0] && lon <= BOX.lon[1])) {
        // Do not print the coordinate itself.
        console.error(`${name}:${i + 1}: coordinate outside the synthetic box`);
        bad++;
      }
    });
  });
}
if (bad) process.exit(1);
console.log('synthetic traces OK');
