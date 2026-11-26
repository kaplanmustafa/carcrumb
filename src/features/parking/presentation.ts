import type { ParkingConfidence } from '../../../modules/carcrumb-detection';

/** How a park's confidence is explained to the user. */
export const confidenceCopy: Record<ParkingConfidence, { label: string; hint?: string }> = {
  high: { label: 'Yüksek' },
  low: {
    label: 'Düşük',
    hint: 'Konum tahmini. Kapalı otopark gibi yerlerde birkaç on metre sapabilir; önceki parklar aşağıda.',
  },
};
