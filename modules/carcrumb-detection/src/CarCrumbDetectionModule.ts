import { NativeModule, requireNativeModule } from 'expo';

import type {
  CarCrumbDetectionModuleEvents,
  DetectionStateName,
  Diagnostics,
  LocationAuthorization,
  MotionAuthorization,
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
  /** Debug builds: trace file names, newest first. Release: always []. */
  listTraces(): string[];
  /** Debug builds: absolute path of a trace from listTraces(). Release: always null. */
  getTracePath(name: string): string | null;
}

export default requireNativeModule<CarCrumbDetectionModule>('CarCrumbDetection');
