// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension JSONEncoder {
    convenience init(using dependencies: Dependencies) {
        self.init()
        self.userInfo = [ Dependencies.userInfoKey: dependencies ]
        self.outputFormatting = .sortedKeys  // Default to sorted for deterministic ordering
    }
    
    func with(outputFormatting: JSONEncoder.OutputFormatting) -> JSONEncoder {
        let result: JSONEncoder = self
        result.outputFormatting = outputFormatting
        
        return result
    }
}

public extension Encoder {
    var dependencies: Dependencies? { self.userInfo[Dependencies.userInfoKey] as? Dependencies }
}
