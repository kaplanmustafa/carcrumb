import type { Diagnostics } from '../../../../modules/carcrumb-detection';
import { diagnosticsGroups } from '../rows';

const base: Diagnostics = {
  engine: {
    started: true,
    state: 'DRIVING',
    gpsActive: true,
    gpsRequested: true,
    geofenceActive: false,
    carLinkConnected: true,
    traceRecording: true,
  },
  location: { authorization: 'always', accuracy: 'full', servicesEnabled: true },
  serviceSession: {
    authorizationDenied: false,
    authorizationDeniedGlobally: false,
    authorizationRestricted: false,
    insufficientlyInUse: false,
    serviceSessionRequired: false,
    fullAccuracyDenied: false,
    alwaysAuthorizationDenied: false,
    authorizationRequestInProgress: false,
  },
  liveUpdates: {
    stationary: false,
    locationUnavailable: false,
    accuracyLimited: false,
    insufficientlyInUse: false,
    serviceSessionRequired: false,
  },
  motion: { available: true, authorization: 'authorized' },
};

const group = (d: Diagnostics, title: string) => diagnosticsGroups(d).find((g) => g.title === title)!;
const row = (d: Diagnostics, title: string, label: string) => group(d, title).rows.find((r) => r.label === label)!;
const warnings = (d: Diagnostics) => diagnosticsGroups(d).flatMap((g) => g.rows.filter((r) => r.warn).map((r) => r.label));

describe('diagnosticsGroups', () => {
  it('a healthy driving engine shows no warnings', () => {
    expect(warnings(base)).toEqual([]);
    expect(row(base, 'Motor', 'Durum').value).toBe('Sürüşte');
  });

  it('warns when GPS is wanted but not running (restart pending / no permission)', () => {
    const d = { ...base, engine: { ...base.engine, gpsActive: false } };
    expect(row(d, 'Motor', 'GPS isteniyor').warn).toBe(true);
    expect(group(d, 'Motor').footer).toMatch(/GPS isteniyor/);
  });

  it('anything below Always is a warning for automatic detection', () => {
    const d = { ...base, location: { ...base.location, authorization: 'whenInUse' as const } };
    expect(row(d, 'Konum', 'Yetki')).toEqual({ label: 'Yetki', value: 'Kullanırken', warn: true });
  });

  it('flags iOS session problems such as insufficientlyInUse', () => {
    const d = { ...base, serviceSession: { ...base.serviceSession!, insufficientlyInUse: true } };
    expect(warnings(d)).toContain('Yetersiz kullanım (insufficientlyInUse)');
  });

  it('informational flags are not warnings', () => {
    const d = {
      ...base,
      serviceSession: { ...base.serviceSession!, authorizationRequestInProgress: true },
      liveUpdates: { ...base.liveUpdates!, stationary: true },
    };
    expect(warnings(d)).toEqual([]);
  });

  it('explains empty groups instead of hiding them', () => {
    const d = { ...base, serviceSession: null, liveUpdates: null };
    expect(group(d, 'Konum oturumu (iOS)').rows).toEqual([]);
    expect(group(d, 'Konum oturumu (iOS)').footer).toBeTruthy();
    expect(group(d, 'Canlı konum (sürüşte)').footer).toBe('GPS kapalıyken boş.');
  });

  it('never contains coordinates (only labels and Turkish values)', () => {
    const text = JSON.stringify(diagnosticsGroups(base));
    expect(text).not.toMatch(/-?\d+\.\d{3,}/);
  });
});
