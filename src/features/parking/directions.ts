/**
 * Walking directions in Apple Maps (DECISIONS v1: "Apple Haritalar'da yürüyüş rotası").
 * `maps://` opens the Maps app on the device; CarCrumb itself sends nothing over the network.
 * The URL contains a raw coordinate: build it only to open it, never log it.
 */
export function walkingDirectionsUrl(latitude: number, longitude: number): string | null {
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) return null;
  if (Math.abs(latitude) > 90 || Math.abs(longitude) > 180) return null;
  // 6 decimals ≈ 0.1 m: enough for walking back to the car, no false precision.
  return `maps://?daddr=${latitude.toFixed(6)},${longitude.toFixed(6)}&dirflg=w`;
}
