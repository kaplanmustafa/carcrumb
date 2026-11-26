/**
 * useDiagnostics (5 s polling only while mounted) and shareTrace, with the native module and
 * Share mocked and React hooks replaced by the test harness (src/__testutils__/hookHarness.ts).
 */
import type { Diagnostics } from '../../../../modules/carcrumb-detection';
import { harness } from '../../../__testutils__/hookHarness';

jest.mock('react', () => require('../../../__testutils__/hookHarness').harness.react);

const mockModule = {
  getDiagnostics: jest.fn(),
  listTraces: jest.fn(),
  getTracePath: jest.fn(),
  addListener: jest.fn(),
};
jest.mock('../../../../modules/carcrumb-detection', () => ({
  __esModule: true,
  get default() {
    return mockModule;
  },
}));
const mockShare = { share: jest.fn() };
const mockAppStateListeners: ((s: string) => void)[] = [];
jest.mock('react-native', () => ({
  get Share() {
    return mockShare;
  },
  AppState: {
    currentState: 'active',
    addEventListener: (_: string, fn: (s: string) => void) => {
      mockAppStateListeners.push(fn);
      return { remove: () => mockAppStateListeners.splice(mockAppStateListeners.indexOf(fn), 1) };
    },
  },
}));

import { shareTrace, useDiagnostics } from '../useDiagnostics';

/** Promise callbacks only (fake timers are on: no setTimeout-based flush). */
const settle = async () => {
  for (let i = 0; i < 10; i++) await Promise.resolve();
};

function deferred<T>() {
  let resolve!: (v: T) => void;
  const promise = new Promise<T>((r) => (resolve = r));
  return { promise, resolve };
}

const diag = (tag: string) => ({ engine: { tag } }) as unknown as Diagnostics;

let stateListener: (() => void) | undefined;
const sub = { remove: jest.fn() };

beforeEach(() => {
  jest.useFakeTimers();
  harness.reset();
  jest.clearAllMocks();
  mockModule.getDiagnostics.mockResolvedValue(diag('a'));
  mockModule.listTraces.mockReturnValue(['20261126-1.jsonl']);
  mockModule.addListener.mockImplementation((_n: string, fn: () => void) => {
    stateListener = fn;
    return sub;
  });
});

afterEach(() => {
  jest.useRealTimers();
});

