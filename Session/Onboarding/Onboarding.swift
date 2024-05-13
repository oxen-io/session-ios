// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import Sodium
import GRDB
import SessionUtilitiesKit
import SessionMessagingKit
import SessionSnodeKit

enum Onboarding {
    private static let profileNameRetrievalIdentifier: Atomic<UUID?> = Atomic(nil)
    private static let profileNameRetrievalPublisher: Atomic<AnyPublisher<String?, Error>?> = Atomic(nil)
    public static var profileNamePublisher: AnyPublisher<String?, Error> {
        guard let existingPublisher: AnyPublisher<String?, Error> = profileNameRetrievalPublisher.wrappedValue else {
            return profileNameRetrievalPublisher.mutate { value in
                let requestId: UUID = UUID()
                let result: AnyPublisher<String?, Error> = createProfileNameRetrievalPublisher(requestId)
                
                value = result
                profileNameRetrievalIdentifier.mutate { $0 = requestId }
                return result
            }
        }
        
        return existingPublisher
    }
    
    private static func createProfileNameRetrievalPublisher(
        _ requestId: UUID,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<String?, Error> {
        let userPublicKey: String = getUserHexEncodedPublicKey(using: dependencies)
        
        return CurrentUserPoller()
            .poll(
                namespaces: [.configUserProfile],
                for: userPublicKey,
                // Note: These values mean the received messages will be
                // processed immediately rather than async as part of a Job
                calledFromBackgroundPoller: true,
                isBackgroundPollValid: { true },
                drainBehaviour: .alwaysRandom,
                using: dependencies
            )
            .map { _ -> String? in
                guard requestId == profileNameRetrievalIdentifier.wrappedValue else { return nil }
                
                return Storage.shared.read { db in
                    try Profile
                        .filter(id: userPublicKey)
                        .select(.name)
                        .asRequest(of: String.self)
                        .fetchOne(db)
                }
            }
            .shareReplay(1)
            .eraseToAnyPublisher()
    }
    
    enum State: CustomStringConvertible {
        case newUser
        case missingName
        case completed
        
        static var current: State {
            // If we have no identify information then the user needs to register
            guard Identity.userExists() else { return .newUser }
            
            // If we have no display name then collect one (this can happen if the
            // app crashed during onboarding which would leave the user in an invalid
            // state with no display name)
            guard !Profile.fetchOrCreateCurrentUser().name.isEmpty else { return .missingName }
            
            // Otherwise we have enough for a full user and can start the app
            return .completed
        }
        
        var description: String {
            switch self {
                case .newUser: return "New User"            // stringlint:disable
                case .missingName: return "Missing Name"    // stringlint:disable
                case .completed: return "Completed"         // stringlint:disable
            }
        }
    }
    
    enum Flow {
        case register, recover, link
        
        /// If the user returns to an earlier screen during Onboarding we might need to clear out a partially created
        /// account (eg. returning from the PN setting screen to the seed entry screen when linking a device)
        func unregister(using dependencies: Dependencies = Dependencies()) {
            // Clear the in-memory state from LibSession
            LibSession.clearMemoryState()
            
            // Clear any data which gets set during Onboarding
            Storage.shared.write { db in
                db[.hasViewedSeed] = false
                
                try SessionThread.deleteAll(db)
                try Profile.deleteAll(db)
                try Contact.deleteAll(db)
                try Identity.deleteAll(db)
                try ConfigDump.deleteAll(db)
                try SnodeReceivedMessageInfo.deleteAll(db)
            }
            
            // Clear the profile name retrieve publisher
            profileNameRetrievalIdentifier.mutate { $0 = nil }
            profileNameRetrievalPublisher.mutate { $0 = nil }
            
            // Clear the cached 'encodedPublicKey' if needed
            dependencies.caches.mutate(cache: .general) { $0.encodedPublicKey = nil }
            
            UserDefaults.standard[.hasSyncedInitialConfiguration] = false
        }
        
        func preregister(with seed: Data, ed25519KeyPair: KeyPair, x25519KeyPair: KeyPair) {
            let x25519PublicKey = x25519KeyPair.hexEncodedPublicKey
            
            // Create the initial shared util state (won't have been created on
            // launch due to lack of ed25519 key)
            LibSession.loadState(
                userPublicKey: x25519PublicKey,
                ed25519SecretKey: ed25519KeyPair.secretKey
            )
            
            // Store the user identity information
            Storage.shared.write { db in
                try Identity.store(
                    db,
                    seed: seed,
                    ed25519KeyPair: ed25519KeyPair,
                    x25519KeyPair: x25519KeyPair
                )
                
                // No need to show the seed again if the user is restoring or linking
                db[.hasViewedSeed] = (self == .recover || self == .link)
                
                // Create a contact for the current user and set their approval/trusted statuses so
                // they don't get weird behaviours
                try Contact
                    .fetchOrCreate(db, id: x25519PublicKey)
                    .save(db)
                try Contact
                    .filter(id: x25519PublicKey)
                    .updateAllAndConfig(
                        db,
                        Contact.Columns.isTrusted.set(to: true),    // Always trust the current user
                        Contact.Columns.isApproved.set(to: true),
                        Contact.Columns.didApproveMe.set(to: true)
                    )

                /// Create the 'Note to Self' thread (not visible by default)
                ///
                /// **Note:** We need to explicitly `updateAllAndConfig` the `shouldBeVisible` value to `false`
                /// otherwise it won't actually get synced correctly
                try SessionThread
                    .fetchOrCreate(db, id: x25519PublicKey, variant: .contact, shouldBeVisible: false)
                
                try SessionThread
                    .filter(id: x25519PublicKey)
                    .updateAllAndConfig(
                        db,
                        SessionThread.Columns.shouldBeVisible.set(to: false)
                    )
            }
            
            // Set hasSyncedInitialConfiguration to true so that when we hit the
            // home screen a configuration sync is triggered (yes, the logic is a
            // bit weird). This is needed so that if the user registers and
            // immediately links a device, there'll be a configuration in their swarm.
            UserDefaults.standard[.hasSyncedInitialConfiguration] = (self == .register)
            
            // Only continue if this isn't a new account
            guard self != .register else { return }
            
            // Fetch any existing profile name
            Onboarding.profileNamePublisher
                .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                .sinkUntilComplete()
        }
        
        func completeRegistration() {
            // Set the `lastNameUpdate` to the current date, so that we don't overwrite
            // what the user set in the display name step with whatever we find in their
            // swarm (otherwise the user could enter a display name and have it immediately
            // overwritten due to the config request running slow)
            Storage.shared.write { db in
                try Profile
                    .filter(id: getUserHexEncodedPublicKey(db))
                    .updateAllAndConfig(
                        db,
                        Profile.Columns.lastNameUpdate.set(to: Date().timeIntervalSince1970)
                    )
            }
            
            // Notify the app that registration is complete
            Identity.didRegister()
        }
    }
}
