import type { TripRecord, TripStatusName } from '../../../modules/carcrumb-detection';

/** "23 dk", "1 sa 5 dk", "2 sa". Under a minute shows "1 dk" (a trip is never 0 minutes). */
export function formatDuration(ms: number): string {
  const totalMin = Math.max(1, Math.round(ms / 60_000));
  const h = Math.floor(totalMin / 60);
  const m = totalMin % 60;
  if (h === 0) return `${m} dk`;
  return m === 0 ? `${h} sa` : `${h} sa ${m} dk`;
}

/** "850 m", "12,4 km" (Turkish decimal comma), "125 km" for long trips. */
export function formatDistance(meters: number): string {
  if (meters < 1000) return `${Math.round(meters / 10) * 10} m`;
  const km = meters / 1000;
  return km >= 100 ? `${Math.round(km)} km` : `${km.toFixed(1).replace('.', ',')} km`;
}

const dateTime = new Intl.DateTimeFormat('tr-TR', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
const timeOnly = new Intl.DateTimeFormat('tr-TR', { hour: '2-digit', minute: '2-digit' });

/** "26 Kas 14:32". */
export function formatDateTime(ms: number): string {
  return dateTime.format(new Date(ms));
}

/** "14:32". */
export function formatTime(ms: number): string {
  return timeOnly.format(new Date(ms));
}

export const statusCopy: Record<TripStatusName, { label: string; note?: string }> = {
  confirmed: { label: 'Onaylı' },
  uncertain: {
    label: 'Belirsiz',
    note: 'Araç bağlantısı olmadan kaydedildi (otobüs, taksi ya da başka bir araç olabilir); park yeri yazılmadı.',
  },
  recovered: { label: 'Kurtarılan', note: 'Hareket geçmişinden sonradan bulundu; rotası yok.' },
  open: { label: 'Devam ediyor' },
};

/** "23 dk · 12,4 km", or just the duration while distance is unknown. Open trips: "Devam ediyor". */
export function tripSummary(trip: TripRecord): string {
  if (trip.endedAt === null) return statusCopy.open.label;
  const parts = [formatDuration(trip.endedAt - trip.startedAt)];
  if (trip.distanceMeters !== null) parts.push(formatDistance(trip.distanceMeters));
  return parts.join(' · ');
}

/** Newest first by real start time (the bridge returns write order; see listTrips docs). */
export function sortTripsForHistory(trips: readonly TripRecord[]): TripRecord[] {
  return [...trips].sort((a, b) => b.startedAt - a.startedAt || b.id - a.id);
}
