// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension JSONDecoder {
    convenience init(using dependencies: Dependencies) {
        self.init()
        self.userInfo = [ Dependencies.userInfoKey: dependencies ]
    }
}

public extension Decoder {
    var dependencies: Dependencies? { self.userInfo[Dependencies.userInfoKey] as? Dependencies }
}
