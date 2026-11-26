/**
 * Test-only: inspect what a presentational screen returns without a React renderer.
 * Design components are mocked as named stubs (`stubComponents`); `flatten` walks the
 * returned element tree, expanding fragments and local (un-stubbed) function components.
 * Only for components without hooks. Not imported by app code. No jest globals.
 */
import { Fragment, isValidElement, type ReactElement, type ReactNode } from 'react';

export type El = ReactElement<Record<string, unknown> & { children?: ReactNode }>;
type Comp = ((props: unknown) => ReactNode) & { displayName?: string; stub?: true };

/** `{ Name: stub }` for each name; use as a jest.mock factory result. */
export function stubComponents(names: readonly string[]): Record<string, Comp> {
  return Object.fromEntries(names.map((name) => [name, Object.assign(() => null, { displayName: name, stub: true as const })]));
}

export function flatten(node: ReactNode): El[] {
  if (Array.isArray(node)) return node.flatMap(flatten);
  if (!isValidElement(node)) return [];
  const el = node as El;
  if (el.type === Fragment) return flatten(el.props.children);
  const type = el.type as Comp;
  if (typeof type === 'function' && !type.stub) return flatten(type(el.props));
  return [el, ...flatten(el.props.children)];
}

export const nameOf = (el: El): string | undefined => (el.type as Comp).displayName;

/** Elements of one stub, in tree order. */
export const all = (els: El[], name: string): El[] => els.filter((e) => nameOf(e) === name);

/** Text children of the `Txt` stubs. */
export const texts = (els: El[]): unknown[] => all(els, 'Txt').map((e) => e.props.children);
