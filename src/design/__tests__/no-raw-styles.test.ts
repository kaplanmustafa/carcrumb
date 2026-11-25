/**
 * Design-system guard: outside `src/design/`, UI code may not write raw style values
 * or style SwiftUI views directly. Use tokens and the shared components instead.
 */
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, sep } from 'node:path';

const ROOT = join(__dirname, '..', '..', '..');
const DESIGN_DIR = join(ROOT, 'src', 'design');

/** Style props whose value is a colour (React Native + @expo/ui view props). */
const COLOUR_PROPS =
  'color|backgroundColor|borderColor|border(?:Top|Bottom|Left|Right|Start|End)Color|tintColor|shadowColor|' +
  'textShadowColor|textDecorationColor|overlayColor|placeholderTextColor|selectionColor|cursorColor|thumbColor|trackColor';

/** Size props that must come from `space` / `radius` tokens, not number literals. */
const SIZE_PROPS =
  '(?:padding|margin)(?:Top|Bottom|Left|Right|Horizontal|Vertical|Start|End)?|gap|rowGap|columnGap|' +
  'border(?:Top|Bottom)?(?:Left|Right|Start|End)?Radius|border(?:Top|Bottom|Left|Right|Start|End)?Width|lineHeight|letterSpacing';

const RULES: { name: string; pattern: RegExp }[] = [
  { name: 'hex colour', pattern: /['"`]#[0-9a-fA-F]{3,8}['"`]/ },
  { name: 'rgb/hsl colour', pattern: /\b(rgba?|hsla?)\(/ },
  { name: 'font size/weight/family', pattern: /\bfont(Size|Weight|Family)\b/ },
  { name: 'SwiftUI modifiers import (use design components)', pattern: /@expo\/ui\/swift-ui\/modifiers/ },
  { name: 'StyleSheet (use design components)', pattern: /\bStyleSheet\b/ },
  // Screens use design components only; raw SwiftUI views would bypass tokens through their own props.
  { name: '@expo/ui import (use design components)', pattern: /['"]@expo\/ui(\/[^'"]*)?['"]/ },
  // `color: 'red'`, `color="red"`, `color={'red'}` (named colours are raw values too).
  { name: 'colour literal on a colour prop', pattern: new RegExp(`\\b(${COLOUR_PROPS})\\s*[:=]\\s*\\{?\\s*['"\`]`) },
  { name: 'platform colour (use color tokens)', pattern: /\b(PlatformColor|DynamicColorIOS)\s*\(/ },
  // `padding: 16`, `borderRadius: 12`, `gap={8}`; `padding: space.l` is fine.
  { name: 'number literal on a size prop (use space/radius)', pattern: new RegExp(`\\b(${SIZE_PROPS})\\s*[:=]\\s*\\{?\\s*-?\\.?\\d`) },
  // Design components take no `modifiers`; passing them means styling a SwiftUI view directly.
  { name: 'SwiftUI modifiers prop (use design components)', pattern: /\bmodifiers\s*=\s*\{/ },
];

/** Comment-only lines may mention forbidden names (docs); code lines may not. */
const COMMENT_LINE = /^\s*(\/\/|\/\*|\*)/;

function violationsIn(text: string): string[] {
  return text
    .split(/\r?\n/)
    .flatMap((line, i) =>
      COMMENT_LINE.test(line) ? [] : RULES.filter((r) => r.pattern.test(line)).map((r) => `line ${i + 1}: ${r.name}`),
    );
}

/** Not UI code (or generated / vendored). Everything else under the repo root is scanned, so a new
 * top-level directory (app/, screens/, components/ …) is covered without touching this test. */
const SKIP_DIRS = new Set([
  'node_modules',
  'modules', // native module + its TS bridge, no UI
  'fixtures',
  'docs',
  'assets',
  'ios',
  'android',
  'dist',
  'build',
  'coverage',
  '__tests__',
]);
/** Root config files may legitimately carry colours (e.g. splash backgroundColor in app.config.ts). */
const CONFIG_FILE = /(^|[./])config\.[cm]?[jt]s$/;

function uiFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) {
      if (name.startsWith('.') || SKIP_DIRS.has(name) || path === DESIGN_DIR) return [];
      return uiFiles(path);
    }
    if (dir === ROOT && CONFIG_FILE.test(name)) return [];
    return /\.(ts|tsx|js|jsx)$/.test(name) && !/\.d\.ts$/.test(name) ? [path] : [];
  });
}

const files = uiFiles(ROOT);
const rel = (f: string) => relative(ROOT, f).split(sep).join('/');

describe('no raw styles outside src/design', () => {
  it('scans the app entry and feature code, never src/design', () => {
    const names = files.map(rel);
    expect(names).toContain('App.tsx');
    expect(names).toContain('src/features/detection/presentation.ts');
    expect(names.filter((n) => n.startsWith('src/design/'))).toEqual([]);
    expect(names.filter((n) => n.includes('node_modules'))).toEqual([]);
  });

  it.each(files.map((f) => [rel(f), f]))('%s', (_name, file) => {
    expect(violationsIn(readFileSync(file, 'utf8'))).toEqual([]);
  });
});

describe('raw-style rules themselves', () => {
  it.each([
    [`<View style={{ color: 'red' }} />`],
    [`<View style={{ backgroundColor: 'white' }} />`],
    [`const s = { borderColor: "#ccc" };`],
    [`<Text color="indigo">x</Text>`],
    [`<Icon tintColor={'orange'} />`],
    [`const s = { padding: 16 };`],
    [`const s = { marginHorizontal: 8 };`],
    [`const s = { paddingTop: .5 };`],
    [`const s = { borderRadius: 12 };`],
    [`const s = { borderTopLeftRadius: 4 };`],
    [`const s = { gap: 4 };`],
    [`<Stack gap={8} />`],
    [`const s = { lineHeight: 22 };`],
    [`const c = PlatformColor('systemRed');`],
    [`const c = DynamicColorIOS({ light: a, dark: b });`],
    [`const s = { fontSize: 17 };`],
    [`const c = '#fff';`],
    [`const c = 'rgba(0, 0, 0, 0.5)';`],
    [`import { padding } from '@expo/ui/swift-ui/modifiers';`],
    [`const styles = StyleSheet.create({});`],
    [`<Text modifiers={[bold()]}>x</Text>`],
    [`import { Host, Label } from '@expo/ui/swift-ui';`],
    [`import { Switch } from '@expo/ui';`],
  ])('flags %s', (code) => {
    expect(violationsIn(code)).not.toEqual([]);
  });

  it.each([
    [`<StatusLabel title={p.title} iconName={p.iconName} tone={p.tone} />`],
    [`<Txt tone="secondary">{p.description}</Txt>`],
    [`tone: 'pending',`],
    [`iconName: 'parked',`],
    [`const s = { padding: space.l, borderRadius: radius.m };`],
    [`const scheme = { colorScheme: 'dark' };`],
    [`const anchor = '#about';`],
    [`const total = trips.length + 16;`],
    [`// StyleSheet is only allowed in src/design`],
    [` * Use tokens instead of fontSize literals.`],
  ])('does not flag %s', (code) => {
    expect(violationsIn(code)).toEqual([]);
  });
});
