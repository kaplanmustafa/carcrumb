/**
 * App.tsx settings wiring (PushedSettings is not exported): App → Root is rendered with the
 * hook harness, the settings page is pushed through the navigation prop, and the
 * PushedSettings element is taken from the destinations. Then its logic is tested on its own:
 * optimistic retention change with rollback on failure, delete status, refresh afterwards.
 * Every screen / design component is a stub; the native module is mocked.
 */
import type { ReactElement, ReactNode } from 'react';

import { harness, flush } from '../../../__testutils__/hookHarness';

jest.mock('react', () => ({
  ...jest.requireActual('react'),
  ...require('../../../__testutils__/hookHarness').harness.react,
}));

const mockModule = {
  getRouteRetention: jest.fn(),
  setRouteRetention: jest.fn(),
  deleteAllHistory: jest.fn(),
  getTripRoute: jest.fn(),
  requestWhenInUseAuthorization: jest.fn(),
  requestMotionAuthorization: jest.fn(),
  requestAlwaysAuthorization: jest.fn(),
};
jest.mock('../../../../modules/carcrumb-detection', () => ({
  __esModule: true,
  get default() {
    return mockModule;
  },
}));
jest.mock('react-native', () => ({
  Linking: { openURL: jest.fn(), openSettings: jest.fn() },
  Settings: { get: jest.fn(), set: jest.fn() },
}));

// Function declaration: hoisted, so the (hoisted) jest.mock factories can call it.
function mockStubs(names: string[]) {
  return require('../../../__testutils__/elementTree').stubComponents(names);
}
jest.mock('../../../design/components', () =>
  mockStubs(['Screen', 'Destination', 'Section', 'Txt', 'InfoRow', 'DetailRow', 'NavRow', 'EmptyState', 'ChoiceRow', 'DestructiveButton']),
);
jest.mock('../../../design/RouteMap', () => mockStubs(['RouteMap']));
jest.mock('../../home/HomeScreen', () => mockStubs(['HomeScreen']));
jest.mock('../../permissions/OnboardingScreen', () => mockStubs(['OnboardingScreen']));
jest.mock('../../preview/DesignPreview', () => ({ ...mockStubs(['DesignPreview']), requestedPreview: () => null }));
jest.mock('../../diagnostics/DiagnosticsPage', () => ({ ...mockStubs(['DiagnosticsPage']), DIAGNOSTICS: 'diagnostics' }));
jest.mock('../../diagnostics/useDiagnostics', () => ({ useDiagnostics: jest.fn(), shareTrace: jest.fn() }));
jest.mock('../SettingsPage', () => ({ ...mockStubs(['SettingsPage']), SETTINGS: 'settings' }));

const mockHome = {
  data: {
    loaded: true,
    state: 'IDLE',
    diagnostics: null, // engine not running → home screen, no onboarding
    parking: null,
    recentParkings: [],
    trips: [],
    storeUnavailable: false,
    motionAsked: true,
    alwaysAsked: true,
  },
  refresh: jest.fn(),
};
jest.mock('../../home/useHomeData', () => ({ useHomeData: () => mockHome }));

const mockHistory = { trips: [] as { id: number }[], loaded: true, refresh: jest.fn() };
jest.mock('../../trips/useTrips', () => ({ useTrips: () => mockHistory, useTripRoute: () => ({ status: 'loading' }) }));

import App from '../../../../App';

type El = ReactElement<Record<string, unknown> & { children?: ReactNode }>;
type Nav = { path: string[]; onPathChange: (p: string[]) => void; destinations: El };

