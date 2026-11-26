/**
 * Diagnostics → labelled rows for the field-test screen. Pure, so the mapping is tested.
 * Diagnostics contain no coordinates by design (see the bridge type).
 */
import type {
  Diagnostics,
  LiveUpdateDiagnostics,
  LocationAuthorization,
  MotionAuthorization,
  ServiceSessionDiagnostics,
} from '../../../modules/carcrumb-detection';
import { statePresentation } from '../detection/presentation';

export type DiagRow = { label: string; value: string; warn?: boolean };
export type DiagGroup = { title: string; footer?: string; rows: DiagRow[] };

const yesNo = (b: boolean) => (b ? 'Evet' : 'Hayır');

const locationAuth: Record<LocationAuthorization, string> = {
  notDetermined: 'Sorulmadı',
  restricted: 'Kısıtlı',
  denied: 'Reddedildi',
  whenInUse: 'Kullanırken',
  always: 'Her Zaman',
  unknown: 'Bilinmiyor',
  unavailable: 'Motor başlamadı',
};

const motionAuth: Record<MotionAuthorization, string> = {
  notDetermined: 'Sorulmadı',
  restricted: 'Kısıtlı',
  denied: 'Reddedildi',
  authorized: 'İzin verildi',
  unknown: 'Bilinmiyor',
};

const sessionLabels: Record<keyof ServiceSessionDiagnostics, string> = {
  authorizationDenied: 'Yetki reddedildi',
  authorizationDeniedGlobally: 'Konum Servisleri kapalı',
  authorizationRestricted: 'Yetki kısıtlı',
  insufficientlyInUse: 'Yetersiz kullanım (insufficientlyInUse)',
  serviceSessionRequired: 'Servis oturumu gerekli',
  fullAccuracyDenied: 'Tam doğruluk reddedildi',
  alwaysAuthorizationDenied: '“Her Zaman” reddedildi',
  authorizationRequestInProgress: 'İzin isteği sürüyor',
};

const liveLabels: Record<keyof LiveUpdateDiagnostics, string> = {
  stationary: 'Durağan',
  locationUnavailable: 'Konum alınamıyor',
  accuracyLimited: 'Doğruluk sınırlı',
  insufficientlyInUse: 'Yetersiz kullanım (insufficientlyInUse)',
  serviceSessionRequired: 'Servis oturumu gerekli',
};

/** Flags that mean "detection will not work well" — shown with a warning tone. */
const sessionWarnings = new Set<keyof ServiceSessionDiagnostics>([
  'authorizationDenied',
  'authorizationDeniedGlobally',
  'authorizationRestricted',
  'insufficientlyInUse',
  'fullAccuracyDenied',
  'alwaysAuthorizationDenied',
]);
const liveWarnings = new Set<keyof LiveUpdateDiagnostics>(['locationUnavailable', 'accuracyLimited', 'insufficientlyInUse']);

function flagRows<K extends string>(flags: Record<K, boolean>, labels: Record<K, string>, warnings: Set<K>): DiagRow[] {
  return (Object.keys(labels) as K[]).map((k) => ({
    label: labels[k],
    value: yesNo(flags[k]),
    warn: flags[k] && warnings.has(k),
  }));
}

export function diagnosticsGroups(d: Diagnostics): DiagGroup[] {
  const e = d.engine;
  const gpsPending = e.gpsRequested && !e.gpsActive;
  return [
    {
      title: 'Motor',
      footer: gpsPending ? 'GPS isteniyor ama çalışmıyor: yeniden başlatma bekleniyor ya da izin yok.' : undefined,
      rows: [
        { label: 'Çalışıyor', value: yesNo(e.started), warn: !e.started },
        { label: 'Durum', value: statePresentation[e.state].title },
        { label: 'GPS açık', value: yesNo(e.gpsActive) },
        { label: 'GPS isteniyor', value: yesNo(e.gpsRequested), warn: gpsPending },
        { label: 'Park geofence’i', value: yesNo(e.geofenceActive) },
        { label: 'Araç bağlantısı', value: yesNo(e.carLinkConnected) },
        { label: 'Sensör kaydı (debug)', value: yesNo(e.traceRecording) },
      ],
    },
    {
      title: 'Konum',
      rows: [
        {
          label: 'Yetki',
          value: locationAuth[d.location.authorization],
          warn: d.location.authorization !== 'always',
        },
        {
          label: 'Doğruluk',
          value: d.location.accuracy === undefined ? '—' : d.location.accuracy === 'full' ? 'Tam' : 'Yaklaşık',
          warn: d.location.accuracy === 'reduced',
        },
        { label: 'Konum Servisleri', value: d.location.servicesEnabled ? 'Açık' : 'Kapalı', warn: !d.location.servicesEnabled },
      ],
    },
    {
      title: 'Hareket',
      rows: [
        { label: 'Destekleniyor', value: yesNo(d.motion.available), warn: !d.motion.available },
        { label: 'Yetki', value: motionAuth[d.motion.authorization], warn: d.motion.authorization !== 'authorized' },
      ],
    },
    {
      title: 'Konum oturumu (iOS)',
      footer: d.serviceSession ? undefined : 'Henüz rapor yok (yetki belirlenince ilk raporla dolar).',
      rows: d.serviceSession ? flagRows(d.serviceSession, sessionLabels, sessionWarnings) : [],
    },
    {
      title: 'Canlı konum (sürüşte)',
      footer: d.liveUpdates ? undefined : 'GPS kapalıyken boş.',
      rows: d.liveUpdates ? flagRows(d.liveUpdates, liveLabels, liveWarnings) : [],
    },
  ];
}
