/**
 * CarCrumb shared components, built on real SwiftUI views from `@expo/ui/swift-ui`.
 *
 * Screens compose these and never style SwiftUI views directly: all modifiers and
 * token lookups happen here. Every component is a SwiftUI view, so it must live
 * inside a <Screen> (which provides the SwiftUI Host).
 */
import {
  Button,
  ContentUnavailableView,
  Form,
  Host,
  Label,
  LabeledContent,
  NavigationStack,
  Section as SwiftSection,
  Text,
} from '@expo/ui/swift-ui';
import {
  buttonStyle,
  controlSize,
  font,
  foregroundStyle,
  monospacedDigit,
  navigationTitle,
  tint,
  type ViewModifier,
} from '@expo/ui/swift-ui/modifiers';
import type { ReactNode } from 'react';
import { StyleSheet } from 'react-native';

import { color, icon, type IconName, type StatusTone, type TypeRole, type as typeScale } from './tokens';

type TextTone = keyof typeof color.text;

/** Root of every screen: SwiftUI host, navigation bar with a large title, grouped form. */
export function Screen({ title, children }: { title: string; children: ReactNode }) {
  return (
    <Host style={styles.fill}>
      <NavigationStack>
        <Form modifiers={[navigationTitle(title), tint(color.accent)]}>{children}</Form>
      </NavigationStack>
    </Host>
  );
}

/** A titled group of rows (inset grouped list section). */
export function Group({ title, footer, children }: { title?: string; footer?: string; children: ReactNode }) {
  return (
    <SwiftSection title={title} footer={footer ? <Txt role="caption" tone="secondary">{footer}</Txt> : undefined}>
      {children}
    </SwiftSection>
  );
}

/** Text in one of the typography roles. Scales with Dynamic Type. */
export function Txt({ role = 'body', tone = 'primary', children }: { role?: TypeRole; tone?: TextTone; children: ReactNode }) {
  const t = typeScale[role];
  const modifiers: ViewModifier[] = [
    font({ textStyle: t.textStyle, weight: 'weight' in t ? t.weight : undefined }),
    foregroundStyle(color.text[tone]),
  ];
  if ('monospacedDigits' in t && t.monospacedDigits) modifiers.push(monospacedDigit());
  return <Text modifiers={modifiers}>{children}</Text>;
}

/** Icon + text in a status colour. Colour is never the only signal: the title carries the meaning. */
export function StatusLabel({ title, iconName, tone }: { title: string; iconName: IconName; tone: StatusTone }) {
  return (
    <Label
      title={title}
      systemImage={icon[iconName]}
      modifiers={[font({ textStyle: typeScale.heading.textStyle }), foregroundStyle(color.status[tone])]}
    />
  );
}

/** A label on the left, a value on the right (Settings-style row). */
export function InfoRow({ label, value }: { label: string; value: string }) {
  return (
    <LabeledContent label={label}>
      <Txt tone="secondary">{value}</Txt>
    </LabeledContent>
  );
}

/** The one main action of a screen. */
export function PrimaryButton({ label, iconName, onPress }: { label: string; iconName?: IconName; onPress: () => void }) {
  return (
    <Button
      label={label}
      systemImage={iconName ? icon[iconName] : undefined}
      onPress={onPress}
      modifiers={[buttonStyle('borderedProminent'), controlSize('large'), tint(color.accent)]}
    />
  );
}

/** A secondary action next to a primary one. */
export function SecondaryButton({ label, iconName, onPress }: { label: string; iconName?: IconName; onPress: () => void }) {
  return (
    <Button
      label={label}
      systemImage={iconName ? icon[iconName] : undefined}
      onPress={onPress}
      modifiers={[buttonStyle('bordered'), controlSize('large'), tint(color.accent)]}
    />
  );
}

/** Empty / unavailable content (no trips yet, location off, …). */
export function EmptyState({
  title,
  iconName,
  description,
  actions,
}: {
  title: string;
  iconName: IconName;
  description?: string;
  actions?: ReactNode;
}) {
  return <ContentUnavailableView title={title} systemImage={icon[iconName]} description={description} actions={actions} />;
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
});
