import { useCallback, useState } from 'react';
import { Linking } from 'react-native';

import CarCrumbDetection, { type ParkingRecord } from './modules/carcrumb-detection';
import { Screen } from './src/design/components';
import { HomeScreen } from './src/features/home/HomeScreen';
import { DIAGNOSTICS, DiagnosticsPage } from './src/features/diagnostics/DiagnosticsPage';
import { shareTrace, useDiagnostics } from './src/features/diagnostics/useDiagnostics';
import { useHomeData } from './src/features/home/useHomeData';
import { SETTINGS, SettingsPage, type DeleteStatus, type RouteRetention } from './src/features/settings/SettingsPage';
import { walkingDirectionsUrl } from './src/features/parking/directions';
import { markAsked } from './src/features/permissions/asked';
import { nextOnboardingStep } from './src/features/permissions/flow';
import { OnboardingScreen } from './src/features/permissions/OnboardingScreen';
import { DesignPreview, requestedPreview } from './src/features/preview/DesignPreview';
import { HISTORY, HistoryPage, TripPage, tripIdFromValue } from './src/features/trips/TripScreens';
import { useTripRoute, useTrips } from './src/features/trips/useTrips';

export default function App() {
  const preview = requestedPreview();
  if (preview) return <DesignPreview screen={preview} />;
  return <Root />;
}

/** A system dialog that never reports back must not leave the screen hanging. */
const DIALOG_TIMEOUT_MS = 30_000;

const loadRoute = (tripId: number) => CarCrumbDetection.getTripRoute(tripId);

function Root() {
  const { data, refresh } = useHomeData();
  const history = useTrips();
  const [path, setPath] = useState<string[]>([]);

  const request = useCallback(
    (fn: () => Promise<unknown>, after?: () => void) => () => {
      const timeout = new Promise((resolve) => setTimeout(resolve, DIALOG_TIMEOUT_MS));
      // Errors only mean the dialog could not be shown; the refresh shows the real status.
      void Promise.race([fn(), timeout])
        .catch(() => undefined)
        .then(() => after?.())
        .then(refresh);
    },
    [refresh],
  );

  const onDirections = useCallback((park: ParkingRecord) => {
    const url = walkingDirectionsUrl(park.latitude, park.longitude);
    if (url) void Linking.openURL(url).catch(() => undefined);
  }, []);

  if (!data.loaded) return <Screen title="CarCrumb">{null}</Screen>;

  const d = data.diagnostics;
  // Without diagnostics the engine is not running: show the (still usable) home screen.
  const step = d
    ? nextOnboardingStep({
        location: d.location.authorization,
        servicesEnabled: d.location.servicesEnabled,
        motion: d.motion.authorization,
        motionAvailable: d.motion.available,
        motionAsked: data.motionAsked,
        alwaysAsked: data.alwaysAsked,
      })
    : 'done';

  if (step === 'location') {
    return <OnboardingScreen step="location" onContinue={request(() => CarCrumbDetection.requestWhenInUseAuthorization())} />;
  }
  if (step === 'motion') {
    return (
      <OnboardingScreen
        step="motion"
        onContinue={request(() => CarCrumbDetection.requestMotionAuthorization(), () => markAsked('motion'))}
      />
    );
  }
  if (step === 'always') {
    return (
      <OnboardingScreen
        step="always"
        onContinue={request(() => CarCrumbDetection.requestAlwaysAuthorization(), () => markAsked('always'))}
      />
    );
  }

  const pushedTrips = path
    .map(tripIdFromValue)
    .flatMap((id) => history.trips.filter((t) => t.id === id));
  // A trip on the stack that no longer exists (history deleted, beyond the list limit) would
  // leave an empty page: drop such values from the path.
  const knownPath = path.filter((v) => tripIdFromValue(v) === null || history.trips.some((t) => t.id === tripIdFromValue(v)));
  if (history.loaded && knownPath.length !== path.length) setPath(knownPath);

  return (
    <HomeScreen
      data={data}
      actions={{
        onDirections,
        onOpenSettings: () => void Linking.openSettings().catch(() => undefined),
      }}
      navigation={{
        path,
        onPathChange: setPath,
        historyValue: HISTORY,
        diagnosticsValue: DIAGNOSTICS,
        settingsValue: SETTINGS,
        destinations: (
          <>
            <HistoryPage trips={history.trips} loaded={history.loaded} />
            {/* One destination per trip on the stack (built on demand, see NavigationDestination). */}
            {path.includes(DIAGNOSTICS) ? <PushedDiagnostics /> : null}
            {path.includes(SETTINGS) ? (
              <PushedSettings
                onHistoryDeleted={() => {
                  void refresh();
                  void history.refresh();
                }}
              />
            ) : null}
            {pushedTrips.map((trip) => (
              <PushedTrip key={trip.id} trip={trip} />
            ))}
          </>
        ),
      }}
    />
  );
}

function PushedTrip({ trip }: { trip: Parameters<typeof TripPage>[0]['trip'] }) {
  const route = useTripRoute(trip.id, loadRoute);
  return <TripPage trip={trip} route={route} />;
}

/** Mounted only while the diagnostics page is pushed, so its 5 s polling stops on back. */
function PushedDiagnostics() {
  const { diagnostics, traces, refresh } = useDiagnostics();
  return (
    <DiagnosticsPage
      diagnostics={diagnostics}
      traces={traces}
      onRefresh={refresh}
      onShareTrace={(name) => void shareTrace(name)}
    />
  );
}

/** Mounted only while the settings page is pushed. */
function PushedSettings({ onHistoryDeleted }: { onHistoryDeleted: () => void }) {
  const [retention, setRetention] = useState<RouteRetention | null>(() => CarCrumbDetection.getRouteRetention());
  const [deleteStatus, setDeleteStatus] = useState<DeleteStatus>('idle');
  return (
    <SettingsPage
      retention={retention}
      onRetentionChange={(value) => {
        setRetention(value);
        // Resolves after the purge; on failure show what the engine actually kept.
        void CarCrumbDetection.setRouteRetention(value).catch(() => setRetention(CarCrumbDetection.getRouteRetention()));
      }}
      deleteStatus={deleteStatus}
      onDeleteHistory={() => {
        setDeleteStatus('deleting');
        CarCrumbDetection.deleteAllHistory().then(
          () => {
            setDeleteStatus('done');
            onHistoryDeleted();
          },
          () => {
            setDeleteStatus('failed');
            onHistoryDeleted();
          },
        );
      }}
    />
  );
}
