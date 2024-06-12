// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

@testable import SessionMessagingKit

class MockOGPoller: Mock<OpenGroupAPI.PollerType>, OpenGroupAPI.PollerType {
    func startIfNeeded(using dependencies: Dependencies) {
        accept()
    }
    
    func stop() {
        accept()
    }
}
