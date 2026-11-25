/**
 * Design preview screens for CI screenshots (.github/workflows/screenshots.yml).
 *
 * Compiled in only when the bundle is built with EXPO_PUBLIC_PREVIEW=1. The screen to show
 * is picked with a simulator launch argument (`-previewScreen states|components|permission`),
 * which iOS puts into NSUserDefaults and React Native's Settings API exposes. Normal builds
 * never read the launch argument and always show the real app.
 */
import { Settings } from 'react-native';

import {
  InfoRow,
  PermissionScreen,
  PrimaryButton,
  Screen,
  SecondaryButton,
  Section,
  StatusLabel,
  Txt,
} from '../../design/components';
import { statePresentation } from '../detection/presentation';

export type PreviewScreen = 'states' | 'components' | 'permission';

const SCREENS: readonly PreviewScreen[] = ['states', 'components', 'permission'];

/** The preview screen requested for this launch, or null for the real app. */
export function requestedPreview(): PreviewScreen | null {
  if (process.env.EXPO_PUBLIC_PREVIEW !== '1') return null;
  const value = Settings.get('previewScreen');
  return SCREENS.includes(value) ? (value as PreviewScreen) : null;
}

const noop = () => {};

export function DesignPreview({ screen }: { screen: PreviewScreen }) {
  if (screen === 'permission') {
    return (
      <PermissionScreen
        title="Konum izni"
        explanation="CarCrumb, aracını park ettiğin yeri ve yolculuklarını kaydetmek için konumunu kullanır. Veriler yalnızca bu cihazda kalır."
        iconName="location"
        onContinue={noop}
      />
    );
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
