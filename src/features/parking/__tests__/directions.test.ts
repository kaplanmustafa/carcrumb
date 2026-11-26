import { walkingDirectionsUrl } from '../directions';

describe('walkingDirectionsUrl', () => {
  it('opens Apple Maps walking directions to the park', () => {
    expect(walkingDirectionsUrl(41.000123, -40.000456)).toBe('maps://?daddr=41.000123,-40.000456&dirflg=w');
  });

  it('rounds to 6 decimals', () => {
    expect(walkingDirectionsUrl(41.1234567891, -39.9)).toBe('maps://?daddr=41.123457,-39.900000&dirflg=w');
  });

  it('rejects invalid coordinates instead of opening a broken link', () => {
    expect(walkingDirectionsUrl(Number.NaN, 0)).toBeNull();
    expect(walkingDirectionsUrl(0, Number.POSITIVE_INFINITY)).toBeNull();
    expect(walkingDirectionsUrl(91, 0)).toBeNull();
    expect(walkingDirectionsUrl(0, -181)).toBeNull();
  });
});
