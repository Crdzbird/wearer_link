#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint wearer_link.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'wearer_link'
  s.version          = '0.2.0'
  s.summary          = 'Phone-to-wearable link: messaging, synced data, background delivery.'
  s.description      = <<-DESC
Connects a Flutter iPhone app with its watchOS companion via WatchConnectivity:
bidirectional messaging, synced data, background delivery while the app is not
running, and workout-session watch launch.
                       DESC
  s.homepage         = 'https://github.com/crdzbird/wearer_link'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'crdzbird' => 'luisalfonsocb83@gmail.com' }
  s.source           = { :path => '.' }
  # Sources live in the Swift Package Manager layout; CocoaPods reuses them.
  s.source_files = 'wearer_link/Sources/wearer_link/**/*.swift'
  s.resource_bundles = {
    'wearer_link_privacy' => ['wearer_link/Sources/wearer_link/PrivacyInfo.xcprivacy']
  }
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'
  s.frameworks = 'WatchConnectivity', 'HealthKit'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
