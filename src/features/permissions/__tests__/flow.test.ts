import type { TripRecord } from '../../../../modules/carcrumb-detection';
import { isLocationOff, nextOnboardingStep, shouldOfferAlways } from '../flow';

const trip = (status: TripRecord['status']): TripRecord => ({
  id: 1,
  startedAt: 0,
  endedAt: status === 'open' ? null : 1,
  status,
  distanceMeters: null,
});

describe('nextOnboardingStep', () => {
  it('asks While Using location first', () => {
    expect(nextOnboardingStep('notDetermined', 'notDetermined')).toBe('location');
  });

  it('asks motion once location is decided, whatever the answer', () => {
    for (const loc of ['whenInUse', 'always', 'denied', 'restricted'] as const) {
      expect(nextOnboardingStep(loc, 'notDetermined')).toBe('motion');
    }
  });

  it('is done when both are decided, including refusals (konumsuz mod)', () => {
    expect(nextOnboardingStep('denied', 'denied')).toBe('done');
    expect(nextOnboardingStep('whenInUse', 'authorized')).toBe('done');
  });

  it('never blocks on an engine that has not started', () => {
    expect(nextOnboardingStep('unavailable', 'unknown')).toBe('done');
  });
});

describe('isLocationOff', () => {
  it('is off when denied, restricted or system-wide disabled', () => {
    expect(isLocationOff('denied', true)).toBe(true);
    expect(isLocationOff('restricted', true)).toBe(true);
    expect(isLocationOff('always', false)).toBe(true);
  });

  it('is on when allowed', () => {
    expect(isLocationOff('whenInUse', true)).toBe(false);
    expect(isLocationOff('always', true)).toBe(false);
  });
});

describe('shouldOfferAlways', () => {
  it('needs While Using and a confirmed trip (context first)', () => {
    expect(shouldOfferAlways('whenInUse', [trip('confirmed')])).toBe(true);
  });

  it('is not offered before any confirmed trip', () => {
    expect(shouldOfferAlways('whenInUse', [])).toBe(false);
    expect(shouldOfferAlways('whenInUse', [trip('uncertain'), trip('open')])).toBe(false);
  });

  it('is not offered when Always is already granted or location is off', () => {
    expect(shouldOfferAlways('always', [trip('confirmed')])).toBe(false);
    expect(shouldOfferAlways('denied', [trip('confirmed')])).toBe(false);
    expect(shouldOfferAlways('notDetermined', [trip('confirmed')])).toBe(false);
  });
});
