import { useEffect, useState } from 'react';

import CarCrumbDetection, { type DetectionStateName } from './modules/carcrumb-detection';
import { Group, Screen, StatusLabel, Txt } from './src/design/components';
import { statePresentation } from './src/features/detection/presentation';

export default function App() {
  const [state, setState] = useState<DetectionStateName>(() => CarCrumbDetection.getState());

  useEffect(() => {
    const sub = CarCrumbDetection.addListener('onStateChange', (e) => setState(e.state));
    return () => sub.remove();
  }, []);

  const p = statePresentation[state];

  return (
    <Screen title="CarCrumb">
      <Group title="Durum" footer="Konum verilerin yalnızca bu cihazda kalır.">
        <StatusLabel title={p.title} iconName={p.iconName} tone={p.tone} />
        <Txt tone="secondary">{p.description}</Txt>
      </Group>
    </Screen>
  );
}
