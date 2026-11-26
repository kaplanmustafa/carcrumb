/**
 * Test-only: a minimal, explicit stand-in for the React hooks our data hooks use
 * (useState, useRef, useCallback, useEffect with deps), for one component at a time.
 * The project has no React test renderer, so hook tests replace 'react' with `harness.react`:
 *
 *   jest.mock('react', () => require('<path>/__testutils__/hookHarness').harness.react);
 *
 * Semantics kept from React: state/refs/callbacks are slots by call order; effects run after
 * the render when their deps changed (always without deps), the previous cleanup first;
 * unmount runs every cleanup. Not imported by app code. No jest globals (app tsconfig).
 */
type Cleanup = () => void;
type EffectFn = () => void | Cleanup;
type Updater = (previous: unknown) => unknown;

function depsChanged(prev: readonly unknown[] | undefined, next: readonly unknown[] | undefined): boolean {
  if (!prev || !next) return true;
  return prev.length !== next.length || prev.some((v, i) => !Object.is(v, next[i]));
}

class HookHarness {
  private states: unknown[] = [];
  private refs: { current: unknown }[] = [];
  private callbacks: { fn: unknown; deps?: readonly unknown[] }[] = [];
  private effects: { deps?: readonly unknown[]; cleanup?: Cleanup }[] = [];
  private queued: { index: number; fn: EffectFn; deps?: readonly unknown[] }[] = [];
  private cursor = { state: 0, ref: 0, callback: 0, effect: 0 };
  private mounted = false;
  /** Number of setState calls (also after unmount: React would drop them, tests assert none happen). */
  setCalls = 0;
  /** setState calls made after unmount. */
  setCallsAfterUnmount = 0;

  readonly react = {
    useState: (init: unknown) => {
      const i = this.cursor.state++;
      if (!(i in this.states)) this.states[i] = typeof init === 'function' ? (init as () => unknown)() : init;
      const set = (value: unknown) => {
        this.setCalls++;
        if (!this.mounted) this.setCallsAfterUnmount++;
        this.states[i] = typeof value === 'function' ? (value as Updater)(this.states[i]) : value;
      };
      return [this.states[i], set];
    },
    useRef: (initial: unknown) => {
      const i = this.cursor.ref++;
      if (!(i in this.refs)) this.refs[i] = { current: initial };
      return this.refs[i];
    },
    useCallback: (fn: unknown, deps?: readonly unknown[]) => {
      const i = this.cursor.callback++;
      const slot = this.callbacks[i];
      if (!slot || depsChanged(slot.deps, deps)) this.callbacks[i] = { fn, deps };
      return this.callbacks[i].fn;
    },
    useEffect: (fn: EffectFn, deps?: readonly unknown[]) => {
      const i = this.cursor.effect++;
      const slot = this.effects[i];
      if (!slot || depsChanged(slot.deps, deps)) this.queued.push({ index: i, fn, deps });
    },
  };

  /** Renders (or re-renders) the hook and runs the effects whose deps changed. */
  render<T>(hook: () => T): T {
    this.cursor = { state: 0, ref: 0, callback: 0, effect: 0 };
    this.mounted = true;
    const result = hook();
    for (const q of this.queued.splice(0)) {
      this.effects[q.index]?.cleanup?.();
      const cleanup = q.fn();
      this.effects[q.index] = { deps: q.deps, cleanup: cleanup || undefined };
    }
    return result;
  }

  unmount(): void {
    for (const e of this.effects) e?.cleanup?.();
    this.effects = [];
    this.mounted = false;
  }

  /** Fresh component (call in beforeEach). */
  reset(): void {
    this.states = [];
    this.refs = [];
    this.callbacks = [];
    this.effects = [];
    this.queued = [];
    this.mounted = false;
    this.setCalls = 0;
    this.setCallsAfterUnmount = 0;
  }
}

export const harness = new HookHarness();

/** Lets pending promise callbacks run. */
export const flush = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 0));
