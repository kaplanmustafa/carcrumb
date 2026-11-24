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
  # GRDB is added with the storage layer. GRDB 7 is not published to CocoaPods trunk;
  # decide there between Swift Package (spm_dependency) and another route.

  s.source_files = '*.swift', 'Detection/**/*.swift'
  s.exclude_files = 'Tests/**/*'

  s.test_spec 'Tests' do |t|
    t.source_files = 'Tests/**/*.swift'
  end

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES'
  }
end
