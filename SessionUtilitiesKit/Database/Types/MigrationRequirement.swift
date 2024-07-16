// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

/// These are the different values which can be requirements for migrations to be able to be performed
///
/// **Note:** The order they appear here is the order they must be run in (so if a latter one is required then any earlier
/// once which have not yet been run will end up getting run)
public enum MigrationRequirement: CaseIterable, Comparable {
    case sessionIdCached
    case libSessionStateLoaded
    
    var shouldProcessAtCompletionIfNotRequired: Bool {
        switch self {
            case .sessionIdCached: return true
            case .libSessionStateLoaded: return true
        }
    }
}
