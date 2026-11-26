/**
 * useHomeData: reads from the native module, refreshes on state change / app active, and
 * never sets state after unmount. No React renderer is installed (no react-test-renderer /
 * @testing-library), so the four React hooks it uses are replaced by a minimal, explicit
 * single-component harness: state slots, stable refs/callbacks, effects run on mount and
 * their cleanup on unmount.
 */
import type { Diagnostics, ParkingRecord, TripRecord } from '../../../../modules/carcrumb-detection';

// ---- React hook harness ------------------------------------------------------------------

// Named type: jest's hoisting check rejects parameter names inside function types in factories.
type MockUpdater = (previous: unknown) => unknown;

const mockHooks = {
  states: [] as unknown[],
  refs: [] as { current: unknown }[],
  callbacks: [] as unknown[],
  effects: [] as (() => void | (() => void))[],
  cleanups: [] as (() => void)[],
  setCalls: 0,
  si: 0,
  ri: 0,
  ci: 0,
};

jest.mock('react', () => ({
  useState: (init: unknown) => {
    const i = mockHooks.si++;
    if (!(i in mockHooks.states)) mockHooks.states[i] = typeof init === 'function' ? (init as () => unknown)() : init;
    const set = (v: unknown) => {
      mockHooks.setCalls++;
      mockHooks.states[i] = typeof v === 'function' ? (v as MockUpdater)(mockHooks.states[i]) : v;
    };
    return [mockHooks.states[i], set];
  },
  useRef: (v: unknown) => {
    const i = mockHooks.ri++;
    if (!(i in mockHooks.refs)) mockHooks.refs[i] = { current: v };
    return mockHooks.refs[i];
  },
  // Deps never change in useHomeData ([]), so the first callback stays.
  useCallback: (fn: unknown) => {
    const i = mockHooks.ci++;
    if (!(i in mockHooks.callbacks)) mockHooks.callbacks[i] = fn;
    return mockHooks.callbacks[i];
  },
  useEffect: (fn: () => void | (() => void)) => {
    mockHooks.effects.push(fn);
  },
}));

// ---- Native module + AppState mocks --------------------------------------------------------

const mockModule = {
  getState: jest.fn(),
  getDiagnostics: jest.fn(),
  getLastParking: jest.fn(),
  listRecentParkings: jest.fn(),
  listTrips: jest.fn(),
  addListener: jest.fn(),
};
// Getters: the factory runs when the hook module is imported, before these consts are set.
jest.mock('../../../../modules/carcrumb-detection', () => ({
  __esModule: true,
  get default() {
    return mockModule;
  },
}));

const mockAppState = { addEventListener: jest.fn() };
/** NSUserDefaults stand-in for the "already asked" marks (src/features/permissions/asked.ts). */
const mockDefaults: Record<string, unknown> = {};
const mockSettings = { get: jest.fn((key: string) => mockDefaults[key]) };
jest.mock('react-native', () => ({
  get AppState() {
    return mockAppState;
  },
  get Settings() {
    return mockSettings;
  },
}));

import { useHomeData } from '../useHomeData';

// ---- Helpers --------------------------------------------------------------------------------

type Hook = ReturnType<typeof useHomeData>;

function mount() {
  const render = (): Hook => {
    mockHooks.si = mockHooks.ri = mockHooks.ci = 0;
    return useHomeData();
  };
  let current = render();
  for (const effect of mockHooks.effects.splice(0)) {
    const cleanup = effect();
    if (cleanup) mockHooks.cleanups.push(cleanup);
  }
  return {
    /** Re-renders and returns the current data (effects only run on mount: deps are stable). */
    get data() {
      current = render();
      mockHooks.effects.splice(0);
      return current.data;
    },
    refresh: () => current.refresh(),
    unmount: () => mockHooks.cleanups.splice(0).forEach((c) => c()),
  };
}

const flush = () => new Promise((r) => setTimeout(r, 0));

