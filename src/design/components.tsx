/**
 * CarCrumb shared components, built on real SwiftUI views from `@expo/ui/swift-ui`.
 *
 * Screens compose these and never style SwiftUI views directly: all modifiers and
 * token lookups happen here. Every component except `Screen`/`PermissionScreen` is a
 * SwiftUI view, so it must live inside one of those (they provide the SwiftUI Host).
 */
import {
  Button,
  ConfirmationDialog,
  ContentUnavailableView,
  Form,
  Host,
  Image,
  Label,
  LabeledContent,
  NavigationDestination,
  NavigationLink,
  NavigationStack,
  Picker,
  RNHostView,
  Section as SwiftSection,
  Text,
  VStack,
} from '@expo/ui/swift-ui';
import {
  buttonStyle,
  controlSize,
  font,
  foregroundStyle,
  monospacedDigit,
  navigationTitle,
  pickerStyle,
  tag,
  tint,
  type ViewModifier,
} from '@expo/ui/swift-ui/modifiers';
import { useState, type ReactElement, type ReactNode } from 'react';
import { StyleSheet, View } from 'react-native';

import { color, icon, radius, size, space, typography, type IconName, type StatusTone, type TypeRole } from './tokens';

type TextTone = keyof typeof color.text;

/** A grouped form with a large navigation title: the body of a screen or a pushed page. */
function Page({ title, children }: { title: string; children: ReactNode }) {
  return <Form modifiers={[navigationTitle(title), tint(color.accent)]}>{children}</Form>;
}

/**
 * Root of every screen: SwiftUI host, navigation bar with a large title, grouped form.
 * For drill-down, pass `destinations` (<Destination> elements) and a controlled `path`;
 * <NavRow value="…"> anywhere inside pushes the destination with that value.
 */
export function Screen({
  title,
  children,
  destinations,
  path,
  onPathChange,
}: {
  title: string;
  children: ReactNode;
  destinations?: ReactNode;
  path?: string[];
  onPathChange?: (path: string[]) => void;
}) {
  return (
    <Host style={styles.fill}>
      <NavigationStack path={path} onPathChange={onPathChange}>
        <Page title={title}>{children}</Page>
        {destinations}
      </NavigationStack>
    </Host>
  );
}

/** A page pushed onto a <Screen>'s navigation stack when a <NavRow> with the same value is tapped. */
export function Destination({ value, title, children }: { value: string; title: string; children: ReactNode }) {
  return (
    <NavigationDestination value={value}>
      <Page title={title}>{children}</Page>
    </NavigationDestination>
  );
}

/** A row with a disclosure chevron that pushes the <Destination> with the same value. */
export function NavRow({ value, children }: { value: string; children: ReactNode }) {
  return <NavigationLink value={value}>{children}</NavigationLink>;
}

/** Icon + title row for navigation lists (e.g. "Yolculuk geçmişi"). Primary text colour, accent icon. */
export function NavLabel({ title, iconName }: { title: string; iconName: IconName }) {
  return (
    <Label
      title={title}
      icon={<Image systemName={icon[iconName]} modifiers={[foregroundStyle(color.accent)]} />}
      modifiers={[foregroundStyle(color.text.primary)]}
    />
  );
}

/**
 * Two-line list row: a title and a secondary detail line (e.g. a trip: "26 Kas 14:32" /
 * "23 dk · 12,4 km"). Optional trailing note in the secondary colour (e.g. "Belirsiz").
 */
export function DetailRow({ title, detail, note }: { title: string; detail: string; note?: string }) {
  return (
    <LabeledContent
      label={
        <VStack alignment="leading" spacing={space.xxs}>
          <Txt>{title}</Txt>
          <Txt role="caption" tone="secondary">
            {detail}
          </Txt>
        </VStack>
      }>
      {note ? (
        <Txt role="caption" tone="secondary">
          {note}
        </Txt>
      ) : null}
    </LabeledContent>
  );
}

/**
 * Embeds a React Native view (e.g. the map) in a form row at a token height. The row takes
 * its height from the hosted view (`matchContents.vertical`) and its width from the form.
 */
export function EmbeddedView({ height, children }: { height: keyof typeof size; children: ReactElement }) {
  return (
    <RNHostView matchContents={{ vertical: true }}>
      <View style={[styles.embedded, { height: size[height] }]}>{children}</View>
    </RNHostView>
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

/**
 * Settings-style row whose value can be flagged: a flagged value gets a warning icon in the
 * pending colour, so the problem is visible without relying on colour alone.
 */
export function FlagRow({ label, value, warn = false }: { label: string; value: string; warn?: boolean }) {
  return (
    <LabeledContent label={label}>
      {warn ? (
        <Label
          title={value}
          icon={<Image systemName={icon.warning} modifiers={[foregroundStyle(color.status.pending)]} />}
          modifiers={[foregroundStyle(color.text.secondary)]}
        />
      ) : (
        <Txt tone="secondary">{value}</Txt>
      )}
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

/** One-of-many setting shown as a menu row (e.g. route retention: 3 ay / 12 ay / Süresiz). */
export function ChoiceRow<T extends string>({
  label,
  options,
  value,
  onChange,
}: {
  label: string;
  options: readonly { value: T; label: string }[];
  value: T;
  onChange: (value: T) => void;
}) {
  return (
    <Picker<string> label={label} selection={value} onSelectionChange={(v) => onChange(v as T)} modifiers={[pickerStyle('menu')]}>
      {options.map((o) => (
        <Text key={o.value} modifiers={[tag(o.value)]}>
          {o.label}
        </Text>
      ))}
    </Picker>
  );
}

/**
 * A destructive action that always asks first (system confirmation dialog with a red
 * confirm button and Cancel). Used for irreversible actions such as deleting history.
 */
export function DestructiveButton({
  label,
  confirmTitle,
  confirmMessage,
  confirmLabel,
  onConfirm,
}: {
  label: string;
  confirmTitle: string;
  confirmMessage: string;
  confirmLabel: string;
  onConfirm: () => void;
}) {
  const [presented, setPresented] = useState(false);
  return (
    <ConfirmationDialog title={confirmTitle} isPresented={presented} onIsPresentedChange={setPresented} titleVisibility="visible">
      <ConfirmationDialog.Trigger>
        <Button label={label} role="destructive" onPress={() => setPresented(true)} />
      </ConfirmationDialog.Trigger>
      <ConfirmationDialog.Actions>
        <Button
          label={confirmLabel}
          role="destructive"
          onPress={() => {
            setPresented(false);
            onConfirm();
          }}
        />
        <Button label="Vazgeç" role="cancel" onPress={() => setPresented(false)} />
      </ConfirmationDialog.Actions>
      <ConfirmationDialog.Message>
        <Text>{confirmMessage}</Text>
      </ConfirmationDialog.Message>
    </ConfirmationDialog>
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
  // Hosted RN views keep the form row's corner shape.
  embedded: { borderRadius: radius.m, overflow: 'hidden' },
});
