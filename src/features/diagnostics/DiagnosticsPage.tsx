/**
 * Field-test page (DECISIONS v1 "teşhis ekranı"): engine, permission and iOS location flags,
 * plus — in debug builds only — sharing the raw sensor traces for replay in CI.
 * Presentational; data and actions come in as props.
 */
import type { Diagnostics } from '../../../modules/carcrumb-detection';
import { Destination, FlagRow, SecondaryButton, Section, Txt } from '../../design/components';
import { diagnosticsGroups } from './rows';

export const DIAGNOSTICS = 'diagnostics';

export function DiagnosticsPage({
  diagnostics,
  traces,
  onRefresh,
  onShareTrace,
}: {
  diagnostics: Diagnostics | null;
  /** Debug trace file names, newest first; always empty in release builds. */
  traces: string[];
  onRefresh: () => void;
  onShareTrace: (name: string) => void;
}) {
  return (
    <Destination value={DIAGNOSTICS} title="Teşhis">
      {diagnostics ? (
        diagnosticsGroups(diagnostics).map((g) => (
          <Section key={g.title} title={g.title} footer={g.footer}>
            {g.rows.map((r) => (
              <FlagRow key={r.label} label={r.label} value={r.value} warn={r.warn} />
            ))}
          </Section>
        ))
      ) : (
        <Section>
          <Txt tone="secondary">Teşhis bilgisi alınamadı: algılama motoru çalışmıyor olabilir.</Txt>
        </Section>
      )}

      <Section footer="Değerler her 5 saniyede bir kendiliğinden yenilenir.">
        <SecondaryButton label="Şimdi yenile" iconName="refresh" onPress={onRefresh} />
      </Section>

      {traces.length > 0 ? (
        <Section
          title="Sensör kayıtları (debug)"
          footer="Bu dosyalar gerçek konum ve rota içerir. Yalnızca kendi bilgisayarına aktar; repoya ya da başka bir yere ekleme. 14 günden eski kayıtlar kendiliğinden silinir.">
          {traces.map((name) => (
            <SecondaryButton key={name} label={name} iconName="share" onPress={() => onShareTrace(name)} />
          ))}
        </Section>
      ) : null}
    </Destination>
  );
}
