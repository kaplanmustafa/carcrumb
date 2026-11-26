/**
 * useTrips / useTripRoute with the native module mocked and React hooks replaced by the
 * test harness (no React renderer in the project, see src/__testutils__/hookHarness.ts).
 */
import type { TripRecord } from '../../../../modules/carcrumb-detection';
import { flush, harness } from '../../../__testutils__/hookHarness';

jest.mock('react', () => require('../../../__testutils__/hookHarness').harness.react);

const mockModule = { listTrips: jest.fn(), addListener: jest.fn() };
jest.mock('../../../../modules/carcrumb-detection', () => ({
  __esModule: true,
  get default() {
    return mockModule;
  },
}));

import { useTripRoute, useTrips, type RouteState } from '../useTrips';

const trip = (id: number, startedAt: number): TripRecord => ({
  id,
  startedAt,
  endedAt: startedAt + 600_000,
  status: 'confirmed',
  distanceMeters: 1000,
});

function deferred<T>() {
  let resolve!: (v: T) => void;
  let reject!: (e: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

let stateListener: (() => void) | undefined;
const sub = { remove: jest.fn() };

beforeEach(() => {
  harness.reset();
  jest.clearAllMocks();
  mockModule.addListener.mockImplementation((_n: string, fn: () => void) => {
    stateListener = fn;
    return sub;
  });
});

describe('useTrips', () => {
  it('loads up to 200 trips, newest start first (bridge returns write order)', async () => {
    mockModule.listTrips.mockResolvedValue([trip(1, 1000), trip(3, 3000), trip(2, 2000)]);
    expect(harness.render(useTrips)).toEqual({ trips: [], loaded: false });
    await flush();
    const r = harness.render(useTrips);
    expect(r.loaded).toBe(true);
    expect(r.trips.map((t) => t.id)).toEqual([3, 2, 1]);
    expect(mockModule.listTrips).toHaveBeenCalledWith(200);
  });

  it('a read error shows an empty, loaded history (no endless loading)', async () => {
    mockModule.listTrips.mockRejectedValue({ code: 'ERR_STORE_UNAVAILABLE' });
    harness.render(useTrips);
    await flush();
    expect(harness.render(useTrips)).toEqual({ trips: [], loaded: true });
  });

  it('refreshes on detection state changes (a trip ended)', async () => {
    mockModule.listTrips.mockResolvedValue([]);
    harness.render(useTrips);
    await flush();
    mockModule.listTrips.mockResolvedValue([trip(5, 5000)]);
    stateListener!();
    await flush();
    expect(harness.render(useTrips).trips.map((t) => t.id)).toEqual([5]);
  });

  it('an older read finishing last does not overwrite a newer one', async () => {
    mockModule.listTrips.mockResolvedValue([]);
    harness.render(useTrips);
    await flush();

    const older = deferred<TripRecord[]>();
    mockModule.listTrips.mockReturnValueOnce(older.promise);
    stateListener!(); // refresh A, hangs
    mockModule.listTrips.mockResolvedValueOnce([trip(9, 9000)]);
    stateListener!(); // refresh B, finishes first
    await flush();
    expect(harness.render(useTrips).trips.map((t) => t.id)).toEqual([9]);
    const sets = harness.setCalls;

    older.resolve([trip(1, 1000)]);
    await flush();
    expect(harness.setCalls).toBe(sets);
    expect(harness.render(useTrips).trips.map((t) => t.id)).toEqual([9]);
  });

  it('unmount removes the listener and a late read sets no state', async () => {
    const pending = deferred<TripRecord[]>();
    mockModule.listTrips.mockReturnValue(pending.promise);
    harness.render(useTrips);
    harness.unmount();
    expect(sub.remove).toHaveBeenCalledTimes(1);
    pending.resolve([trip(1, 1000)]);
    await flush();
    expect(harness.setCallsAfterUnmount).toBe(0);
  });
});

describe('useTripRoute', () => {
  const pt = (lat: number) => ({ latitude: lat, longitude: -40.0 });

  it('loading, then the route', async () => {
    const load = jest.fn().mockResolvedValue([pt(41.0), pt(41.01)]);
    expect(harness.render(() => useTripRoute(7, load))).toEqual({ status: 'loading' });
    expect(load).toHaveBeenCalledWith(7);
    await flush();
    expect(harness.render(() => useTripRoute(7, load))).toEqual({ status: 'ready', points: [pt(41.0), pt(41.01)] });
  });

  it('a read error becomes status error', async () => {
    const load = jest.fn().mockRejectedValue(new Error('locked'));
    harness.render(() => useTripRoute(7, load));
    await flush();
    expect(harness.render(() => useTripRoute(7, load))).toEqual({ status: 'error' });
  });

  it('re-rendering with the same trip and loader does not reload', async () => {
    const load = jest.fn().mockResolvedValue([]);
    harness.render(() => useTripRoute(7, load));
    await flush();
    harness.render(() => useTripRoute(7, load));
    harness.render(() => useTripRoute(7, load));
    expect(load).toHaveBeenCalledTimes(1);
  });

  it('tripId change: back to loading, loads the new trip, the old answer is ignored', async () => {
    const first = deferred<{ latitude: number; longitude: number }[]>();
    const load = jest
      .fn()
      .mockReturnValueOnce(first.promise)
      .mockResolvedValueOnce([pt(41.05), pt(41.06)]);
    harness.render(() => useTripRoute(1, load));
    expect(harness.render(() => useTripRoute(2, load))).toEqual({ status: 'loading' } satisfies RouteState);
    expect(load).toHaveBeenLastCalledWith(2);
    await flush();
    const sets = harness.setCalls;

    first.resolve([pt(41.0), pt(41.01)]); // trip 1's route arrives late
    await flush();
    expect(harness.setCalls).toBe(sets);
    expect(harness.render(() => useTripRoute(2, load))).toEqual({ status: 'ready', points: [pt(41.05), pt(41.06)] });
  });

  it('unmount: a late route or error sets no state', async () => {
    const ok = deferred<{ latitude: number; longitude: number }[]>();
    harness.render(() => useTripRoute(1, () => ok.promise));
    harness.unmount();
    ok.resolve([pt(41.0)]);
    await flush();
    expect(harness.setCallsAfterUnmount).toBe(0);

    harness.reset();
    const bad = deferred<{ latitude: number; longitude: number }[]>();
    harness.render(() => useTripRoute(1, () => bad.promise));
    harness.unmount();
    bad.reject(new Error('x'));
    await flush();
    expect(harness.setCallsAfterUnmount).toBe(0);
  });
});
