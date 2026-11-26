import { useCallback } from 'react';
import { Linking } from 'react-native';

import CarCrumbDetection, { type ParkingRecord } from './modules/carcrumb-detection';
import { Screen } from './src/design/components';
import { HomeScreen } from './src/features/home/HomeScreen';
import { useHomeData } from './src/features/home/useHomeData';
import { walkingDirectionsUrl } from './src/features/parking/directions';
import { nextOnboardingStep } from './src/features/permissions/flow';
import { OnboardingScreen } from './src/features/permissions/OnboardingScreen';
import { DesignPreview, requestedPreview } from './src/features/preview/DesignPreview';

export default function App() {
  const preview = requestedPreview();
  if (preview) return <DesignPreview screen={preview} />;
  return <Root />;
}

function Root() {
  const { data, refresh } = useHomeData();

  const request = useCallback(
    (fn: () => Promise<unknown>) => () => {
      // Errors only mean the prompt could not be shown; the refresh shows the real status.
      void fn()
        .catch(() => undefined)
        .then(refresh);
    },
    [refresh],
  );

  const onDirections = useCallback((park: ParkingRecord) => {
    const url = walkingDirectionsUrl(park.latitude, park.longitude);
    if (url) void Linking.openURL(url).catch(() => undefined);
  }, []);

  if (!data.loaded) return <Screen title="CarCrumb">{null}</Screen>;

  const diagnostics = data.diagnostics;
  const step = diagnostics ? nextOnboardingStep(diagnostics.location.authorization, diagnostics.motion.authorization) : 'done';

  if (step === 'location') {
    return <OnboardingScreen step="location" onContinue={request(() => CarCrumbDetection.requestWhenInUseAuthorization())} />;
  }
  if (step === 'motion') {
    return <OnboardingScreen step="motion" onContinue={request(() => CarCrumbDetection.requestMotionAuthorization())} />;
  }

  return (
    <HomeScreen
      data={data}
      actions={{
        onDirections,
        onUpgradeAlways: request(() => CarCrumbDetection.requestAlwaysAuthorization()),
        onOpenSettings: () => void Linking.openSettings().catch(() => undefined),
      }}
    />
  );
}