const diagnostics = { location: { authorization: 'whenInUse', servicesEnabled: true } } as unknown as Diagnostics;
const park: ParkingRecord = { id: 3, tripId: 7, latitude: 41.0, longitude: -40.0, accuracy: 5, confidence: 'high', parkedAt: 1 };
const trip: TripRecord = { id: 7, startedAt: 0, endedAt: 1, status: 'confirmed', distanceMeters: null };

let stateListener: (() => void) | undefined;
let appListener: ((s: string) => void) | undefined;
const stateSub = { remove: jest.fn() };
const appSub = { remove: jest.fn() };

beforeEach(() => {
  Object.assign(mockHooks, { states: [], refs: [], callbacks: [], effects: [], cleanups: [], setCalls: 0 });
  jest.clearAllMocks();
  for (const k of Object.keys(mockDefaults)) delete mockDefaults[k];
  mockModule.getState.mockReturnValue('IDLE');
  mockModule.getDiagnostics.mockResolvedValue(diagnostics);
  mockModule.getLastParking.mockResolvedValue(park);
  mockModule.listRecentParkings.mockResolvedValue([park]);
  mockModule.listTrips.mockResolvedValue([trip]);
  mockModule.addListener.mockImplementation((_name: string, fn: () => void) => {
    stateListener = fn;
    return stateSub;
  });
  mockAppState.addEventListener.mockImplementation((_name: string, fn: (s: string) => void) => {
    appListener = fn;
    return appSub;
  });
});

// ---- Tests ------------------------------------------------------------------------------------

