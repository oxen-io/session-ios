// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUIKit
import SessionSnodeKit
import SessionMessagingKit
import SessionUtilitiesKit

public enum Configuration {
    public static func performMainSetup(using dependencies: Dependencies) {
        // Need to do this first to ensure the legacy database exists
        SNUtilitiesKit.configure(maxFileSize: UInt(FileServerAPI.maxFileSize), using: dependencies)
        SNMessagingKit.configure(using: dependencies)
        SNSnodeKit.configure(using: dependencies)
        SNUIKit.configure()
    }
}
