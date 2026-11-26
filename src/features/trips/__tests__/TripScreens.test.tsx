/**
 * TripScreens section logic (no renderer: design components are stubs, the element tree is
 * inspected, see src/__testutils__/elementTree.ts).
 */
import type { TripRecord } from '../../../../modules/carcrumb-detection';
import { all, flatten, texts } from '../../../__testutils__/elementTree';
import { HistoryPage, TripPage, tripIdFromValue, tripValue } from '../TripScreens';

jest.mock('../../../design/components', () =>
  require('../../../__testutils__/elementTree').stubComponents([
    'DetailRow',
    'Destination',
    'EmptyState',
    'InfoRow',
    'NavRow',
    'Section',
    'Txt',
  ]),
);
jest.mock('../../../design/RouteMap', () => require('../../../__testutils__/elementTree').stubComponents(['RouteMap']));

const t0 = Date.UTC(2026, 10, 26, 11, 0);
const trip = (over: Partial<TripRecord> = {}): TripRecord => ({
  id: 4,
  startedAt: t0,
  endedAt: t0 + 23 * 60_000,
  status: 'confirmed',
  distanceMeters: 12_400,
  ...over,
});
const pt = (lat: number) => ({ latitude: lat, longitude: -40.0 });
const info = (els: ReturnType<typeof flatten>) =>
  Object.fromEntries(all(els, 'InfoRow').map((e) => [e.props.label as string, e.props.value as string]));

describe('trip value routing', () => {
  it('round-trips ids and rejects anything else', () => {
    expect(tripIdFromValue(tripValue(42))).toBe(42);
    expect(tripIdFromValue('history')).toBeNull();
    expect(tripIdFromValue('trip:')).toBeNull();
    expect(tripIdFromValue('trip:-1')).toBeNull();
    expect(tripIdFromValue('trip:1x')).toBeNull();
  });
});

describe('HistoryPage', () => {
  it('loaded and empty → empty state only', () => {
    const els = flatten(HistoryPage({ trips: [], loaded: true }));
    expect(all(els, 'EmptyState')).toHaveLength(1);
    expect(all(els, 'Section')).toHaveLength(0);
  });

  it('not loaded yet → no empty state flash', () => {
    const els = flatten(HistoryPage({ trips: [], loaded: false }));
    expect(all(els, 'EmptyState')).toHaveLength(0);
  });

  it('one row per trip linking to its page; status note only for non-confirmed trips', () => {
    const trips = [trip({ id: 1 }), trip({ id: 2, status: 'uncertain' }), trip({ id: 3, status: 'open', endedAt: null })];
    const els = flatten(HistoryPage({ trips, loaded: true }));
    expect(all(els, 'NavRow').map((e) => e.props.value)).toEqual(['trip:1', 'trip:2', 'trip:3']);
    expect(all(els, 'DetailRow').map((e) => e.props.note)).toEqual([undefined, 'Belirsiz', 'Devam ediyor']);
    expect(all(els, 'Section')[0].props.footer).toEqual(expect.stringContaining('Belirsiz yolculuklar'));
  });
});

describe('TripPage', () => {
  const page = (t: TripRecord, route: Parameters<typeof TripPage>[0]['route']) => flatten(TripPage({ trip: t, route }));

  it('loading → loading text, no map', () => {
    const els = page(trip(), { status: 'loading' });
    expect(texts(els)).toContain('Rota yükleniyor…');
    expect(all(els, 'RouteMap')).toHaveLength(0);
  });

  it('error → error text, no map, facts still shown', () => {
    const els = page(trip(), { status: 'error' });
    expect(texts(els)).toContain('Rota şu an okunamadı.');
    expect(all(els, 'RouteMap')).toHaveLength(0);
    expect(info(els)['Durum']).toBe('Onaylı');
  });

  it('ready with a route → map with the points, no fallback text', () => {
    const points = [pt(41.0), pt(41.01), pt(41.02)];
    const els = page(trip(), { status: 'ready', points });
    const maps = all(els, 'RouteMap');
    expect(maps).toHaveLength(1);
    expect(maps[0].props.points).toBe(points);
    expect(maps[0].props.camera).toBeTruthy();
    expect(texts(els)).toHaveLength(0);
  });

  it.each([[[]], [[pt(41.0)]]])('ready with %j → "no route" text, no map (rotasız)', (points) => {
    const els = page(trip({ distanceMeters: null }), { status: 'ready', points });
    expect(texts(els)).toEqual(['Bu yolculuk için rota kaydı yok.']);
    expect(all(els, 'RouteMap')).toHaveLength(0);
  });

  it('confirmed trip: duration and distance, no status note', () => {
    const els = page(trip(), { status: 'ready', points: [] });
    const facts = info(els);
    expect(facts['Süre']).toBe('23 dk');
    expect(facts['Mesafe']).toBe('12,4 km');
    expect(all(els, 'Section')[1].props.footer).toBeUndefined();
  });

  it('uncertain trip: "Belirsiz" with the no-park note', () => {
    const els = page(trip({ status: 'uncertain' }), { status: 'ready', points: [] });
    expect(info(els)['Durum']).toBe('Belirsiz');
    expect(all(els, 'Section')[1].props.footer).toEqual(expect.stringContaining('park yeri yazılmadı'));
  });

  it('open trip: end "Devam ediyor", no duration; unknown distance hidden', () => {
    const els = page(trip({ status: 'open', endedAt: null, distanceMeters: null }), { status: 'loading' });
    const facts = info(els);
    expect(facts['Bitiş']).toBe('Devam ediyor');
    expect(facts).not.toHaveProperty('Süre');
    expect(facts).not.toHaveProperty('Mesafe');
  });
});
