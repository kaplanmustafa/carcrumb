/** Mirrors `DetectionState.name` in Swift. Keep in sync with DetectionTypes.swift. */
export type DetectionStateName =
  | 'IDLE'
  | 'MAYBE_DRIVING'
  | 'DRIVING'
  | 'MAYBE_PARKED'
  | 'PARKED';

export type StateChangeEvent = {
  state: DetectionStateName;
};

export type CarCrumbDetectionModuleEvents = {
  onStateChange: (event: StateChangeEvent) => void;
};
