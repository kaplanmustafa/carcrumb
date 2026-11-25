/**
 * Privacy guard: JS receives park coordinates (getLastParking, listRecentParkings), and in
 * React Native `console.*` reaches the system log even in release builds. One forgotten
 * `console.log(park)` would leak a raw coordinate (CLAUDE.md: "Ham koordinat loglanmaz").
 * So app code may not call `console` at all.
 */
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, sep } from 'node:path';

const ROOT = join(__dirname, '..', '..');
const SKIP_DIRS = new Set(['node_modules', 'fixtures', 'docs', 'assets', 'ios', 'android', 'dist', 'build', 'coverage', '__tests__']);
const CONSOLE = /\bconsole\s*\.\s*[a-zA-Z]+\s*\(/;
const COMMENT_LINE = /^\s*(\/\/|\/\*|\*)/;

function codeFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) {
      return name.startsWith('.') || SKIP_DIRS.has(name) ? [] : codeFiles(path);
    }
    return /\.(ts|tsx|js|jsx)$/.test(name) && !/\.d\.ts$/.test(name) && !/\.config\.[cm]?[jt]s$/.test(name) ? [path] : [];
  });
}

export function consoleCalls(text: string): number[] {
  return text
    .split(/\r?\n/)
    .flatMap((line, i) => (!COMMENT_LINE.test(line) && CONSOLE.test(line) ? [i + 1] : []));
}

const files = codeFiles(ROOT);
const rel = (f: string) => relative(ROOT, f).split(sep).join('/');

describe('no console in app code', () => {
  it('scans the app entry, screens and the native module bridge', () => {
    const names = files.map(rel);
    expect(names).toContain('App.tsx');
    expect(names.some((n) => n.startsWith('modules/carcrumb-detection/src/'))).toBe(true);
  });

  it.each(files.map((f) => [rel(f), f]))('%s', (_name, file) => {
    expect(consoleCalls(readFileSync(file, 'utf8'))).toEqual([]);
  });

  it('rule flags console calls and ignores comments', () => {
    expect(consoleCalls(`console.log(park);`)).toEqual([1]);
    expect(consoleCalls(`  console . warn ('x')`)).toEqual([1]);
    expect(consoleCalls(`// console.log is forbidden`)).toEqual([]);
    expect(consoleCalls(`const consoleLike = 1;`)).toEqual([]);
  });
});
