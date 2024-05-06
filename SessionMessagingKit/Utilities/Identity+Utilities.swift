// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public extension Identity {
    /// The user actually exists very early on during the onboarding process but there are also a few cases
    /// where we want to know that the user is in a valid state (ie. has completed the proper onboarding
    /// process), this value indicates that state
    ///
    /// One case which can happen is if the app crashed during onboarding the user can be left in an invalid
    /// state (ie. with no display name) - the user would be asked to enter one on a subsequent launch to
    /// resolve the invalid state
    static func userCompletedRequiredOnboarding(
        _ db: Database? = nil,
        using dependencies: Dependencies = Dependencies()
    ) -> Bool {
        Identity.userExists(db, using: dependencies) &&
        !Profile.fetchOrCreateCurrentUser(db, using: dependencies).name.isEmpty
    }
}
