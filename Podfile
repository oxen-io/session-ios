platform :ios, '13.0'

use_frameworks!
inhibit_all_warnings!

install! 'cocoapods', :warn_for_unused_master_specs_repo => false

# CI Dependencies
pod 'xcbeautify'

# Dependencies to be included in the app and all extensions/frameworks
abstract_target 'GlobalDependencies' do
  pod 'GRDB.swift/SQLCipher'
  
  # FIXME: Would be nice to migrate from CocoaPods to SwiftPackageManager (should allow us to speed up build time), haven't gone through all of the dependencies but currently unfortunately SQLCipher doesn't support SPM (for more info see: https://github.com/sqlcipher/sqlcipher/issues/371)
  pod 'SQLCipher', '~> 4.5.3'
  pod 'WebRTC-lib'
  
  target 'Session' do
    pod 'Reachability'
    pod 'NVActivityIndicatorView'
    pod 'YYImage/libwebp', git: 'https://github.com/signalapp/YYImage'
    pod 'DifferenceKit'
    
    target 'SessionTests' do
      inherit! :complete
      
      pod 'Quick'
      pod 'Nimble'
    end
  end
  
  # Dependencies to be included only in all extensions/frameworks
  abstract_target 'FrameworkAndExtensionDependencies' do
    pod 'SignalCoreKit', git: 'https://github.com/oxen-io/session-ios-core-kit', branch: 'session-version'
    
    target 'SessionNotificationServiceExtension'
    
    target 'SessionShareExtension' do
      pod 'NVActivityIndicatorView'
      pod 'DifferenceKit'
    end
    
    target 'SignalUtilitiesKit' do
      pod 'NVActivityIndicatorView'
      pod 'Reachability'
      pod 'SAMKeychain'
      pod 'SwiftProtobuf', '~> 1.5.0'
      pod 'YYImage/libwebp', git: 'https://github.com/signalapp/YYImage'
      pod 'DifferenceKit'
    end
    
    target 'SessionMessagingKit' do
      pod 'Reachability'
      pod 'SAMKeychain'
      pod 'SwiftProtobuf', '~> 1.5.0'
      pod 'DifferenceKit'
      
      target 'SessionMessagingKitTests' do
        inherit! :complete
        
        pod 'Quick'
        pod 'Nimble'
        
        # Need to include this for the tests because otherwise it won't actually build
        pod 'YYImage/libwebp', git: 'https://github.com/signalapp/YYImage'
      end
    end
    
    target 'SessionUtilitiesKit' do
      pod 'SAMKeychain'
      pod 'YYImage/libwebp', git: 'https://github.com/signalapp/YYImage'
      pod 'DifferenceKit'
      
      target 'SessionUtilitiesKitTests' do
        inherit! :complete
        
        pod 'Quick'
        pod 'Nimble'
      end
    end
    
    target 'SessionSnodeKit' do
      target 'SessionSnodeKitTests' do
        inherit! :complete
        
        pod 'Quick'
        pod 'Nimble'
        
        # Need to include these for the tests because otherwise it won't actually build
        pod 'SAMKeychain'
        pod 'YYImage/libwebp', git: 'https://github.com/signalapp/YYImage'
        pod 'DifferenceKit'
      end
    end
  end
  
  target 'SessionUIKit' do
    pod 'GRDB.swift/SQLCipher'
    pod 'DifferenceKit'
    pod 'YYImage/libwebp', git: 'https://github.com/signalapp/YYImage'
  end
end

# Actions to perform post-install
post_install do |installer|
  set_minimum_deployment_target(installer)
end

def set_minimum_deployment_target(installer)
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |build_configuration|
      build_configuration.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '13.0'
    end
  end
end
