/**
 * DiagnosticsPage section logic (no renderer: design components are stubs, the element tree
 * is inspected, see src/__testutils__/elementTree.ts).
 */
import type { Diagnostics } from '../../../../modules/carcrumb-detection';
import { all, flatten, texts } from '../../../__testutils__/elementTree';
import { DiagnosticsPage } from '../DiagnosticsPage';
import { diagnosticsGroups } from '../rows';

jest.mock('../../../design/components', () =>
  require('../../../__testutils__/elementTree').stubComponents(['Destination', 'FlagRow', 'SecondaryButton', 'Section', 'Txt']),
);

const diagnostics: Diagnostics = {
  engine: {
    started: true,
    state: 'IDLE',
    gpsActive: false,
    gpsRequested: false,
    geofenceActive: true,
    carLinkConnected: false,
    traceRecording: true,
  },
  location: { authorization: 'always', accuracy: 'full', servicesEnabled: true },
  serviceSession: null,
  liveUpdates: null,
  motion: { available: true, authorization: 'authorized' },
};

const TRACES_TITLE = 'Sensör kayıtları (debug)';

function render(over: Partial<Parameters<typeof DiagnosticsPage>[0]> = {}) {
  const props = { diagnostics, traces: [] as string[], onRefresh: jest.fn(), onShareTrace: jest.fn(), ...over };
  const els = flatten(DiagnosticsPage(props));
  const sections = all(els, 'Section');
  return { props, els, sections, titles: sections.map((s) => s.props.title) };
}

describe('DiagnosticsPage', () => {
  it('no traces (release build) → no trace section', () => {
    const r = render();
    expect(r.titles).not.toContain(TRACES_TITLE);
    expect(all(r.els, 'SecondaryButton').map((b) => b.props.label)).toEqual(['Şimdi yenile']);
  });

  it('one section per diagnostics group plus the refresh section', () => {
    const r = render();
    const groups = diagnosticsGroups(diagnostics);
    expect(r.titles).toEqual([...groups.map((g) => g.title), undefined]);
    expect(all(r.els, 'FlagRow')).toHaveLength(groups.reduce((n, g) => n + g.rows.length, 0));
  });

  it('no diagnostics (engine not running) → explanation instead of flag rows, refresh still there', () => {
    const r = render({ diagnostics: null });
    expect(all(r.els, 'FlagRow')).toHaveLength(0);
    expect(texts(r.els)).toEqual([expect.stringContaining('algılama motoru çalışmıyor')]);
    expect(all(r.els, 'SecondaryButton').map((b) => b.props.label)).toEqual(['Şimdi yenile']);
  });

  it('refresh button calls onRefresh', () => {
    const r = render();
    const [refresh] = all(r.els, 'SecondaryButton');
    (refresh.props.onPress as () => void)();
    expect(r.props.onRefresh).toHaveBeenCalledTimes(1);
  });

  it('traces → one share button per file (newest first, as given) with the privacy warning', () => {
    const traces = ['20261126-2.jsonl', '20261126-1.jsonl'];
    const r = render({ traces });
    const section = r.sections.find((s) => s.props.title === TRACES_TITLE);
    expect(section?.props.footer).toEqual(expect.stringContaining('gerçek konum'));
    const buttons = flatten(section?.props.children).filter((e) => e.props.iconName === 'share');
    expect(buttons.map((b) => b.props.label)).toEqual(traces);
    (buttons[1].props.onPress as () => void)();
    expect(r.props.onShareTrace).toHaveBeenCalledWith('20261126-1.jsonl');
  });
});
