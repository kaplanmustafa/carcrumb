import { statePresentation } from '../../features/detection/presentation';
import { color, icon, radius, space, typography } from '../tokens';

describe('design tokens', () => {
  it('spacing is on the 2/4-pt grid and strictly increasing', () => {
    const values = Object.values(space);
    values.forEach((v) => expect(v % 2).toBe(0));
    values.slice(1).forEach((v, i) => expect(v).toBeGreaterThan(values[i]));
  });

  it('radii are strictly increasing', () => {
    const values = Object.values(radius);
    values.slice(1).forEach((v, i) => expect(v).toBeGreaterThan(values[i]));
  });

  it('every type role uses a Dynamic Type text style and no fixed size', () => {
    Object.values(typography).forEach((t) => {
      expect(t.textStyle).toBeTruthy();
      expect(t).not.toHaveProperty('size');
    });
  });
});

describe('detection state presentation', () => {
  const states = ['IDLE', 'MAYBE_DRIVING', 'DRIVING', 'MAYBE_PARKED', 'PARKED'] as const;

  it('covers exactly the detection states', () => {
    expect(Object.keys(statePresentation).sort()).toEqual([...states].sort());
  });

  it.each(states)('%s uses existing tokens and has copy', (s) => {
    const p = statePresentation[s];
    expect(p.title.length).toBeGreaterThan(0);
    expect(p.description.length).toBeGreaterThan(0);
    expect(icon).toHaveProperty(p.iconName);
    expect(color.status).toHaveProperty(p.tone);
  });
});
