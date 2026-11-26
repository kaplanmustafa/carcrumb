/**
 * HomeScreen logic: which sections are shown for which data. The SwiftUI design components
 * are replaced by named stubs and the returned element tree is inspected directly
 * (HomeScreen uses no hooks; local function components are expanded by calling them).
 */
import { Fragment, isValidElement, type ReactElement, type ReactNode } from 'react';

import type { Diagnostics, ParkingRecord, TripRecord } from '../../../../modules/carcrumb-detection';
import { HomeScreen, type HomeActions } from '../HomeScreen';
import type { HomeData } from '../useHomeData';

jest.mock('../../../design/components', () => {
  const stub = (name: string) => Object.assign(() => null, { displayName: name });
  return {
    InfoRow: stub('InfoRow'),
    PrimaryButton: stub('PrimaryButton'),
    Screen: stub('Screen'),
    SecondaryButton: stub('SecondaryButton'),
    Section: stub('Section'),
    StatusLabel: stub('StatusLabel'),
    TimeRow: stub('TimeRow'),
    Txt: stub('Txt'),
  };
});

// ---- Tree helpers ---------------------------------------------------------------------------

type El = ReactElement<Record<string, unknown> & { children?: ReactNode }>;
type Comp = ((props: unknown) => ReactNode) & { displayName?: string };

/** Flattens the tree into stub elements, expanding fragments and local function components. */
function flatten(node: ReactNode): El[] {
  if (Array.isArray(node)) return node.flatMap(flatten);
  if (!isValidElement(node)) return [];
  const el = node as El;
  if (el.type === Fragment) return flatten(el.props.children);
  const type = el.type as Comp;
  if (typeof type === 'function' && !type.displayName) return flatten(type(el.props));
  return [el, ...flatten(el.props.children)];
}

const nameOf = (el: El) => (el.type as Comp).displayName;

function render(data: HomeData, actions: HomeActions = makeActions()) {
  const all = flatten(HomeScreen({ data, actions }));
  const sections = all.filter((e) => nameOf(e) === 'Section');
  const section = (title: string) => sections.find((s) => s.props.title === title);
  const inside = (title: string) => {
    const s = section(title);
    return s ? flatten(s.props.children) : [];
  };
  return {
    titles: sections.map((s) => s.props.title as string | undefined),
    section,
    inside,
    buttons: (title: string) => inside(title).filter((e) => /Button$/.test(nameOf(e) ?? '')),
    texts: (title: string) =>
      inside(title)
        .filter((e) => nameOf(e) === 'Txt')
        .map((e) => e.props.children),
  };
}

// ---- Data -----------------------------------------------------------------------------------

const makeActions = (): HomeActions => ({
  onDirections: jest.fn(),
  onOpenSettings: jest.fn(),
});

const diag = (authorization: Diagnostics['location']['authorization'], servicesEnabled = true) =>
  ({ location: { authorization, servicesEnabled } }) as unknown as Diagnostics;

const park = (id: number, confidence: ParkingRecord['confidence'], parkedAt = id * 1000): ParkingRecord => ({
  id,
  tripId: id,
  latitude: 41.0,
  longitude: -40.0,
  accuracy: 8,
  confidence,
  parkedAt,
});

const confirmedTrip: TripRecord = { id: 1, startedAt: 0, endedAt: 1, status: 'confirmed', distanceMeters: null };

const base = (over: Partial<HomeData> = {}): HomeData => ({
  loaded: true,
  state: 'IDLE',
  diagnostics: diag('whenInUse'),
  parking: null,
  recentParkings: [],
  trips: [],
  storeUnavailable: false,
  motionAsked: true,
  alwaysAsked: false,
  ...over,
});

// ---- Tests ----------------------------------------------------------------------------------

