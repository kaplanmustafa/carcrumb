/**
 * Permission flow (docs/DECISIONS.md, "App Store ve izinler"):
 * 1. While Using location, 2. motion — each behind a one-button explanation screen.
 * 3. Always is requested later, with context, after the first automatic detection.
 * No step is skippable in-app: declining happens in the system dialog, and the app keeps
 * working without location (konumsuz mod, App Store 5.1.5).
 *
 * Decided from the live authorization status only, so there is no "onboarding done" flag
 * to get out of sync with Settings.
 */
import type { LocationAuthorization, MotionAuthorization, TripRecord } from '../../../modules/carcrumb-detection';

export type OnboardingStep = 'location' | 'motion' | 'done';

export function nextOnboardingStep(location: LocationAuthorization, motion: MotionAuthorization): OnboardingStep {
  if (location === 'notDetermined') return 'location';
  if (motion === 'notDetermined') return 'motion';
  return 'done';
}

/** Location is off for us: denied, restricted, or Location Services disabled system-wide. */
export function isLocationOff(location: LocationAuthorization, servicesEnabled: boolean): boolean {
  return !servicesEnabled || location === 'denied' || location === 'restricted';
}

/**
 * Offer the Always upgrade only with context: While Using is granted and the app has
 * already recorded a confirmed trip, so the user has seen what automatic detection does.
 */
export function shouldOfferAlways(location: LocationAuthorization, trips: readonly TripRecord[]): boolean {
  return location === 'whenInUse' && trips.some((t) => t.status === 'confirmed');
}
