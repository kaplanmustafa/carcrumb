/**
 * Design preview screens for CI screenshots (.github/workflows/screenshots.yml).
 *
 * Active only when the bundle is built with EXPO_PUBLIC_PREVIEW=1 (the module is always bundled;
 * in normal builds the branch is dead and the launch argument is never read). The screen to show
 * is picked with a simulator launch argument (`-previewScreen <name>`), which iOS puts into
 * NSUserDefaults and React Native's Settings API exposes. Normal builds never read the launch
 * argument and always show the real app.
 */
import { Settings } from 'react-native';

import type { Diagnostics, LocationAuthorization, ParkingRecord, TripRecord } from '../../../modules/carcrumb-detection';
import { InfoRow, PrimaryButton, Screen, SecondaryButton, Section, StatusLabel, Txt } from '../../design/components';
import { statePresentation } from '../detection/presentation';
import { HomeScreen } from '../home/HomeScreen';
import type { HomeData } from '../home/useHomeData';
import { OnboardingScreen } from '../permissions/OnboardingScreen';

export type PreviewScreen =
  | 'states'
  | 'components'
  | 'permission'
  | 'motion'
  | 'always'
  | 'home-parked'
  | 'home-low'
  | 'home-off';

const SCREENS: readonly PreviewScreen[] = [
  'states',
  'components',
  'permission',
  'motion',
  'always',
  'home-parked',
  'home-low',
  'home-off',
];

/** The preview screen requested for this launch, or null for the real app. */
export function requestedPreview(): PreviewScreen | null {
  if (process.env.EXPO_PUBLIC_PREVIEW !== '1') return null;
  const value = Settings.get('previewScreen');
  return SCREENS.includes(value) ? (value as PreviewScreen) : null;
}

const noop = () => {};

// Synthetic data only. Coordinates stay in the synthetic box (41.0 / -40.0, open Atlantic):
// screenshots end up in CI artifacts.
const minutesAgo = (m: number) => Date.now() - m * 60_000;

function park(id: number, confidence: ParkingRecord['confidence'], parkedAt: number): ParkingRecord {
  return {
    id,
    tripId: id,
    latitude: 41.0 + id / 10_000,
    longitude: -40.0,
    accuracy: confidence === 'high' ? 5 : 60,
    confidence,
    parkedAt,
  };
}

function diagnostics(authorization: LocationAuthorization): Diagnostics {
  return {
    engine: {
      started: true,
      state: 'PARKED',
      gpsActive: false,
      gpsRequested: false,
      geofenceActive: true,
      carLinkConnected: false,
      traceRecording: false,
    },
    location: { authorization, servicesEnabled: true },
    serviceSession: null,
    liveUpdates: null,
    motion: { available: true, authorization: 'authorized' },
  };
}

type HomePreview = 'home-parked' | 'home-low' | 'home-off';

function homeData(kind: HomePreview): HomeData {
  if (kind === 'home-off') {
    return {
      loaded: true,
      state: 'IDLE',
      diagnostics: diagnostics('denied'),
      parking: null,
      recentParkings: [],
      trips: [],
      storeUnavailable: false,
      motionAsked: true,
      alwaysAsked: false,
    };
  }
  const trip: TripRecord = { id: 3, startedAt: minutesAgo(40), endedAt: minutesAgo(12), status: 'confirmed', distanceMeters: null };
  const current = park(3, kind === 'home-low' ? 'low' : 'high', minutesAgo(12));
  const recent =
    kind === 'home-low' ? [current, park(2, 'high', minutesAgo(26 * 60)), park(1, 'high', minutesAgo(50 * 60))] : [current];
  return {
    loaded: true,
    state: 'PARKED',
    // home-low also shows the "Always declined → Settings" card.
    diagnostics: diagnostics(kind === 'home-low' ? 'whenInUse' : 'always'),
    parking: current,
    recentParkings: recent,
    trips: [trip],
    storeUnavailable: false,
    motionAsked: true,
    alwaysAsked: true,
  };
}

const previewActions = { onDirections: noop, onOpenSettings: noop };

export function DesignPreview({ screen }: { screen: PreviewScreen }) {
  if (screen === 'permission') return <OnboardingScreen step="location" onContinue={noop} />;
  if (screen === 'motion') return <OnboardingScreen step="motion" onContinue={noop} />;
  if (screen === 'always') return <OnboardingScreen step="always" onContinue={noop} />;
  if (screen === 'home-parked' || screen === 'home-low' || screen === 'home-off') {
    return <HomeScreen data={homeData(screen)} actions={previewActions} />;
  }

  if (screen === 'components') {
    return (
      <Screen title="Bileşenler">
        <Section title="Metin rolleri">
          <Txt role="title">Başlık</Txt>
          <Txt role="heading">Alt başlık</Txt>
          <Txt>Gövde metni, Dynamic Type ile büyür.</Txt>
          <Txt role="secondary" tone="secondary">
            İkincil metin
          </Txt>
          <Txt role="metric">12,4 km · 23 dk</Txt>
          <Txt role="caption" tone="tertiary">
            Dipnot
          </Txt>
        </Section>
        <Section title="Bilgi satırları" footer="Ayarlar tarzı satırlar.">
          <InfoRow label="Son park" value="14:32" />
          <InfoRow label="Güven" value="Yüksek" />
        </Section>
        <Section title="Butonlar">
          <PrimaryButton label="Yol tarifi al" iconName="directions" onPress={noop} />
          <SecondaryButton label="Geçmiş" iconName="history" onPress={noop} />
        </Section>
      </Screen>
    );
  }

  return (
    <Screen title="Durumlar">
      {Object.values(statePresentation).map((p) => (
        <Section key={p.title}>
          <StatusLabel title={p.title} iconName={p.iconName} tone={p.tone} />
          <Txt tone="secondary">{p.description}</Txt>
        </Section>
      ))}
    </Screen>
  );
}
