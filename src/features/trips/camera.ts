/** A point on a trip's route (mirrors the native RoutePoint; contains coordinates — never log). */
export type RouteCoordinate = { latitude: number; longitude: number };

export type MapCamera = { coordinates: RouteCoordinate; zoom: number };

const MIN_ZOOM = 3;
const MAX_ZOOM = 17;

/**
 * Camera that frames the whole route: centre of the bounding box and a web-mercator zoom
 * level where the larger span fits with ~20% padding. Pure and approximate on purpose —
 * MapKit refines nothing here, so keep it simple and clamped.
 */
export function cameraForRoute(points: readonly RouteCoordinate[]): MapCamera | null {
  const valid = points.filter((p) => Number.isFinite(p.latitude) && Number.isFinite(p.longitude));
  if (valid.length === 0) return null;
  let minLat = Infinity;
  let maxLat = -Infinity;
  let minLon = Infinity;
  let maxLon = -Infinity;
  for (const p of valid) {
    minLat = Math.min(minLat, p.latitude);
    maxLat = Math.max(maxLat, p.latitude);
    minLon = Math.min(minLon, p.longitude);
    maxLon = Math.max(maxLon, p.longitude);
  }
  const centre = { latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2 };
  // Longitude degrees shrink with latitude; compare spans in "equator degrees".
  const lonSpan = (maxLon - minLon) * Math.cos((centre.latitude * Math.PI) / 180);
  const span = Math.max(maxLat - minLat, lonSpan) * 1.2;
  if (span <= 0) return { coordinates: centre, zoom: MAX_ZOOM - 1 };
  const zoom = Math.log2(360 / span);
  return { coordinates: centre, zoom: Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, Math.round(zoom * 2) / 2)) };
}
