require 'json'

package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

Pod::Spec.new do |s|
  s.name           = 'CarCrumbDetection'
  s.version        = package['version']
  s.summary        = package['description']
  s.description    = package['description']
  s.license        = package['license']
  s.author         = 'CarCrumb'
  s.homepage       = 'https://github.com/'
  s.platforms      = { :ios => '18.0' }
  s.swift_version  = '5.9'
  s.source         = { git: '' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  # GRDB 7 is not published to CocoaPods trunk, so it comes in as a Swift package through
  # React Native's helper (verified in react-native 0.88.1, scripts/react_native_pods.rb):
  #   def spm_dependency(spec, url:, requirement:, products:)
  # It records the package (scripts/cocoapods/spm.rb, SPMManager#dependency); the Podfile's
  # react_native_post_install then adds the package reference and the product dependency to
  # this pod's target in Pods.xcodeproj (SPMManager#apply_on_post_install). Expo autolinking
  # 58.1.0 tracks such pods (precompiled_modules.rb, record_spm_dependency_pods).
  # Fail loudly instead of producing a pod that cannot `import GRDB`.
  unless defined?(spm_dependency)
    raise 'CarCrumbDetection: React Native spm_dependency helper not found (needed for GRDB). ' \
          'The Podfile must require react-native/scripts/react_native_pods before use_expo_modules!.'
  end
  spm_dependency(s,
    url: 'https://github.com/groue/GRDB.swift.git',
    requirement: { kind: 'upToNextMajorVersion', minimumVersion: '7.0.0' },
    products: ['GRDB'])

  s.source_files = '*.swift', 'Detection/**/*.swift', 'Sensors/**/*.swift', 'Engine/**/*.swift', 'Store/**/*.swift'
  s.exclude_files = 'Tests/**/*', 'StoreTests/**/*'

  s.test_spec 'Tests' do |t|
    t.source_files = 'Tests/**/*.swift'
  end

  # DEBUG gates the sensor trace recorder (raw coordinates on disk). Set explicitly per
  # configuration instead of relying on the CocoaPods project default: Debug gets DEBUG,
  # Release gets no condition at all, so a release build can never record traces.
  # Verify on device via getDiagnostics().engine.traceRecording (false in release).
  # CARCRUMB_SPM is defined only by Package.swift (separate modules there); here all sources
  # form one module, so Store/ files do not import CarCrumbDetection.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS[config=Debug]' => '$(inherited) DEBUG',
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS[config=Release]' => ''
  }
end
