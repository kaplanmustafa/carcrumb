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
};

export function OnboardingScreen({ step, onContinue }: { step: Exclude<OnboardingStep, 'done'>; onContinue: () => void }) {
  const copy = permissionCopy[step];
  return (
    <PermissionScreen
      title={copy.title}
      explanation={copy.explanation}
      iconName={step === 'location' ? 'location' : 'motion'}
      onContinue={onContinue}
    />
  );
}