describe('useHomeData', () => {
  it('starts not loaded, then loads everything on mount', async () => {
    const h = mount();
    expect(h.data.loaded).toBe(false);
    await flush();
    expect(h.data).toEqual({
      loaded: true,
      state: 'IDLE',
      diagnostics,
      parking: park,
      recentParkings: [park],
      trips: [trip],
      storeUnavailable: false,
      motionAsked: false,
      alwaysAsked: false,
    });
    expect(mockModule.addListener).toHaveBeenCalledWith('onStateChange', expect.any(Function));
    expect(mockAppState.addEventListener).toHaveBeenCalledWith('change', expect.any(Function));
  });

  it('reads the "already asked" marks initially and again on every refresh', async () => {
    mockDefaults['carcrumb.permissionAsked.motion'] = true;
    const h = mount();
    expect(h.data).toMatchObject({ loaded: false, motionAsked: true, alwaysAsked: false });
    await flush();
    expect(h.data).toMatchObject({ motionAsked: true, alwaysAsked: false });

    // Always dialog shown and closed (OnboardingScreen marks it), then the app refreshes.
    mockDefaults['carcrumb.permissionAsked.always'] = true;
    await h.refresh();
    expect(h.data).toMatchObject({ motionAsked: true, alwaysAsked: true });
  });

  it('only a truthy boolean counts as asked', async () => {
    mockDefaults['carcrumb.permissionAsked.motion'] = 'true';
    mockDefaults['carcrumb.permissionAsked.always'] = 1;
    const h = mount();
    await flush();
    expect(h.data).toMatchObject({ motionAsked: false, alwaysAsked: false });
  });

  it('an older refresh finishing last does not overwrite a newer one', async () => {
    const h = mount();
    await flush();

    // Refresh A starts and hangs on diagnostics; refresh B starts later and finishes first.
    let resolveA!: (d: Diagnostics) => void;
    const old = { location: { authorization: 'whenInUse', servicesEnabled: true }, tag: 'A' } as unknown as Diagnostics;
    const fresh = { location: { authorization: 'always', servicesEnabled: true }, tag: 'B' } as unknown as Diagnostics;
    mockModule.getDiagnostics.mockReturnValueOnce(new Promise<Diagnostics>((r) => (resolveA = r)));
    const a = h.refresh();
    mockModule.getDiagnostics.mockResolvedValueOnce(fresh);
    mockModule.getState.mockReturnValue('PARKED');
    await h.refresh();
    expect(h.data).toMatchObject({ diagnostics: fresh, state: 'PARKED' });
    const setsAfterB = mockHooks.setCalls;

    mockModule.getState.mockReturnValue('IDLE');
    resolveA(old);
    await a;
    expect(mockHooks.setCalls).toBe(setsAfterB);
    expect(h.data).toMatchObject({ diagnostics: fresh, state: 'PARKED' });
  });

  it('ERR_STORE_UNAVAILABLE → storeUnavailable, empty history, still loaded', async () => {
    const locked = Object.assign(new Error('locked'), { code: 'ERR_STORE_UNAVAILABLE' });
    mockModule.getLastParking.mockRejectedValue(locked);
    mockModule.listRecentParkings.mockRejectedValue(locked);
    mockModule.listTrips.mockRejectedValue(locked);
    const h = mount();
    await flush();
    expect(h.data).toMatchObject({ loaded: true, storeUnavailable: true, parking: null, recentParkings: [], trips: [] });
    expect(h.data.diagnostics).toBe(diagnostics);
  });

  it('one locked read is enough to flag storeUnavailable; the other reads keep their data', async () => {
    mockModule.listTrips.mockRejectedValue({ code: 'ERR_STORE_UNAVAILABLE' });
    const h = mount();
    await flush();
    expect(h.data).toMatchObject({ storeUnavailable: true, parking: park, trips: [] });
  });

  it('other read errors fall back without flagging storeUnavailable', async () => {
    mockModule.getLastParking.mockRejectedValue({ code: 'ERR_STORE' });
    mockModule.listTrips.mockRejectedValue(new Error('no code'));
    const h = mount();
    await flush();
    expect(h.data).toMatchObject({ loaded: true, storeUnavailable: false, parking: null, trips: [] });
  });

  it('getDiagnostics failure → diagnostics null, history still read', async () => {
    mockModule.getDiagnostics.mockRejectedValue(new Error('engine not started'));
    const h = mount();
    await flush();
    expect(h.data).toMatchObject({ loaded: true, diagnostics: null, parking: park, trips: [trip] });
  });

  it('refreshes on every detection state change', async () => {
    const h = mount();
    await flush();
    mockModule.getState.mockReturnValue('DRIVING');
    mockModule.getLastParking.mockResolvedValue(null);
    stateListener!();
    await flush();
    expect(h.data).toMatchObject({ state: 'DRIVING', parking: null });
    expect(mockModule.getLastParking).toHaveBeenCalledTimes(2);
  });

  it('refreshes when the app becomes active, not on background / inactive', async () => {
    const h = mount();
    await flush();
    appListener!('background');
    appListener!('inactive');
    await flush();
    expect(mockModule.getDiagnostics).toHaveBeenCalledTimes(1);

    const always = { location: { authorization: 'always', servicesEnabled: true } } as unknown as Diagnostics;
    mockModule.getDiagnostics.mockResolvedValue(always);
    appListener!('active');
    await flush();
    expect(mockModule.getDiagnostics).toHaveBeenCalledTimes(2);
    expect(h.data.diagnostics).toBe(always);
  });

  it('unmount removes both subscriptions and a refresh finishing later sets no state', async () => {
    let resolveParking!: (p: ParkingRecord | null) => void;
    mockModule.getLastParking.mockReturnValue(new Promise((r) => (resolveParking = r)));
    const h = mount();
    await flush();
    const setsBefore = mockHooks.setCalls;

    h.unmount();
    expect(stateSub.remove).toHaveBeenCalledTimes(1);
    expect(appSub.remove).toHaveBeenCalledTimes(1);

    resolveParking(park);
    await flush();
    expect(mockHooks.setCalls).toBe(setsBefore);
  });

  it('manual refresh() reloads', async () => {
    const h = mount();
    await flush();
    mockModule.listTrips.mockResolvedValue([]);
    await h.refresh();
    expect(h.data.trips).toEqual([]);
  });
});
