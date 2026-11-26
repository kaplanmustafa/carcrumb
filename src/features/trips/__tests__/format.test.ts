import type { TripRecord } from '../../../../modules/carcrumb-detection';
import { cameraForRoute } from '../camera';
import { formatDistance, formatDuration, sortTripsForHistory, tripSummary } from '../format';
import { tripIdFromValue, tripValue } from '../TripScreens';

const MIN = 60_000;
const trip = (over: Partial<TripRecord>): TripRecord => ({
  id: 1,
  startedAt: 0,
  endedAt: 23 * MIN,
  status: 'confirmed',
  distanceMeters: 12_400,
  ...over,
});

describe('formatDuration', () => {
  it.each([
    [10_000, '1 dk'],
    [23 * MIN, '23 dk'],
    [60 * MIN, '1 sa'],
    [65 * MIN, '1 sa 5 dk'],
    [119.6 * MIN, '2 sa'],
  ])('%d ms → %s', (ms, text) => expect(formatDuration(ms)).toBe(text));
});

describe('formatDistance', () => {
  it.each([
    [0, '0 m'],
    [849, '850 m'],
    [12_400, '12,4 km'],
    [99_960, '100,0 km'],
    [125_400, '125 km'],
  ])('%d m → %s', (m, text) => expect(formatDistance(m)).toBe(text));
});

describe('tripSummary', () => {
  it('shows duration and distance', () => expect(tripSummary(trip({}))).toBe('23 dk · 12,4 km'));
  it('omits unknown distance', () => expect(tripSummary(trip({ distanceMeters: null }))).toBe('23 dk'));
  it('open trips say so', () => expect(tripSummary(trip({ endedAt: null, status: 'open' }))).toBe('Devam ediyor'));
});

describe('sortTripsForHistory', () => {
  it('orders by real start time, newest first, not by write order (clock-independent ids)', () => {
    const sorted = sortTripsForHistory([trip({ id: 3, startedAt: 10 }), trip({ id: 1, startedAt: 30 }), trip({ id: 2, startedAt: 20 })]);
    expect(sorted.map((t) => t.id)).toEqual([1, 2, 3]);
  });
});

describe('trip navigation values', () => {
  it('round-trips ids and rejects anything else', () => {
    expect(tripIdFromValue(tripValue(42))).toBe(42);
    expect(tripIdFromValue('history')).toBeNull();
    expect(tripIdFromValue('trip:')).toBeNull();
    expect(tripIdFromValue('trip:1x')).toBeNull();
  });
});

describe('cameraForRoute', () => {
  it('returns null without valid points', () => {
    expect(cameraForRoute([])).toBeNull();
    expect(cameraForRoute([{ latitude: Number.NaN, longitude: 0 }])).toBeNull();
  });

  it('centres on the bounding box', () => {
    const cam = cameraForRoute([
      { latitude: 41.0, longitude: -40.02 },
      { latitude: 41.02, longitude: -40.0 },
    ]);
    expect(cam?.coordinates.latitude).toBeCloseTo(41.01, 6);
    expect(cam?.coordinates.longitude).toBeCloseTo(-40.01, 6);
  });

  it('zooms out for longer routes and stays within limits', () => {
    const short = cameraForRoute([
      { latitude: 41.0, longitude: -40.0 },
      { latitude: 41.01, longitude: -40.0 },
    ])!;
    const long = cameraForRoute([
      { latitude: 41.0, longitude: -40.0 },
      { latitude: 41.09, longitude: -40.0 },
    ])!;
    expect(long.zoom).toBeLessThan(short.zoom);
    expect(short.zoom).toBeLessThanOrEqual(17);
    expect(cameraForRoute([{ latitude: 41.0, longitude: -40.0 }])!.zoom).toBeLessThanOrEqual(17);
  });
});
