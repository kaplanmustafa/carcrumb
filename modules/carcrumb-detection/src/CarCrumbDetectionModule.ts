import { NativeModule, requireNativeModule } from 'expo';

import type {
  CarCrumbDetectionModuleEvents,
  DetectionStateName,
  Diagnostics,
  LocationAuthorization,
  MotionAuthorization,
  ParkingRecord,
  RoutePoint,
  TripRecord,
} from './CarCrumbDetection.types';

// Keep in sync with ios/CarCrumbDetectionModule.swift.
declare class CarCrumbDetectionModule extends NativeModule<CarCrumbDetectionModuleEvents> {
  getState(): DetectionStateName;
  /** Shows the system prompt directly (permission screen's single "Devam" button). */
  requestWhenInUseAuthorization(): Promise<LocationAuthorization>;
  /**
   * Always upgrade; prompts only from 'whenInUse'. Any other status (incl. 'notDetermined')
   * resolves immediately with the current status and shows no prompt: ask While Using first.
   */
  requestAlwaysAuthorization(): Promise<LocationAuthorization>;
  requestMotionAuthorization(): Promise<MotionAuthorization>;
  getDiagnostics(): Promise<Diagnostics>;
  /**
   * Current park ("Arabam nerede") or null. Newest park wins, even a low-confidence one
   * (a newer trip proves the car moved); show `confidence` and offer listRecentParkings().
   * Contains coordinates: never log the result.
   */
  getLastParking(): Promise<ParkingRecord | null>;
  /** Up to 3 parks, current (newest written) first. Contains coordinates: never log the result. */
  listRecentParkings(): Promise<ParkingRecord[]>;
  /**
   * Trips, newest written first (not sorted by startedAt: the device clock can jump; sort
   * in the UI if a by-time view is needed). Pass an integer; natively it is rounded to the nearest integer and
   * clamped to 1...500 (NaN / Infinity → 50).
   */
  listTrips(limit: number): Promise<TripRecord[]>;
  /**
   * Route of one trip (`TripRecord.id`), in driving order. [] for an unknown trip, a trip
   * without route, or an id that is not a non-negative integer. Only points driven at vehicle
   * speed with good accuracy are stored (roughly every 25 m), so the line is an approximation.
   * Contains coordinates: never log the result. Rejects like listTrips.
   */
  getTripRoute(tripId: number): Promise<RoutePoint[]>;
  /**
   * Deletes all history: database rows (+ VACUUM, WAL truncate), engine state (back to IDLE),
   * the park geofence (resolves only after its removal is confirmed; without location
   * permission there is no monitor and this step succeeds) and debug traces.
   * Rejects with code ERR_DELETE_HISTORY on failure.
   */
  deleteAllHistory(): Promise<void>;
  /** Debug builds: trace file names, newest first. Release: always []. */
  listTraces(): string[];
  /** Debug builds: absolute path of a trace from listTraces(). Release: always null. */
  getTracePath(name: string): string | null;
}

export default requireNativeModule<CarCrumbDetectionModule>('CarCrumbDetection');
