/**
 * "Already asked" marks for the dialogs iOS shows only once (motion, Always upgrade).
 * Stored in the app's own NSUserDefaults via React Native's Settings API: no extra
 * dependency, no personal data (a boolean per dialog), removed with the app.
 */
import { Settings } from 'react-native';

export type AskedDialog = 'motion' | 'always';

const key = (dialog: AskedDialog) => `carcrumb.permissionAsked.${dialog}`;

export function wasAsked(dialog: AskedDialog): boolean {
  return Settings.get(key(dialog)) === true;
}

export function markAsked(dialog: AskedDialog): void {
  Settings.set({ [key(dialog)]: true });
}
