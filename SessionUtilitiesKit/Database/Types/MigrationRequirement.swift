// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum MigrationRequirement: CaseIterable {
    case libSessionStateLoaded
    
    var shouldProcessAtCompletionIfNotRequired: Bool {
        switch self {
            case .libSessionStateLoaded: return true
        }
    }
}
