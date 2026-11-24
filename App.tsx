import { StatusBar } from 'expo-status-bar';
import { useEffect, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import CarCrumbDetection, { type DetectionStateName } from './modules/carcrumb-detection';

export default function App() {
  const [state, setState] = useState<DetectionStateName>(() => CarCrumbDetection.getState());

  useEffect(() => {
    const sub = CarCrumbDetection.addListener('onStateChange', (e) => setState(e.state));
    return () => sub.remove();
  }, []);

  return (
    <View style={styles.container}>
      <Text style={styles.title}>CarCrumb</Text>
      <Text>Algılama durumu: {state}</Text>
      <StatusBar style="auto" />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 8 },
  title: { fontSize: 24, fontWeight: '600' },
});
