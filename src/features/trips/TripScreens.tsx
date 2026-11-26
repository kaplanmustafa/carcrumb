/**
 * Trip history (list) and trip detail (route map + facts). Rendered as <Destination>
 * pages of the home screen's navigation stack. Presentational: data comes in as props.
 */
import type { TripRecord } from '../../../modules/carcrumb-detection';
import { DetailRow, Destination, EmptyState, InfoRow, NavRow, Section, Txt } from '../../design/components';
import { RouteMap } from '../../design/RouteMap';
import { cameraForRoute } from './camera';
import { formatDateTime, formatDistance, formatDuration, formatTime, statusCopy, tripSummary } from './format';
import type { RouteState } from './useTrips';

export const HISTORY = 'history';
export const tripValue = (id: number) => `trip:${id}`;
export const tripIdFromValue = (value: string): number | null => {
  const m = /^trip:(\d+)$/.exec(value);
  return m ? Number(m[1]) : null;
};

export function HistoryPage({ trips, loaded }: { trips: TripRecord[]; loaded: boolean }) {
  return (
    <Destination value={HISTORY} title="Yolculuklar">
      {loaded && trips.length === 0 ? (
        <EmptyState
          title="Henüz yolculuk yok"
          iconName="history"
          description="Araç kullandığında yolculukların burada kendiliğinden listelenir."
        />
      ) : (
        <Section footer="Belirsiz yolculuklar araç bağlantısı olmadan kaydedildi; park yeri yazmaz.">
          {trips.map((t) => (
            <NavRow key={t.id} value={tripValue(t.id)}>
              <DetailRow
                title={formatDateTime(t.startedAt)}
                detail={tripSummary(t)}
                note={t.status === 'confirmed' ? undefined : statusCopy[t.status].label}
              />
            </NavRow>
          ))}
        </Section>
      )}
    </Destination>
  );
}

export function TripPage({ trip, route }: { trip: TripRecord; route: RouteState }) {
  const camera = route.status === 'ready' ? cameraForRoute(route.points) : null;
  const status = statusCopy[trip.status];
  return (
    <Destination value={tripValue(trip.id)} title={formatDateTime(trip.startedAt)}>
      <Section footer="Rota yalnızca bu cihazda saklanır ve çizilir.">
        {route.status === 'loading' ? <Txt tone="secondary">Rota yükleniyor…</Txt> : null}
        {route.status === 'error' ? <Txt tone="secondary">Rota şu an okunamadı.</Txt> : null}
        {route.status === 'ready' && camera && route.points.length > 1 ? (
          <RouteMap points={route.points} camera={camera} />
        ) : null}
        {route.status === 'ready' && route.points.length < 2 ? (
          <Txt tone="secondary">Bu yolculuk için rota kaydı yok.</Txt>
        ) : null}
      </Section>
      <Section footer={status.note}>
        <InfoRow label="Başlangıç" value={formatTime(trip.startedAt)} />
        <InfoRow label="Bitiş" value={trip.endedAt === null ? statusCopy.open.label : formatTime(trip.endedAt)} />
        {trip.endedAt !== null ? <InfoRow label="Süre" value={formatDuration(trip.endedAt - trip.startedAt)} /> : null}
        {trip.distanceMeters !== null ? <InfoRow label="Mesafe" value={formatDistance(trip.distanceMeters)} /> : null}
        <InfoRow label="Durum" value={status.label} />
      </Section>
    </Destination>
  );
}
