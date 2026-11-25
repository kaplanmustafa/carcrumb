/**
 * Design-system guard: outside `src/design/`, UI code may not write raw style values
 * or style SwiftUI views directly. Use tokens and the shared components instead.
 */
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, sep } from 'node:path';

const ROOT = join(__dirname, '..', '..', '..');
const DESIGN_DIR = join(ROOT, 'src', 'design');

const RULES: { name: string; pattern: RegExp }[] = [
  { name: 'hex colour', pattern: /['"`]#[0-9a-fA-F]{3,8}['"`]/ },
  { name: 'rgb/hsl colour', pattern: /\b(rgba?|hsla?)\(/ },
  { name: 'font size/weight/family', pattern: /\bfont(Size|Weight|Family)\b/ },
  { name: 'SwiftUI modifiers import (use design components)', pattern: /@expo\/ui\/swift-ui\/modifiers/ },
  { name: 'StyleSheet (use design components)', pattern: /\bStyleSheet\b/ },
];

function uiFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) {
      if (name === '__tests__' || path === DESIGN_DIR) return [];
      return uiFiles(path);
    }
    return /\.(ts|tsx)$/.test(name) ? [path] : [];
  });
}

const files = [join(ROOT, 'App.tsx'), ...uiFiles(join(ROOT, 'src'))];

describe('no raw styles outside src/design', () => {
  it('scans at least the app entry and one feature file', () => {
    expect(files.length).toBeGreaterThanOrEqual(2);
  });

  it.each(files.map((f) => [relative(ROOT, f).split(sep).join('/'), f]))('%s', (_name, file) => {
    const lines = readFileSync(file, 'utf8').split(/\r?\n/);
    const violations = lines.flatMap((line, i) =>
      RULES.filter((r) => r.pattern.test(line)).map((r) => `line ${i + 1}: ${r.name}`),
    );
    expect(violations).toEqual([]);
  });
});
