/**
 * Trip route on Apple MapKit (expo-maps; DECISIONS "Harita"). The line is drawn on the
 * device; CarCrumb sends the route nowhere (map tiles come from Apple). Read-only: no
 * user-location dot, no POI selection — this is a record, not navigation.
 */
import { AppleMaps } from 'expo-maps';
import { processColor, StyleSheet } from 'react-native';

import type { MapCamera, RouteCoordinate } from '../features/trips/camera';
import { EmbeddedView } from './components';
import { color, icon, size } from './tokens';

const LINE_WIDTH = 5;

export function RouteMap({
  points,
  camera,
  height = 'map',
}: {
  points: readonly RouteCoordinate[];
  camera: MapCamera;
  height?: keyof typeof size;
}) {
  const line = processColor(color.status.driving) ?? undefined;
  const start = points[0];
  const end = points[points.length - 1];
  return (
    <EmbeddedView height={height}>
      <AppleMaps.View
        style={styles.fill}
        cameraPosition={camera}
        polylines={points.length > 1 ? [{ coordinates: [...points], color: line, width: LINE_WIDTH }] : []}
        markers={[
          ...(start ? [{ coordinates: start, title: 'Başlangıç', systemImage: icon.car }] : []),
          ...(end && points.length > 1 ? [{ coordinates: end, title: 'Varış', systemImage: icon.parked }] : []),
        ]}
        properties={{ isMyLocationEnabled: false, selectionEnabled: false }}
        uiSettings={{ myLocationButtonEnabled: false, compassEnabled: false, togglePitchEnabled: false }}
      />
    </EmbeddedView>
  );
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
});
