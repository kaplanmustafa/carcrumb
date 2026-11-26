// eslint-disable-next-line @typescript-eslint/no-require-imports
const { anonymizeLines, SYNTHETIC } = require('../anonymize-trace.js') as {
  anonymizeLines: (lines: string[], random?: () => number) => { lines: string[]; extent: number };
  SYNTHETIC: { latitude: number; longitude: number };
};

// A "real" trace somewhere far from the synthetic box (values are made up for the test).
const REAL = { lat: 52.52, lon: 13.405 };
const T0 = 1_800_000_000;
const loc = (dLat: number, dLon: number, t: number) =>
  JSON.stringify({
    event: {
      type: 'location',
      sample: { latitude: REAL.lat + dLat, longitude: REAL.lon + dLon, accuracy: 5, speed: 12, timestamp: t },
    },
    t,
  });

const input = [
  JSON.stringify({ event: { type: 'wake', source: 'visit' }, t: T0 }),
  loc(0, 0, T0 + 10),
  loc(0.009, 0, T0 + 70), // ~1 km north
  loc(0.009, 0.0147, T0 + 130), // then ~1 km east
  JSON.stringify({ event: { type: 'motion', activity: 'walking', startedAt: T0 + 125 }, t: T0 + 140 }),
  JSON.stringify({ restore: { savedAt: T0 + 100, state: { parked: { location: { latitude: REAL.lat, longitude: REAL.lon, accuracy: 5, speed: 0, timestamp: T0 } } }, version: 1 }, t: T0 + 150 }),
];

const haversine = (a: { latitude: number; longitude: number }, b: { latitude: number; longitude: number }) => {
  const r = (d: number) => (d * Math.PI) / 180;
  const h =
    Math.sin(r(b.latitude - a.latitude) / 2) ** 2 +
    Math.cos(r(a.latitude)) * Math.cos(r(b.latitude)) * Math.sin(r(b.longitude - a.longitude) / 2) ** 2;
  return 2 * 6_371_000 * Math.asin(Math.sqrt(h));
};

const samples = (lines: string[]) =>
  lines
    .map((l) => JSON.parse(l))
    .filter((r) => r.event?.type === 'location')
    .map((r) => r.event.sample as { latitude: number; longitude: number; timestamp: number; speed: number; accuracy: number });

describe('anonymize-trace', () => {
  const random = (() => {
    const values = [0.37, 0.5];
    let i = 0;
    return () => values[i++ % values.length];
  })();
  const { lines, extent } = anonymizeLines(input, random);
  const text = lines.join('\n');

  it('removes every trace of the real place', () => {
    expect(text).not.toContain('52.5');
    expect(text).not.toContain('13.4');
  });

  it('moves coordinates to the synthetic point, inside the CI box', () => {
    const first = samples(lines)[0];
    expect(first.latitude).toBeCloseTo(SYNTHETIC.latitude, 6);
    expect(first.longitude).toBeCloseTo(SYNTHETIC.longitude, 6);
    expect(extent).toBeLessThan(0.1);
  });

  it('keeps distances between points (replay behaves the same)', () => {
    const before = samples(input);
    const after = samples(lines);
    for (let i = 1; i < before.length; i++) {
      expect(haversine(after[i - 1], after[i])).toBeCloseTo(haversine(before[i - 1], before[i]), -0.3); // within ~1 m
    }
  });

  it('rewrites nested coordinates too (restore records)', () => {
    const restore = JSON.parse(lines[lines.length - 1]).restore.state.parked.location;
    expect(restore.latitude).toBeCloseTo(SYNTHETIC.latitude, 6);
  });

  it('shifts all timestamps by whole days, keeping intervals; speed/accuracy untouched', () => {
    const before = samples(input);
    const after = samples(lines);
    const shift = after[0].timestamp - before[0].timestamp;
    expect(Math.abs(shift % 86_400)).toBe(0);
    expect(shift).toBeLessThanOrEqual(-30 * 86_400);
    const records = lines.map((l) => JSON.parse(l));
    records.forEach((r, i) => expect(r.t - JSON.parse(input[i]).t).toBe(shift));
    expect(JSON.parse(lines[4]).event.startedAt - (T0 + 125)).toBe(shift);
    expect(after.map((s) => [s.speed, s.accuracy])).toEqual(before.map((s) => [s.speed, s.accuracy]));
  });

  it('never echoes a broken line', () => {
    expect(() => anonymizeLines(['{"latitude": 52.52, "longitude": oops'])).toThrow('line 1: invalid JSON');
    try {
      anonymizeLines(['{"latitude": 52.52, "longitude": oops']);
    } catch (e) {
      expect(String(e)).not.toContain('52.52');
    }
  });
});
