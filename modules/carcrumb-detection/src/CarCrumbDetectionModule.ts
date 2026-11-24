import { NativeModule, requireNativeModule } from 'expo';

import type { CarCrumbDetectionModuleEvents, DetectionStateName } from './CarCrumbDetection.types';

declare class CarCrumbDetectionModule extends NativeModule<CarCrumbDetectionModuleEvents> {
  getState(): DetectionStateName;
}

export default requireNativeModule<CarCrumbDetectionModule>('CarCrumbDetection');
