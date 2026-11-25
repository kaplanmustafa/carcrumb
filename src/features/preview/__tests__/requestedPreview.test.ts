/**
 * requestedPreview(): the real app must never switch to a design preview unless the bundle
 * was built with EXPO_PUBLIC_PREVIEW=1, and then only to a known screen.
 */
// Settings reads NSUserDefaults through a native module: replace it. DesignPreview uses
// nothing else from react-native.
const mockSettingsGet = jest.fn();
jest.mock('react-native', () => ({ Settings: { get: (key: string) => mockSettingsGet(key) } }));

// Keep the SwiftUI components out of the test: only the launch-argument logic is under test.
jest.mock('../../../design/components', () => ({}));

const ENV = 'EXPO_PUBLIC_PREVIEW';
const originalEnv = process.env[ENV];

function load(): typeof import('../DesignPreview') {
  let mod!: typeof import('../DesignPreview');
  jest.isolateModules(() => {
    mod = require('../DesignPreview');
  });
  return mod;
}

const settingsGet = mockSettingsGet;

afterEach(() => {
  settingsGet.mockReset();
  if (originalEnv === undefined) delete process.env[ENV];
  else process.env[ENV] = originalEnv;
});

describe('requestedPreview without EXPO_PUBLIC_PREVIEW=1', () => {
  it.each([[undefined], [''], ['0'], ['true'], ['yes']])('EXPO_PUBLIC_PREVIEW=%p → null, launch argument not read', (env) => {
    if (env === undefined) delete process.env[ENV];
    else process.env[ENV] = env;
    settingsGet.mockReturnValue('states');

    expect(load().requestedPreview()).toBeNull();
    expect(settingsGet).not.toHaveBeenCalled();
  });
});

describe('requestedPreview with EXPO_PUBLIC_PREVIEW=1', () => {
  beforeEach(() => {
    process.env[ENV] = '1';
  });

  it.each([['states'], ['components'], ['permission']])('allowed value %p is returned', (value) => {
    settingsGet.mockReturnValue(value);
    expect(load().requestedPreview()).toBe(value);
    expect(settingsGet).toHaveBeenCalledWith('previewScreen');
  });

  it.each([[undefined], [null], [''], ['States'], ['states '], ['settings'], [1], [['states']], [{ screen: 'states' }]])(
    'other value %p → null',
    (value) => {
      settingsGet.mockReturnValue(value);
      expect(load().requestedPreview()).toBeNull();
    },
  );
});
