/**
 * CarCrumb shared components, built on real SwiftUI views from `@expo/ui/swift-ui`.
 *
 * Screens compose these and never style SwiftUI views directly: all modifiers and
 * token lookups happen here. Every component except `Screen`/`PermissionScreen` is a
 * SwiftUI view, so it must live inside one of those (they provide the SwiftUI Host).
 */
import {
  Button,
  ContentUnavailableView,
  Form,
  Host,
  Image,
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

import { color, icon, typography, type IconName, type StatusTone, type TypeRole } from './tokens';

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

/**
 * Permission explanation screen (App Store 5.1.1(iv), CLAUDE.md): one explanation and
 * exactly one button, "Devam", that goes straight to the system prompt. There is no
 * second action and no way to pass one; declining happens in the system dialog.
 */
export function PermissionScreen({
  title,
  explanation,
  iconName,
  onContinue,
}: {
  title: string;
  explanation: string;
  iconName: IconName;
  onContinue: () => void;
}) {
  return (
    <Host style={styles.fill}>
      <ContentUnavailableView
        title={title}
        systemImage={icon[iconName]}
        description={explanation}
        actions={<PrimaryButton label="Devam" onPress={onContinue} />}
      />
    </Host>
  );
}

/** A titled group of rows (inset grouped list section). */
export function Section({ title, footer, children }: { title?: string; footer?: string; children: ReactNode }) {
  return (
    <SwiftSection
      title={title}
      footer={
        footer ? (
          <Txt role="caption" tone="secondary">
            {footer}
          </Txt>
        ) : undefined
      }>
      {children}
    </SwiftSection>
  );
}

/** Text in one of the typography roles. Scales with Dynamic Type. */
export function Txt({ role = 'body', tone = 'primary', children }: { role?: TypeRole; tone?: TextTone; children: ReactNode }) {
  const t = typography[role];
  const modifiers: ViewModifier[] = [
    font({ textStyle: t.textStyle, weight: 'weight' in t ? t.weight : undefined }),
    foregroundStyle(color.text[tone]),
  ];
  if ('monospacedDigits' in t && t.monospacedDigits) modifiers.push(monospacedDigit());
  return <Text modifiers={modifiers}>{children}</Text>;
}

/**
 * Status icon + title. Only the icon is tinted with the status colour; the title stays in
 * the primary text colour so it keeps full contrast (system green/orange on white is
 * below 3:1). Colour is never the only signal: the title carries the meaning.
 */
export function StatusLabel({ title, iconName, tone }: { title: string; iconName: IconName; tone: StatusTone }) {
  return (
    <Label
      title={title}
      icon={
        // The icon is its own hosted view, so it does not inherit the Label's font:
        // give it the same text style or it stays small at large Dynamic Type sizes.
        <Image
          systemName={icon[iconName]}
          modifiers={[font({ textStyle: typography.heading.textStyle }), foregroundStyle(color.status[tone])]}
        />
      }
      modifiers={[font({ textStyle: typography.heading.textStyle }), foregroundStyle(color.text.primary)]}
    />
  );
}

/**
 * A moment shown relative to now ("12 dk", "2 sa") and kept current by SwiftUI as time
 * passes. Localised by the system (the app's development region is Turkish).
 */
export function RelativeTime({ date, tone = 'secondary' }: { date: Date; tone?: TextTone }) {
  return (
    <Text
      date={date}
      dateStyle="relative"
      modifiers={[font({ textStyle: typography.body.textStyle }), foregroundStyle(color.text[tone]), monospacedDigit()]}
    />
  );
}

/** A label on the left, a relative time on the right ("Park edildi · 12 dk"). */
export function TimeRow({ label, date }: { label: string; date: Date }) {
  return (
    <LabeledContent label={label}>
      <RelativeTime date={date} />
    </LabeledContent>
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

/** A secondary action next to a primary one. Not for permission screens (see PermissionScreen). */
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
