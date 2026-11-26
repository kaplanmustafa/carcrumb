/**
 * Settings (Ayarlar): route retention (DECISIONS "Rota saklama süresi") and deleting all
 * history (DECISIONS "Geçmişi silme kontrol listesi"; native `deleteAllHistory`).
 * Presentational: values and actions come in as props.
 */
import { ChoiceRow, Destination, DestructiveButton, Section, Txt } from '../../design/components';

export const SETTINGS = 'settings';

export type RouteRetention = 'threeMonths' | 'twelveMonths' | 'forever';

export const retentionOptions: readonly { value: RouteRetention; label: string }[] = [
  { value: 'threeMonths', label: '3 ay' },
  { value: 'twelveMonths', label: '12 ay' },
  { value: 'forever', label: 'Süresiz' },
];

export type DeleteStatus = 'idle' | 'deleting' | 'done' | 'failed';

const deleteStatusCopy: Record<Exclude<DeleteStatus, 'idle'>, string> = {
  deleting: 'Siliniyor…',
  done: 'Geçmiş silindi.',
  failed: 'Silme tamamlanamadı. Telefonun kilidi açıkken tekrar dene.',
};

export function SettingsPage({
  retention,
  onRetentionChange,
  deleteStatus,
  onDeleteHistory,
}: {
  /** null while it is being read. */
  retention: RouteRetention | null;
  onRetentionChange: (value: RouteRetention) => void;
  deleteStatus: DeleteStatus;
  onDeleteHistory: () => void;
}) {
  return (
    <Destination value={SETTINGS} title="Ayarlar">
      <Section
        title="Gizlilik"
        footer="Süresi dolan yolculukların rotası silinir; tarih, süre ve mesafe kalır. Tüm veriler yalnızca bu cihazda tutulur.">
        {retention ? (
          <ChoiceRow label="Rotaları sakla" options={retentionOptions} value={retention} onChange={onRetentionChange} />
        ) : (
          <Txt tone="secondary">Yükleniyor…</Txt>
        )}
      </Section>

      <Section
        title="Veriler"
        footer={
          deleteStatus === 'idle'
            ? 'Tüm yolculuklar, rotalar ve park yerleri kalıcı olarak silinir. Geri alınamaz.'
            : deleteStatusCopy[deleteStatus]
        }>
        <DestructiveButton
          label="Geçmişi sil"
          confirmTitle="Tüm geçmiş silinsin mi?"
          confirmMessage="Yolculuklar, rotalar ve kayıtlı park yerlerin bu cihazdan kalıcı olarak silinir. Bu işlem geri alınamaz."
          confirmLabel="Geçmişi sil"
          onConfirm={onDeleteHistory}
        />
      </Section>
    </Destination>
  );
}