function deferred<T = void>() {
  let resolve!: (v: T) => void;
  let reject!: (e: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

const childrenOf = (el: El): El[] => ([] as unknown[]).concat(el.props.children ?? []).flat(Infinity).filter(Boolean) as El[];

/** Renders Root (with the harness), pushes `path`, returns the home element's navigation. */
function renderRoot(path: string[]): { nav: Nav; render: () => Nav } {
  const Root = (App() as El).type as () => El;
  const render = () => (harness.render(Root).props.navigation as Nav);
  render().onPathChange(path);
  return { nav: render(), render };
}

function pushedSettings(): { type: (p: { onHistoryDeleted: () => void }) => El; onHistoryDeleted: () => void } {
  const { nav } = renderRoot(['settings']);
  const el = childrenOf(nav.destinations).find((e) => typeof e.props.onHistoryDeleted === 'function');
  if (!el) throw new Error('PushedSettings not in destinations');
  return { type: el.type as never, onHistoryDeleted: el.props.onHistoryDeleted as () => void };
}

beforeEach(() => {
  harness.reset();
  jest.clearAllMocks();
  mockHistory.trips = [];
  mockModule.getRouteRetention.mockReturnValue('twelveMonths');
});

describe('Root navigation', () => {
  it('settings page is mounted only while pushed', () => {
    const { nav } = renderRoot([]);
    expect(childrenOf(nav.destinations).some((e) => 'onHistoryDeleted' in e.props)).toBe(false);
    harness.reset();
    pushedSettings(); // throws if missing
  });

  it('history deleted → home data and trip history are refreshed', () => {
    const { onHistoryDeleted } = pushedSettings();
    onHistoryDeleted();
    expect(mockHome.refresh).toHaveBeenCalledTimes(1);
    expect(mockHistory.refresh).toHaveBeenCalledTimes(1);
  });

  it('trip pages of deleted trips are dropped from the navigation path', () => {
    mockHistory.trips = [{ id: 5 }];
    const { render } = renderRoot(['settings', 'trip:5']);
    expect(render().path).toEqual(['settings', 'trip:5']);
    mockHistory.trips = []; // history deleted and reloaded
    render(); // prunes during render
    expect(render().path).toEqual(['settings']);
  });
});

describe('PushedSettings', () => {
  function mount() {
    const { type, onHistoryDeleted } = pushedSettings();
    harness.reset();
    const onDeleted = jest.fn();
    mockHome.refresh.mockClear();
    const render = () => harness.render(() => type({ onHistoryDeleted: onDeleted })).props as {
      retention: string | null;
      onRetentionChange: (v: string) => void;
      deleteStatus: string;
      onDeleteHistory: () => void;
    };
    return { render, onDeleted, rootOnHistoryDeleted: onHistoryDeleted };
  }

  it('shows the retention the engine has', () => {
    mockModule.getRouteRetention.mockReturnValue('forever');
    expect(mount().render()).toMatchObject({ retention: 'forever', deleteStatus: 'idle' });
  });

  it('retention change: shown at once, sent to the engine, kept on success', async () => {
    const { render } = mount();
    mockModule.setRouteRetention.mockResolvedValue(undefined);
    render().onRetentionChange('threeMonths');
    expect(render().retention).toBe('threeMonths');
    expect(mockModule.setRouteRetention).toHaveBeenCalledWith('threeMonths');
    await flush();
    expect(render().retention).toBe('threeMonths');
  });

  it('retention change failure: rolls back to what the engine actually kept', async () => {
    const { render } = mount();
    mockModule.setRouteRetention.mockRejectedValue(new Error('engine'));
    mockModule.getRouteRetention.mockReturnValue('twelveMonths');
    render().onRetentionChange('threeMonths');
    expect(render().retention).toBe('threeMonths');
    await flush();
    expect(render().retention).toBe('twelveMonths');
  });

  it('two quick changes, the first fails late: the value comes from the engine, not the stale choice', async () => {
    const { render } = mount();
    const first = deferred();
    mockModule.setRouteRetention.mockReturnValueOnce(first.promise).mockResolvedValueOnce(undefined);
    render().onRetentionChange('threeMonths');
    render().onRetentionChange('forever');
    await flush();
    mockModule.getRouteRetention.mockReturnValue('forever'); // the engine stored the last one
    first.reject(new Error('engine'));
    await flush();
    expect(render().retention).toBe('forever');
  });

  it('delete success: deleting → done, then refresh', async () => {
    const { render, onDeleted } = mount();
    const del = deferred();
    mockModule.deleteAllHistory.mockReturnValue(del.promise);
    render().onDeleteHistory();
    expect(render().deleteStatus).toBe('deleting');
    expect(onDeleted).not.toHaveBeenCalled();
    del.resolve();
    await flush();
    expect(render().deleteStatus).toBe('done');
    expect(onDeleted).toHaveBeenCalledTimes(1);
  });

  it('delete failure: deleting → failed, and still refreshes (partial deletion is visible)', async () => {
    const { render, onDeleted } = mount();
    mockModule.deleteAllHistory.mockRejectedValue({ code: 'ERR_DELETE_HISTORY', message: 'database' });
    render().onDeleteHistory();
    expect(render().deleteStatus).toBe('deleting');
    await flush();
    expect(render().deleteStatus).toBe('failed');
    expect(onDeleted).toHaveBeenCalledTimes(1);
  });

  it('a retry after a failure goes through deleting again', async () => {
    const { render } = mount();
    mockModule.deleteAllHistory.mockRejectedValueOnce(new Error('locked')).mockResolvedValueOnce(undefined);
    render().onDeleteHistory();
    await flush();
    expect(render().deleteStatus).toBe('failed');
    render().onDeleteHistory();
    expect(render().deleteStatus).toBe('deleting');
    await flush();
    expect(render().deleteStatus).toBe('done');
    expect(mockModule.deleteAllHistory).toHaveBeenCalledTimes(2);
  });
});
