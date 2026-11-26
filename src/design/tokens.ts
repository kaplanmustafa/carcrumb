/**
 * CarCrumb design tokens — the only place where raw style values live.
 *
 * Screens never write colours, font sizes or spacing literals; they use these tokens
 * through the components in `src/design/components.tsx`. A Jest test enforces this
 * (`src/design/__tests__/no-raw-styles.test.ts`).
 *
 * Principles (docs/DECISIONS.md, "Tasarım sistemi"):
 * - iOS-native first: system semantic colours and SwiftUI text styles, so light/dark
 *   mode, Increase Contrast and Dynamic Type come from the system for free.
 * - One brand accent; everything else is semantic.
 */
import { PlatformColor } from 'react-native';
import type { SFSymbol } from 'sf-symbols-typescript';

/**
 * iOS system colour (UIColor.system*). Adapts to dark mode and Increase Contrast.
 * Never use bare names like 'blue': @expo/ui reads those as CSS colours (#0000FF),
 * not the system palette (the first CI screenshots showed exactly that).
 */
const system = (name: 'systemIndigo' | 'systemGreen' | 'systemBlue' | 'systemOrange' | 'systemGray' | 'systemRed') =>
  PlatformColor(name);

/**
 * Colours for `@expo/ui/swift-ui` modifiers (`foregroundStyle`, `tint`): system colours
 * or SwiftUI hierarchical styles, all adapting to dark mode and accessibility settings.
 */
export const color = {
  /** Brand accent: buttons, selected states, the car pin. */
  accent: system('systemIndigo'),
  text: {
    primary: { type: 'hierarchical', style: 'primary' },
    secondary: { type: 'hierarchical', style: 'secondary' },
    tertiary: { type: 'hierarchical', style: 'tertiary' },
  },
  /** Meaning-carrying colours. Never used as the only signal: always paired with text/icon. */
  status: {
    /** Nothing happening: neutral, not a warning. */
    idle: { type: 'hierarchical', style: 'secondary' },
    parked: system('systemGreen'),
    driving: system('systemBlue'),
    pending: system('systemOrange'),
    uncertain: system('systemGray'),
    danger: system('systemRed'),
  },
} as const;

/** 4-pt spacing scale (points). */
export const space = {
  xxs: 2,
  xs: 4,
  s: 8,
  m: 12,
  l: 16,
  xl: 24,
  xxl: 32,
} as const;

/** Corner radii (points). SwiftUI draws them as continuous corners. */
export const radius = {
  s: 8,
  m: 12,
  l: 20,
} as const;

/**
 * Typography roles mapped to SwiftUI text styles. Every role scales with Dynamic Type;
 * there are deliberately no fixed point sizes.
 */
export const typography = {
  display: { textStyle: 'largeTitle', weight: 'bold' },
  title: { textStyle: 'title2', weight: 'semibold' },
  heading: { textStyle: 'headline' },
  body: { textStyle: 'body' },
  secondary: { textStyle: 'subheadline' },
  caption: { textStyle: 'footnote' },
  /** Numbers that update in place (distance, duration): monospaced digits. */
  metric: { textStyle: 'title3', weight: 'semibold', monospacedDigits: true },
} as const;

export type TypeRole = keyof typeof typography;
export type StatusTone = keyof typeof color.status;

/** SF Symbols used for domain concepts, so the same idea always has the same icon. */
export const icon = {
  car: 'car.fill',
  parked: 'parkingsign.circle.fill',
  driving: 'car.fill',
  walking: 'figure.walk',
  pending: 'hourglass',
  idle: 'moon.zzz.fill',
  location: 'location.fill',
  locationOff: 'location.slash.fill',
  motion: 'figure.walk.motion',
  carLink: 'car.front.waves.left.and.right.and.up.fill',
  history: 'clock.arrow.circlepath',
  diagnostics: 'stethoscope',
  directions: 'arrow.triangle.turn.up.right.diamond.fill',
  warning: 'exclamationmark.triangle.fill',
  settings: 'gearshape.fill',
} as const satisfies Record<string, SFSymbol>;

export type IconName = keyof typeof icon;
