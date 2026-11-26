import { PermissionScreen } from '../../design/components';
import type { OnboardingStep } from './flow';

/** Copy for each permission explanation. One button ("Devam") straight to the system dialog. */
export const permissionCopy: Record<Exclude<OnboardingStep, 'done'>, { title: string; explanation: string }> = {
  location: {
    title: 'Konum izni',
    explanation:
      'CarCrumb, aracını park ettiğin yeri ve yolculuklarını kaydetmek için konumunu kullanır. Veriler yalnızca bu cihazda kalır.',
  },
  motion: {
    title: 'Hareket izni',
    explanation:
      'CarCrumb, sürüşü ve araçtan inip yürümeye başladığını ayırt etmek için hareket verilerini kullanır. Veriler yalnızca bu cihazda kalır.',
  },
  always: {
    title: 'Arka planda kayıt',
    explanation:
      'Uygulama kapalıyken de yolculuklarını ve park yerini kendiliğinden kaydedebilmek için CarCrumb konumuna her zaman erişmeli. Tercihini sonraki pencerede yapabilirsin; veriler yalnızca bu cihazda kalır.',
  },
};

const stepIcon = { location: 'location', motion: 'motion', always: 'car' } as const;

export function OnboardingScreen({ step, onContinue }: { step: Exclude<OnboardingStep, 'done'>; onContinue: () => void }) {
  const copy = permissionCopy[step];
  return (
    <PermissionScreen
      title={copy.title}
      explanation={copy.explanation}
      iconName={stepIcon[step]}
      onContinue={onContinue}
    />
  );
}
