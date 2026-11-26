import { useCallback, useEffect, useRef, useState } from 'react';
import { AppState, Share } from 'react-native';

import CarCrumbDetection, { type Diagnostics } from '../../../modules/carcrumb-detection';

const REFRESH_MS = 5_000;

/**
 * Live diagnostics while the page is on screen (mount it only while it is pushed): polls
 * every 5 s and on state changes. Contains no coordinates.
 */
export function useDiagnostics(): { diagnostics: Diagnostics | null; traces: string[]; refresh: () => void } {
  const [state, setState] = useState<{ diagnostics: Diagnostics | null; traces: string[] }>({ diagnostics: null, traces: [] });
  const latest = useRef(0);
  const mounted = useRef(true);

  const refresh = useCallback(() => {
    const run = ++latest.current;
    void CarCrumbDetection.getDiagnostics()
      .catch(() => null)
      .then((diagnostics) => {
        if (!mounted.current || run !== latest.current) return;
        setState({ diagnostics, traces: CarCrumbDetection.listTraces() });
      });
  }, []);

  useEffect(() => {
    mounted.current = true;
    const sub = CarCrumbDetection.addListener('onStateChange', refresh);
    // Poll only while the app is in the foreground: with the page left open during a drive the
    // JS timers would otherwise keep crossing to the engine queue every 5 s in the background.
    let timer: ReturnType<typeof setInterval> | null = null;
    const start = () => {
      if (timer === null) timer = setInterval(refresh, REFRESH_MS);
    };
    const stop = () => {
      if (timer !== null) clearInterval(timer);
      timer = null;
    };
    const appSub = AppState.addEventListener('change', (s) => {
      if (s === 'active') {
        refresh();
        start();
      } else {
        stop();
      }
    });
    if (AppState.currentState !== 'background') start();
    refresh();
    return () => {
      mounted.current = false;
      sub.remove();
      appSub.remove();
      stop();
    };
  }, [refresh]);

  return { ...state, refresh };
}

/**
 * Opens the iOS share sheet for one debug trace. Only the user's explicit tap shares it;
 * the path is never logged. Release builds have no traces, so this is a no-op there.
 */
export async function shareTrace(name: string): Promise<void> {
  const path = CarCrumbDetection.getTracePath(name);
  if (!path) return;
  // The path contains spaces ("Application Support"): encode it for a valid file URL.
  await Share.share({ url: `file://${encodeURI(path)}` }).catch(() => undefined);
}
