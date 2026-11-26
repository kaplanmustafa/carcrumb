import { useCallback } from 'react';
import { Linking } from 'react-native';

import CarCrumbDetection, { type ParkingRecord } from './modules/carcrumb-detection';
import { Screen } from './src/design/components';
import { HomeScreen } from './src/features/home/HomeScreen';
import { useHomeData } from './src/features/home/useHomeData';
import { walkingDirectionsUrl } from './src/features/parking/directions';
import { markAsked } from './src/features/permissions/asked';
import { nextOnboardingStep } from './src/features/permissions/flow';
import { OnboardingScreen } from './src/features/permissions/OnboardingScreen';
import { DesignPreview, requestedPreview } from './src/features/preview/DesignPreview';

export default function App() {
  const preview = requestedPreview();
  if (preview) return <DesignPreview screen={preview} />;
  return <Root />;
}

/** A system dialog that never reports back must not leave the screen hanging. */
const DIALOG_TIMEOUT_MS = 30_000;

function Root() {
  const { data, refresh } = useHomeData();

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

  return (
    <HomeScreen
      data={data}
      actions={{
        onDirections,
        onOpenSettings: () => void Linking.openSettings().catch(() => undefined),
      }}
    />
  );
}