describe('useDiagnostics', () => {
  it('reads diagnostics and traces on mount', async () => {
    expect(harness.render(useDiagnostics)).toMatchObject({ diagnostics: null, traces: [] });
    await settle();
    expect(harness.render(useDiagnostics)).toMatchObject({ diagnostics: diag('a'), traces: ['20261126-1.jsonl'] });
    expect(mockModule.getDiagnostics).toHaveBeenCalledTimes(1);
  });

  it('polls every 5 s only while mounted; unmount clears the interval and the listener', async () => {
    expect(jest.getTimerCount()).toBe(0);
    harness.render(useDiagnostics);
    expect(jest.getTimerCount()).toBe(1);

    jest.advanceTimersByTime(4_999);
    expect(mockModule.getDiagnostics).toHaveBeenCalledTimes(1);
    jest.advanceTimersByTime(1);
    expect(mockModule.getDiagnostics).toHaveBeenCalledTimes(2);
    jest.advanceTimersByTime(10_000);
    expect(mockModule.getDiagnostics).toHaveBeenCalledTimes(4);

    harness.unmount();
    expect(jest.getTimerCount()).toBe(0);
    expect(sub.remove).toHaveBeenCalledTimes(1);
    jest.advanceTimersByTime(60_000);
    expect(mockModule.getDiagnostics).toHaveBeenCalledTimes(4);
  });

  it('re-rendering does not start a second interval', () => {
    harness.render(useDiagnostics);
    harness.render(useDiagnostics);
    harness.render(useDiagnostics);
    expect(jest.getTimerCount()).toBe(1);
    expect(mockModule.addListener).toHaveBeenCalledTimes(1);
  });

  it('refreshes on state change and on the button', async () => {
    const { refresh } = harness.render(useDiagnostics);
    stateListener!();
    refresh();
    expect(mockModule.getDiagnostics).toHaveBeenCalledTimes(3);
  });

  it('an older read finishing last does not overwrite a newer one', async () => {
    harness.render(useDiagnostics);
    await settle();
    const older = deferred<Diagnostics>();
    mockModule.getDiagnostics.mockReturnValueOnce(older.promise);
    stateListener!(); // A, hangs
    mockModule.getDiagnostics.mockResolvedValueOnce(diag('b'));
    harness.render(useDiagnostics).refresh(); // B
    await settle();
    expect(harness.render(useDiagnostics).diagnostics).toEqual(diag('b'));
    const sets = harness.setCalls;

    older.resolve(diag('old'));
    await settle();
    expect(harness.setCalls).toBe(sets);
    expect(harness.render(useDiagnostics).diagnostics).toEqual(diag('b'));
  });

  it('engine error → diagnostics null, traces still listed', async () => {
    mockModule.getDiagnostics.mockRejectedValue(new Error('not started'));
    harness.render(useDiagnostics);
    await settle();
    expect(harness.render(useDiagnostics)).toMatchObject({ diagnostics: null, traces: ['20261126-1.jsonl'] });
  });

  it('release build: no traces', async () => {
    mockModule.listTraces.mockReturnValue([]);
    harness.render(useDiagnostics);
    await settle();
    expect(harness.render(useDiagnostics).traces).toEqual([]);
  });

  it('a read finishing after unmount sets no state', async () => {
    const pending = deferred<Diagnostics>();
    mockModule.getDiagnostics.mockReturnValue(pending.promise);
    harness.render(useDiagnostics);
    harness.unmount();
    pending.resolve(diag('late'));
    await settle();
    expect(harness.setCallsAfterUnmount).toBe(0);
    expect(mockModule.listTraces).not.toHaveBeenCalled();
  });
});

describe('shareTrace', () => {
  it('no path (release build / unknown name) → no share sheet', async () => {
    mockModule.getTracePath.mockReturnValue(null);
    await shareTrace('x.jsonl');
    expect(mockModule.getTracePath).toHaveBeenCalledWith('x.jsonl');
    expect(mockShare.share).not.toHaveBeenCalled();
  });

  it('shares the file as a file:// URL', async () => {
    mockShare.share.mockResolvedValue({ action: 'sharedAction' });
    mockModule.getTracePath.mockReturnValue('/data/traces/20261126-1.jsonl');
    await shareTrace('20261126-1.jsonl');
    expect(mockShare.share).toHaveBeenCalledWith({ url: 'file:///data/traces/20261126-1.jsonl' });
  });

  it('a cancelled / failed share sheet does not throw', async () => {
    mockShare.share.mockRejectedValue(new Error('cancelled'));
    mockModule.getTracePath.mockReturnValue('/data/traces/a.jsonl');
    await expect(shareTrace('a.jsonl')).resolves.toBeUndefined();
  });

  /**
   * The real path is under "Library/Application Support/traces" (a space). The URL is built
   * by plain concatenation, without percent-encoding; whether iOS accepts it depends on
   * React Native's NSURL conversion. Pinned here so a change is deliberate; verify on device
   * (docs/FIELD_TEST.md) that sharing works from that directory.
   */
  it('percent-encodes the path (it contains spaces)', async () => {
    mockShare.share.mockResolvedValue({ action: 'sharedAction' });
    mockModule.getTracePath.mockReturnValue('/var/mobile/Library/Application Support/traces/a.jsonl');
    await shareTrace('a.jsonl');
    expect(mockShare.share).toHaveBeenCalledWith({ url: 'file:///var/mobile/Library/Application%20Support/traces/a.jsonl' });
  });
});
