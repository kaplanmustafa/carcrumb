import { useCallback, useEffect, useRef, useState } from 'react';

import CarCrumbDetection, { type TripRecord } from '../../../modules/carcrumb-detection';
import { sortTripsForHistory } from './format';

const HISTORY_LIMIT = 200;

/** Trip history, newest start first. Refreshes on detection state changes (a trip ends). */
export function useTrips(): { trips: TripRecord[]; loaded: boolean } {
  const [state, setState] = useState<{ trips: TripRecord[]; loaded: boolean }>({ trips: [], loaded: false });
  const latest = useRef(0);
  const mounted = useRef(true);

  const refresh = useCallback(async () => {
    const run = ++latest.current;
    const trips = await CarCrumbDetection.listTrips(HISTORY_LIMIT).catch(() => [] as TripRecord[]);
    if (!mounted.current || run !== latest.current) return;
    setState({ trips: sortTripsForHistory(trips), loaded: true });
  }, []);

  useEffect(() => {
    mounted.current = true;
    const sub = CarCrumbDetection.addListener('onStateChange', () => void refresh());
    void refresh();
    return () => {
      mounted.current = false;
      sub.remove();
    };
  }, [refresh]);

  return state;
}

export type RouteState = { status: 'loading' } | { status: 'ready'; points: { latitude: number; longitude: number }[] } | { status: 'error' };

/** Loads one trip's route when its page is pushed. Contains coordinates: never log. */
export function useTripRoute(
  tripId: number,
  loadRoute: (tripId: number) => Promise<{ latitude: number; longitude: number }[]>,
): RouteState {
  const [state, setState] = useState<RouteState>({ status: 'loading' });
  useEffect(() => {
    let active = true;
    setState({ status: 'loading' });
    loadRoute(tripId).then(
      (points) => active && setState({ status: 'ready', points }),
      () => active && setState({ status: 'error' }),
    );
    return () => {
      active = false;
    };
  }, [tripId, loadRoute]);
  return state;
}
