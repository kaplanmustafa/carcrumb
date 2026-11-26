/**
 * Permission flow (docs/DECISIONS.md, "İzin akışı"):
 * 1. While Using location, 2. motion, 3. Always — each behind a one-button explanation
 * screen that goes straight to the system dialog. Declining happens in the system dialog,
 * and the app keeps working without location (konumsuz mod, App Store 5.1.5).
 *
 * Decided from the live authorization status plus two "already asked" marks, because iOS
 * shows the motion and the Always-upgrade dialogs only once: without the marks a user who
 * declined would be stuck on the explanation screen.
 */
import type { LocationAuthorization, MotionAuthorization } from '../../../modules/carcrumb-detection';

export type OnboardingStep = 'location' | 'motion' | 'always' | 'done';

export type PermissionSnapshot = {
  location: LocationAuthorization;
  /** Location Services switched on system-wide. Off: iOS shows no permission dialog at all. */
  servicesEnabled: boolean;
  motion: MotionAuthorization;
  /** Motion activity hardware/API available (false on the simulator). */
  motionAvailable: boolean;
  motionAsked: boolean;
  alwaysAsked: boolean;
};

export function nextOnboardingStep(p: PermissionSnapshot): OnboardingStep {
  // With Location Services off iOS cannot show the dialog; skip to keep the app usable.
  if (p.location === 'notDetermined' && p.servicesEnabled) return 'location';
  if (p.motion === 'notDetermined' && p.motionAvailable && !p.motionAsked) return 'motion';
  // The upgrade dialog only exists from While Using, and iOS shows it once.
  if (p.location === 'whenInUse' && !p.alwaysAsked) return 'always';
  return 'done';
}

/** Location is off for us: denied, restricted, or Location Services disabled system-wide. */
export function isLocationOff(location: LocationAuthorization, servicesEnabled: boolean): boolean {
  return !servicesEnabled || location === 'denied' || location === 'restricted';
}

/**
 * Always was asked and the user kept While Using: automatic detection cannot wake the app,
 * and iOS will not show the dialog again, so the home screen points to Settings instead.
 */
export function needsAlwaysInSettings(
  location: LocationAuthorization,
  alwaysAsked: boolean,
  servicesEnabled: boolean,
): boolean {
  // With Location Services off the "Konum kapalı" card already covers it; upgrading is moot.
  return servicesEnabled && location === 'whenInUse' && alwaysAsked;
}
