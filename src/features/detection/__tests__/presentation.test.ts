import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { statePresentation } from '../presentation';

const ROOT = join(__dirname, '..', '..', '..', '..');

/** State names emitted by Swift (`DetectionState.name`), parsed from the source of truth. */
function swiftStateNames(): string[] {
  const swift = readFileSync(
    join(ROOT, 'modules', 'carcrumb-detection', 'ios', 'Detection', 'DetectionTypes.swift'),
    'utf8',
  );
  const nameVar = swift.slice(swift.indexOf('public var name: String'));
  const body = nameVar.slice(0, nameVar.indexOf('}'));
  return [...body.matchAll(/case \.\w+: return "([A-Z_]+)"/g)].map((m) => m[1]);
}

describe('detection state presentation', () => {
  it('covers exactly the state names Swift emits (JS bridge stays in sync)', () => {
    const names = swiftStateNames();
    expect(names.length).toBeGreaterThanOrEqual(5);
    expect(Object.keys(statePresentation).sort()).toEqual([...names].sort());
  });

  it('every state has a distinct title, so colour/icon is never the only signal', () => {
    const titles = Object.values(statePresentation).map((p) => p.title);
    expect(new Set(titles).size).toBe(titles.length);
  });

  it('only PARKED uses the parked tone and only DRIVING the driving tone', () => {
    const byTone = (tone: string) =>
      Object.entries(statePresentation)
        .filter(([, p]) => p.tone === tone)
        .map(([s]) => s);
    expect(byTone('parked')).toEqual(['PARKED']);
    expect(byTone('driving')).toEqual(['DRIVING']);
  });
});
