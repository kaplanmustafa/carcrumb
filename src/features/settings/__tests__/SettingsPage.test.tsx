/** SettingsPage logic (design components are stubs; see src/__testutils__/elementTree.ts). */
import { all, flatten, texts } from '../../../__testutils__/elementTree';
import { retentionOptions, SettingsPage } from '../SettingsPage';

jest.mock('../../../design/components', () =>
  require('../../../__testutils__/elementTree').stubComponents(['ChoiceRow', 'Destination', 'DestructiveButton', 'Section', 'Txt']),
);

function render(over: Partial<Parameters<typeof SettingsPage>[0]> = {}) {
  const props = {
    retention: 'twelveMonths' as const,
    onRetentionChange: jest.fn(),
    deleteStatus: 'idle' as const,
    onDeleteHistory: jest.fn(),
    ...over,
  };
  const els = flatten(SettingsPage(props));
  return { props, els, sections: all(els, 'Section') };
}

describe('SettingsPage', () => {
  it('offers exactly 3 ay / 12 ay / Süresiz, 12 ay selected by default', () => {
    expect(retentionOptions.map((o) => o.label)).toEqual(['3 ay', '12 ay', 'Süresiz']);
    const choice = all(render().els, 'ChoiceRow')[0];
    expect(choice.props.value).toBe('twelveMonths');
  });

  it('passes the chosen retention up', () => {
    const { els, props } = render();
    (all(els, 'ChoiceRow')[0].props.onChange as (v: string) => void)('threeMonths');
    expect(props.onRetentionChange).toHaveBeenCalledWith('threeMonths');
  });

  it('shows a loading text until the retention is read', () => {
    const { els } = render({ retention: null });
    expect(all(els, 'ChoiceRow')).toHaveLength(0);
    expect(texts(els)).toContain('Yükleniyor…');
  });

  it('deleting history always asks for confirmation and says it cannot be undone', () => {
    const { els, props } = render();
    const button = all(els, 'DestructiveButton')[0];
    expect(button.props.confirmMessage).toMatch(/geri alınamaz/);
    (button.props.onConfirm as () => void)();
    expect(props.onDeleteHistory).toHaveBeenCalledTimes(1);
  });

  it('reports the delete result in the section footer', () => {
    const footer = (s: ReturnType<typeof render>) => s.sections.find((x) => x.props.title === 'Veriler')!.props.footer;
    expect(footer(render({ deleteStatus: 'done' }))).toBe('Geçmiş silindi.');
    expect(footer(render({ deleteStatus: 'failed' }))).toMatch(/kilidi açıkken/);
  });
});
