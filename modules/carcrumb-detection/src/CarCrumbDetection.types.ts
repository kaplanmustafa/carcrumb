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
    /** A live location loop is running right now. */
    gpsActive: boolean;
    /** The state machine wants GPS; true while gpsActive is false means a restart is pending. */
    gpsRequested: boolean;
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

/** Mirrors `Confidence` in Swift. */
export type ParkingConfidence = 'low' | 'high';

/**
 * A stored park point. Mirrors `BridgeValues.parking` (ios/CarCrumbDetectionModule.swift).
 * Contains raw coordinates: use them for display / map links only, never log them
 * (no console.log, no error reports) and never send them over the network.
 */
export type ParkingRecord = {
  id: number;
  /** null when the trip row is unknown (e.g. the database was locked when the trip began). */
  tripId: number | null;
  latitude: number;
  longitude: number;
  /** Horizontal accuracy of the chosen fix, metres. */
  accuracy: number;
  confidence: ParkingConfidence;
  /** Milliseconds since 1970 (`new Date(parkedAt)`). */
  parkedAt: number;
};

/**
 * Mirrors `StoredTripStatus` in Swift; 'open' = trip in progress (no status yet).
 * 'uncertain' = no car link (bus, taxi): out of statistics until confirmed, never has a park.
 * 'recovered' = reconstructed from motion history without a route (not produced yet).
 */
export type TripStatusName = 'confirmed' | 'uncertain' | 'recovered' | 'open';

/** Mirrors `BridgeValues.trip` (ios/CarCrumbDetectionModule.swift). */
export type TripRecord = {
  id: number;
  /** Milliseconds since 1970; the real start (refined from motion history when possible). */
  startedAt: number;
  /** Milliseconds since 1970; null while the trip is open. */
  endedAt: number | null;
  status: TripStatusName;
  /**
   * Driven distance in metres (haversine sum of the recorded route points, accumulated while
   * driving, so it is current for an open trip too and survives route thinning / retention).
   * null for trips without a route (e.g. begun before the first unlock after a restart, or no
   * usable GPS yet).
   */
  distanceMeters: number | null;
};

/**
 * How long trip routes are kept. Mirrors `RouteRetention` in Swift (ios/Store/RouteRetention.swift).
 * After the limit only the route points are deleted; the trip (dates, duration, distance, status) stays.
 */
export type RouteRetention = 'threeMonths' | 'twelveMonths' | 'forever';

/**
 * One point of a trip route. Mirrors `BridgeValues.routePoint` (ios/CarCrumbDetectionModule.swift).
 * Contains raw coordinates: use them for drawing the route only, never log them
 * (no console.log, no error reports) and never send them over the network.
 */
export type RoutePoint = {
  latitude: number;
  longitude: number;
  /** Fix time, milliseconds since 1970 (`new Date(timestamp)`). */
  timestamp: number;
};

/**
 * Rejection codes of the history functions (`error.code`):
 * - ERR_STORE_UNAVAILABLE: database not readable yet (device not unlocked since restart),
 * - ERR_STORE: other read error,
 * - ERR_DELETE_HISTORY: deleteAllHistory failed; the message is the failed step
 *   ('database' | 'stateFile' | 'geofence' | 'traces'),
 * - ERR_INVALID_ARGUMENT: setRouteRetention got an unknown value.
 */
export type HistoryErrorCode = 'ERR_STORE_UNAVAILABLE' | 'ERR_STORE' | 'ERR_DELETE_HISTORY' | 'ERR_INVALID_ARGUMENT';
