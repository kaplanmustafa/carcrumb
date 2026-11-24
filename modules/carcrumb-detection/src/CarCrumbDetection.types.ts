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

/** Mirrors `DetectionEngine.name(of: CLAuthorizationStatus)`. "unavailable" = engine not started. */
export type LocationAuthorization =
  | 'notDetermined'
  | 'restricted'
  | 'denied'
  | 'whenInUse'
  | 'always'
  | 'unknown'
  | 'unavailable';

/** Mirrors `DetectionEngine.name(of: CMAuthorizationStatus)`. */
export type MotionAuthorization = 'notDetermined' | 'restricted' | 'denied' | 'authorized' | 'unknown';

/** `CLServiceSession.Diagnostic` flags (iOS 18). Mirrors `ServiceSessionFlags.dictionary`. */
export type ServiceSessionDiagnostics = {
  authorizationDenied: boolean;
  authorizationDeniedGlobally: boolean;
  authorizationRestricted: boolean;
  insufficientlyInUse: boolean;
  serviceSessionRequired: boolean;
  fullAccuracyDenied: boolean;
  alwaysAuthorizationDenied: boolean;
  authorizationRequestInProgress: boolean;
};

/** Flags of the latest live location update while GPS is on. Mirrors `LiveUpdateFlags.dictionary`. */
export type LiveUpdateDiagnostics = {
  stationary: boolean;
  locationUnavailable: boolean;
  accuracyLimited: boolean;
  insufficientlyInUse: boolean;
  serviceSessionRequired: boolean;
};

/** Result of `getDiagnostics()`. Contains no coordinates by design. Mirrors `DetectionEngine.diagnostics()`. */
export type Diagnostics = {
  engine: {
    started: boolean;
    state: DetectionStateName;
    gpsActive: boolean;
    geofenceActive: boolean;
    carLinkConnected: boolean;
    /** True only in debug builds. */
    traceRecording: boolean;
  };
  location: {
    authorization: LocationAuthorization;
    /** Missing when the engine has not started. */
    accuracy?: 'full' | 'reduced';
    servicesEnabled: boolean;
  };
  /** null until a CLServiceSession exists (authorization decided) and reported once. */
  serviceSession: ServiceSessionDiagnostics | null;
  /** null while GPS is off. */
  liveUpdates: LiveUpdateDiagnostics | null;
  motion: {
    available: boolean;
    authorization: MotionAuthorization;
  };
};
