import type { DetectionStateName } from '../../../modules/carcrumb-detection';
import type { IconName, StatusTone } from '../../design/tokens';

/** How each detection state is shown to the user. Copy is Turkish (product language). */
export type StatePresentation = {
  title: string;
  description: string;
  iconName: IconName;
  tone: StatusTone;
};

export const statePresentation: Record<DetectionStateName, StatePresentation> = {
  IDLE: {
    title: 'Beklemede',
    description: 'Araç hareketi algılanınca yolculuk kendiliğinden başlar.',
    iconName: 'idle',
    tone: 'uncertain',
  },
  MAYBE_DRIVING: {
    title: 'Hareket algılandı',
    description: 'Sürüş olup olmadığı doğrulanıyor.',
    iconName: 'pending',
    tone: 'pending',
  },
  DRIVING: {
    title: 'Sürüşte',
    description: 'Yolculuk kaydediliyor.',
    iconName: 'driving',
    tone: 'driving',
  },
  MAYBE_PARKED: {
    title: 'Park ediliyor',
    description: 'Araçtan uzaklaştığın doğrulanınca park yeri kaydedilir.',
    iconName: 'walking',
    tone: 'pending',
  },
  PARKED: {
    title: 'Park edildi',
    description: 'Aracının yeri kaydedildi.',
    iconName: 'parked',
    tone: 'parked',
  },
};
