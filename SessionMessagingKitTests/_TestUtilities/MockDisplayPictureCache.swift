// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

@testable import SessionMessagingKit

class MockDisplayPictureCache: Mock<DisplayPictureCacheType>, DisplayPictureCacheType {
    var imageData: [String: Data] {
        get { return mock() }
        set { mockNoReturn(args: [newValue]) }
    }
    var downloadsToSchedule: Set<DisplayPictureManager.DownloadInfo> {
        get { return mock() }
        set { mockNoReturn(args: [newValue]) }
    }
}
