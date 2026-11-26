import { useCallback, useEffect, useRef, useState } from 'react';
import { Share } from 'react-native';

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
    const timer = setInterval(refresh, REFRESH_MS);
    refresh();
    return () => {
      mounted.current = false;
      sub.remove();
      clearInterval(timer);
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
  await Share.share({ url: `file://${path}` }).catch(() => undefined);
}
