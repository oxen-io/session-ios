// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let deviceSleepManager: SingletonConfig<DeviceSleepManager> = Dependencies.create(
        identifier: "deviceSleepManager",
        createInstance: { dependencies in DeviceSleepManager(using: dependencies) }
    )
}

// MARK: - DeviceSleepManager

/// This entity has responsibility for blocking the device from sleeping if certain behaviors (e.g. recording or
/// playing voice messages) are in progress.
///
/// Sleep blocking is keyed using "block objects" whose lifetime corresponds to the duration of the block.  For
/// example, sleep blocking during audio playback can be keyed to the audio player.  This provides a measure
/// of robustness.
///
/// On the one hand, we can use weak references to track block objects and stop blocking if the block object is
/// deallocated even if removeBlock() is not called.  On the other hand, we will also get correct behavior to addBlock()
/// being called twice with the same block object.
public class DeviceSleepManager {
    private class SleepBlock: CustomDebugStringConvertible {
        weak var blockObject: NSObject?

        var debugDescription: String {
            return "SleepBlock(\(String(reflecting: blockObject)))"
        }

        init(blockObject: NSObject?) {
            self.blockObject = blockObject
        }
    }
    private let dependencies: Dependencies
    private var blocks: [SleepBlock] = []
    
    // MARK: - Initialization

    fileprivate init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        DeviceSleepManager_objc.dependencies = dependencies

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didEnterBackground),
            name: .sessionDidEnterBackground,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Functions

    @objc private func didEnterBackground() {
        ensureSleepBlocking()
    }

    public func addBlock(blockObject: NSObject?) {
        blocks.append(SleepBlock(blockObject: blockObject))

        ensureSleepBlocking()
    }

    public func removeBlock(blockObject: NSObject?) {
        blocks = blocks.filter {
            $0.blockObject != nil && $0.blockObject != blockObject
        }

        ensureSleepBlocking()
    }

    private func ensureSleepBlocking() {
        // Cull expired blocks.
        blocks = blocks.filter {
            $0.blockObject != nil
        }
        let shouldBlock = blocks.count > 0

        guard dependencies.hasInitialised(singleton: .appContext) else { return }
       
        dependencies[singleton: .appContext].ensureSleepBlocking(shouldBlock, blockingObjects: blocks)
    }
}

// MARK: - Objective-C Support

@objc(DeviceSleepManager_objc)
public class DeviceSleepManager_objc: NSObject {
    fileprivate static var dependencies: Dependencies!
    
    @objc public static func addBlock(blockObject: NSObject?) {
        dependencies[singleton: .deviceSleepManager].addBlock(blockObject: blockObject)
    }

    @objc public static func removeBlock(blockObject: NSObject?) {
        dependencies[singleton: .deviceSleepManager].removeBlock(blockObject: blockObject)
    }
}
