import { useCallback, useEffect, useRef, useState } from 'react';
import { AppState } from 'react-native';

import CarCrumbDetection, {
  type DetectionStateName,
  type Diagnostics,
  type ParkingRecord,
  type TripRecord,
} from '../../../modules/carcrumb-detection';
import { wasAsked } from '../permissions/asked';

export type HomeData = {
  loaded: boolean;
  state: DetectionStateName;
  diagnostics: Diagnostics | null;
  parking: ParkingRecord | null;
  recentParkings: ParkingRecord[];
  trips: TripRecord[];
  /** The database is not readable yet (device restarted and not unlocked). */
  storeUnavailable: boolean;
  /** iOS shows these dialogs once; see src/features/permissions/asked.ts. */
  motionAsked: boolean;
  alwaysAsked: boolean;
};

const TRIPS_FOR_HOME = 20;

const initial = (): HomeData => ({
  loaded: false,
  state: CarCrumbDetection.getState(),
  diagnostics: null,
  parking: null,
  recentParkings: [],
  trips: [],
  storeUnavailable: false,
  motionAsked: wasAsked('motion'),
  alwaysAsked: wasAsked('always'),
});

function errorCode(e: unknown): string | undefined {
  return typeof e === 'object' && e !== null && 'code' in e ? String((e as { code: unknown }).code) : undefined;
}

/**
 * Everything the home screen shows, read from the native module (Swift is the only writer).
 * Refreshes on mount, on every detection state change and when the app becomes active
 * (permissions may have changed in Settings). Contains coordinates: never log it.
 */
export function useHomeData(): { data: HomeData; refresh: () => Promise<void> } {
  const [data, setData] = useState<HomeData>(initial);
  const mounted = useRef(true);
  // Several refreshes can overlap (dialog closes → .then(refresh) and AppState 'active' at
  // once, plus state changes). Only the most recently started one may write.
  const latest = useRef(0);

  const refresh = useCallback(async () => {
    const run = ++latest.current;
    const diagnostics = await CarCrumbDetection.getDiagnostics().catch(() => null);
    let storeUnavailable = false;
    const read = async <T,>(fn: () => Promise<T>, fallback: T): Promise<T> => {
      try {
        return await fn();
      } catch (e) {
        if (errorCode(e) === 'ERR_STORE_UNAVAILABLE') storeUnavailable = true;
        return fallback;
      }
    };
    const [parking, recentParkings, trips] = await Promise.all([
      read(() => CarCrumbDetection.getLastParking(), null),
      read(() => CarCrumbDetection.listRecentParkings(), [] as ParkingRecord[]),
      read(() => CarCrumbDetection.listTrips(TRIPS_FOR_HOME), [] as TripRecord[]),
    ]);
    if (!mounted.current || run !== latest.current) return;
    setData({
      loaded: true,
      state: CarCrumbDetection.getState(),
      diagnostics,
      parking,
      recentParkings,
      trips,
      storeUnavailable,
      motionAsked: wasAsked('motion'),
      alwaysAsked: wasAsked('always'),
    });
  }, []);

  useEffect(() => {
    mounted.current = true;
    const stateSub = CarCrumbDetection.addListener('onStateChange', () => void refresh());
    const appSub = AppState.addEventListener('change', (s) => {
      if (s === 'active') void refresh();
    });
    // Subscribed first, then read: a change in between is not missed.
    void refresh();
    return () => {
      mounted.current = false;
      stateSub.remove();
      appSub.remove();
    };
  }, [refresh]);

  return { data, refresh };
}
