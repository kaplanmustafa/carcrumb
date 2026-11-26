import { isLocationOff, needsAlwaysInSettings, nextOnboardingStep, type PermissionSnapshot } from '../flow';

const fresh: PermissionSnapshot = {
  location: 'notDetermined',
  servicesEnabled: true,
  motion: 'notDetermined',
  motionAvailable: true,
  motionAsked: false,
  alwaysAsked: false,
};
const snap = (over: Partial<PermissionSnapshot>): PermissionSnapshot => ({ ...fresh, ...over });

describe('nextOnboardingStep', () => {
  it('asks While Using location first', () => {
    expect(nextOnboardingStep(fresh)).toBe('location');
  });

  it('asks motion once location is decided, whatever the answer', () => {
    for (const location of ['whenInUse', 'always', 'denied', 'restricted'] as const) {
      expect(nextOnboardingStep(snap({ location }))).toBe('motion');
    }
  });

  it('asks the Always upgrade right after motion, from While Using only', () => {
    expect(nextOnboardingStep(snap({ location: 'whenInUse', motion: 'authorized' }))).toBe('always');
    expect(nextOnboardingStep(snap({ location: 'whenInUse', motion: 'denied' }))).toBe('always');
  });

  it('is done when everything is decided, including refusals (konumsuz mod)', () => {
    expect(nextOnboardingStep(snap({ location: 'always', motion: 'authorized' }))).toBe('done');
    expect(nextOnboardingStep(snap({ location: 'denied', motion: 'denied' }))).toBe('done');
  });

  it('does not loop on the Always screen after the one-time dialog (user kept While Using)', () => {
    expect(nextOnboardingStep(snap({ location: 'whenInUse', motion: 'authorized', alwaysAsked: true }))).toBe('done');
  });

  it('skips location when Location Services are off (no dialog possible, app must stay usable)', () => {
    expect(nextOnboardingStep(snap({ servicesEnabled: false }))).toBe('motion');
    expect(nextOnboardingStep(snap({ servicesEnabled: false, motion: 'authorized' }))).toBe('done');
  });

  it('skips motion when unavailable (simulator) or already asked', () => {
    expect(nextOnboardingStep(snap({ location: 'denied', motionAvailable: false }))).toBe('done');
    expect(nextOnboardingStep(snap({ location: 'denied', motionAsked: true }))).toBe('done');
  });

  it('never blocks on an engine that has not started', () => {
    expect(nextOnboardingStep(snap({ location: 'unavailable', motion: 'unknown' }))).toBe('done');
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

describe('needsAlwaysInSettings', () => {
  it('points to Settings only after the one-time upgrade dialog was declined', () => {
    expect(needsAlwaysInSettings('whenInUse', true, true)).toBe(true);
    expect(needsAlwaysInSettings('whenInUse', false, true)).toBe(false);
    expect(needsAlwaysInSettings('always', true, true)).toBe(false);
    expect(needsAlwaysInSettings('denied', true, true)).toBe(false);
  });

  it('is not shown while Location Services are off (the Konum kapalı card covers it)', () => {
    expect(needsAlwaysInSettings('whenInUse', true, false)).toBe(false);
  });
});