describe('HomeScreen sections', () => {
  it('always shows the car and status sections', () => {
    const r = render(base());
    expect(r.titles).toEqual(['Aracın', 'Durum']);
  });

  it('without diagnostics (engine not started) shows no permission cards', () => {
    const r = render(base({ diagnostics: null, trips: [confirmedTrip], alwaysAsked: true }));
    expect(r.titles).toEqual(['Aracın', 'Durum']);
  });

  describe('konumsuz mod card', () => {
    it.each([
      ['denied', true],
      ['restricted', true],
      ['always', false],
    ] as const)('location %s / services %s → card with one Settings button, history still shown', (auth, services) => {
      const actions = makeActions();
      const r = render(base({ diagnostics: diag(auth, services), parking: park(1, 'high') }), actions);
      expect(r.titles[0]).toBe('Konum kapalı');
      expect(r.titles).toContain('Aracın');
      const buttons = r.buttons('Konum kapalı');
      expect(buttons).toHaveLength(1);
      (buttons[0].props.onPress as () => void)();
      expect(actions.onOpenSettings).toHaveBeenCalledTimes(1);
    });

    it.each(['whenInUse', 'always', 'notDetermined'] as const)('location %s → no card', (auth) => {
      expect(render(base({ diagnostics: diag(auth) })).section('Konum kapalı')).toBeUndefined();
    });
  });

  describe('Always in Settings card', () => {
    const CARD = 'Arka planda kayıt kapalı';

    it('Always asked, user kept While Using, services on → card with one "Ayarları aç" button', () => {
      const actions = makeActions();
      const r = render(base({ alwaysAsked: true }), actions);
      expect(r.section('Konum kapalı')).toBeUndefined();
      const buttons = r.buttons(CARD);
      expect(buttons).toHaveLength(1);
      expect(buttons[0].props.label).toBe('Ayarları aç');
      (buttons[0].props.onPress as () => void)();
      expect(actions.onOpenSettings).toHaveBeenCalledTimes(1);
    });

    it.each([
      ['Always not asked yet (onboarding still to show it)', base({ alwaysAsked: false })],
      ['Always granted', base({ diagnostics: diag('always'), alwaysAsked: true })],
      ['location denied (konumsuz card instead)', base({ diagnostics: diag('denied'), alwaysAsked: true })],
      ['location not determined', base({ diagnostics: diag('notDetermined'), alwaysAsked: true })],
      ['engine not started (no diagnostics)', base({ diagnostics: null, alwaysAsked: true })],
    ])('not shown: %s', (_label, data) => {
      expect(render(data).section(CARD)).toBeUndefined();
    });

    it('not shown while Location Services are off system-wide: only the "Konum kapalı" card', () => {
      const r = render(base({ diagnostics: diag('whenInUse', false), alwaysAsked: true, trips: [confirmedTrip] }));
      expect(r.section('Konum kapalı')).toBeDefined();
      expect(r.section(CARD)).toBeUndefined();
    });

    it('confirmed trips no longer matter (Always is part of onboarding)', () => {
      expect(render(base({ alwaysAsked: true, trips: [] })).section(CARD)).toBeDefined();
    });
  });

  describe('park and alternatives', () => {
    it('no park: empty copy; locked store: unlock copy', () => {
      expect(render(base()).texts('Aracın')[0]).toBe('Henüz park kaydı yok.');
      expect(render(base({ storeUnavailable: true })).texts('Aracın')[0]).toBe('Kayıtlar telefonun kilidi açılınca görünür.');
    });

    it('high-confidence park: directions button, no hint, no alternatives', () => {
      const actions = makeActions();
      const current = park(3, 'high');
      const r = render(base({ parking: current, recentParkings: [current, park(2, 'high'), park(1, 'low')] }), actions);
      const footer = r.section('Aracın')?.props.footer as string;
      expect(footer).not.toContain('Konum tahmini');
      expect(footer).toContain('Apple Haritalar');
      expect(r.section('Önceki parklar')).toBeUndefined();
      const buttons = r.buttons('Aracın');
      expect(buttons).toHaveLength(1);
      (buttons[0].props.onPress as () => void)();
      expect(actions.onDirections).toHaveBeenCalledWith(current);
    });

    it('low-confidence park: hint + the other recent parks as alternatives (current excluded)', () => {
      const actions = makeActions();
      const current = park(3, 'low');
      const older = [park(2, 'high'), park(1, 'low')];
      const r = render(base({ parking: current, recentParkings: [current, ...older] }), actions);
      expect(r.section('Aracın')?.props.footer).toEqual(expect.stringContaining('Konum tahmini'));
      const buttons = r.buttons('Önceki parklar');
      expect(buttons).toHaveLength(2);
      buttons.forEach((b) => (b.props.onPress as () => void)());
      expect(actions.onDirections).toHaveBeenNthCalledWith(1, older[0]);
      expect(actions.onDirections).toHaveBeenNthCalledWith(2, older[1]);
      expect(actions.onDirections).not.toHaveBeenCalledWith(current);
    });

    it('low-confidence park with no other recent park: no alternatives section', () => {
      const current = park(3, 'low');
      expect(render(base({ parking: current, recentParkings: [current] })).section('Önceki parklar')).toBeUndefined();
    });
  });
});
