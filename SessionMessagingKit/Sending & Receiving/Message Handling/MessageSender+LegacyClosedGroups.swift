// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionSnodeKit

extension MessageSender {
    public static var distributingKeyPairs: Atomic<[String: [ClosedGroupKeyPair]]> = Atomic([:])
    
    public static func createLegacyClosedGroup(
        name: String,
        members: Set<String>,
        using dependencies: Dependencies
    ) -> AnyPublisher<SessionThread, Error> {
        dependencies[singleton: .storage]
            .writePublisher { db -> (SessionId, SessionThread, [HTTP.PreparedRequest<Void>], Set<String>) in
                // Generate the group's two keys
                guard
                    let groupKeyPair: KeyPair = dependencies[singleton: .crypto].generate(.x25519KeyPair()),
                    let encryptionKeyPair: KeyPair = dependencies[singleton: .crypto].generate(.x25519KeyPair())
                else { throw MessageSenderError.noKeyPair }
                
                // Legacy group ids have the 'SessionId.Prefix.standard' prefix
                let legacyGroupSessionId: String = SessionId(.standard, publicKey: groupKeyPair.publicKey).hexString
                let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
                var members: Set<String> = members
                
                // Create the group
                members.insert(userSessionId.hexString) // Ensure the current user is included in the member list
                let membersAsData: [Data] = members.map { Data(hex: $0) }
                let admins: Set<String> = [ userSessionId.hexString ]
                let adminsAsData: [Data] = admins.map { Data(hex: $0) }
                let formationTimestamp: TimeInterval = TimeInterval(Double(SnodeAPI.currentOffsetTimestampMs()) / 1000)
                
                // Create the relevant objects in the database
                let thread: SessionThread = try SessionThread.fetchOrCreate(
                    db,
                    id: legacyGroupSessionId,
                    variant: .legacyGroup,
                    shouldBeVisible: true,
                    calledFromConfigHandling: false,
                    using: dependencies
                )
                try ClosedGroup(
                    threadId: legacyGroupSessionId,
                    name: name,
                    formationTimestamp: formationTimestamp,
                    shouldPoll: true,   // Legacy groups should always poll
                    invited: false      // Legacy groups are never in the "invite" state
                ).insert(db)
                
                // Store the key pair
                let latestKeyPairReceivedTimestamp: TimeInterval = TimeInterval(Double(SnodeAPI.currentOffsetTimestampMs()) / 1000)
                try ClosedGroupKeyPair(
                    threadId: legacyGroupSessionId,
                    publicKey: Data(encryptionKeyPair.publicKey),
                    secretKey: Data(encryptionKeyPair.secretKey),
                    receivedTimestamp: latestKeyPairReceivedTimestamp
                ).insert(db)
                
                // Create the member objects
                try admins.forEach { adminId in
                    try GroupMember(
                        groupId: legacyGroupSessionId,
                        profileId: adminId,
                        role: .admin,
                        roleStatus: .accepted,  // Legacy group members don't have role statuses
                        isHidden: false
                    ).upsert(db)
                }
                
                try members.forEach { memberId in
                    try GroupMember(
                        groupId: legacyGroupSessionId,
                        profileId: memberId,
                        role: .standard,
                        roleStatus: .accepted,  // Legacy group members don't have role statuses
                        isHidden: false
                    ).upsert(db)
                }
                
                // Update libSession
                try LibSession.add(
                    db,
                    legacyGroupSessionId: legacyGroupSessionId,
                    name: name,
                    latestKeyPairPublicKey: Data(encryptionKeyPair.publicKey),
                    latestKeyPairSecretKey: Data(encryptionKeyPair.secretKey),
                    latestKeyPairReceivedTimestamp: latestKeyPairReceivedTimestamp,
                    disappearingConfig: DisappearingMessagesConfiguration.defaultWith(legacyGroupSessionId),
                    members: members,
                    admins: admins,
                    formationTimestamp: formationTimestamp,
                    using: dependencies
                )
                
                let memberSendData: [HTTP.PreparedRequest<Void>] = try members
                    .map { memberId -> HTTP.PreparedRequest<Void> in
                        try MessageSender.preparedSend(
                            db,
                            message: ClosedGroupControlMessage(
                                kind: .new(
                                    publicKey: Data(hex: legacyGroupSessionId),
                                    name: name,
                                    encryptionKeyPair: encryptionKeyPair,
                                    members: membersAsData,
                                    admins: adminsAsData,
                                    expirationTimer: 0
                                ),
                                // Note: We set this here to ensure the value matches
                                // the 'ClosedGroup' object we created
                                sentTimestampMs: UInt64(floor(formationTimestamp * 1000))
                            ),
                            to: .contact(publicKey: memberId),
                            namespace: Message.Destination.contact(publicKey: memberId).defaultNamespace,
                            interactionId: nil,
                            fileIds: [],
                            using: dependencies
                        )
                    }
                let allActiveLegacyGroupIds: Set<String> = try ClosedGroup
                    .select(.threadId)
                    .filter(!ClosedGroup.Columns.threadId.like("\(SessionId.Prefix.group.rawValue)%"))
                    .joining(
                        required: ClosedGroup.members
                            .filter(GroupMember.Columns.profileId == userSessionId.hexString)
                    )
                    .asRequest(of: String.self)
                    .fetchSet(db)
                    .inserting(legacyGroupSessionId)  // Insert the new key just to be sure
                
                return (userSessionId, thread, memberSendData, allActiveLegacyGroupIds)
            }
            .flatMap { userSessionId, thread, memberSendData, allActiveLegacyGroupIds in
                Publishers
                    .MergeMany(
                        // Send a closed group update message to all members individually
                        memberSendData
                            .appending(
                                // Resubscribe to all legacy groups
                                try? PushNotificationAPI
                                    .preparedSubscribeToLegacyGroups(
                                        userSessionId: userSessionId,
                                        legacyGroupIds: allActiveLegacyGroupIds,
                                        using: dependencies
                                    )?
                                    .map { _, _ in () }
                            )
                            .map { $0.send(using: dependencies) }
                    )
                    .collect()
                    .map { _ in thread }
            }
            .handleEvents(
                receiveOutput: { thread in
                    // Start polling
                    dependencies[singleton: .groupsPoller].startIfNeeded(for: thread.id, using: dependencies)
                }
            )
            .eraseToAnyPublisher()
    }

    /// Generates and distributes a new encryption key pair for the group with the given closed group. This sends an
    /// `ENCRYPTION_KEY_PAIR` message to the group. The message contains a list of key pair wrappers. Each key
    /// pair wrapper consists of the public key for which the wrapper is intended along with the newly generated key pair
    /// encrypted for that public key.
    ///
    /// The returned promise is fulfilled when the message has been sent to the group.
    private static func generateAndSendNewEncryptionKeyPair(
        targetMembers: Set<String>,
        userSessionId: SessionId,
        allGroupMembers: [GroupMember],
        closedGroup: ClosedGroup,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        guard allGroupMembers.contains(where: { $0.role == .admin && $0.profileId == userSessionId.hexString }) else {
            return Fail(error: MessageSenderError.invalidClosedGroupUpdate)
                .eraseToAnyPublisher()
        }
        
        return dependencies[singleton: .storage]
            .readPublisher { db -> (ClosedGroupKeyPair, HTTP.PreparedRequest<Void>) in
                // Generate the new encryption key pair
                guard let legacyNewKeyPair: KeyPair = dependencies[singleton: .crypto].generate(.x25519KeyPair()) else {
                    throw MessageSenderError.noKeyPair
                }
                
                let newKeyPair: ClosedGroupKeyPair = ClosedGroupKeyPair(
                    threadId: closedGroup.threadId,
                    publicKey: Data(legacyNewKeyPair.publicKey),
                    secretKey: Data(legacyNewKeyPair.secretKey),
                    receivedTimestamp: TimeInterval(Double(SnodeAPI.currentOffsetTimestampMs()) / 1000)
                )
                
                // Distribute it
                let proto = try SNProtoKeyPair.builder(
                    publicKey: newKeyPair.publicKey,
                    privateKey: newKeyPair.secretKey
                ).build()
                let plaintext = try proto.serializedData()
                
                distributingKeyPairs.mutate {
                    $0[closedGroup.id] = ($0[closedGroup.id] ?? [])
                        .appending(newKeyPair)
                }
                
                let preparedRequest: HTTP.PreparedRequest<Void> = try MessageSender
                    .preparedSend(
                        db,
                        message: ClosedGroupControlMessage(
                            kind: .encryptionKeyPair(
                                publicKey: nil,
                                wrappers: targetMembers.map { memberPublicKey in
                                    ClosedGroupControlMessage.KeyPairWrapper(
                                        publicKey: memberPublicKey,
                                        encryptedKeyPair: try dependencies[singleton: .crypto].tryGenerate(
                                            .ciphertextWithSessionProtocol(
                                                db,
                                                plaintext: plaintext,
                                                destination: .contact(publicKey: memberPublicKey),
                                                using: dependencies
                                            )
                                        )
                                    )
                                }
                            )
                        ),
                        to: try Message.Destination
                            .from(db, threadId: closedGroup.threadId, threadVariant: .legacyGroup),
                        namespace: try Message.Destination
                            .from(db, threadId: closedGroup.threadId, threadVariant: .legacyGroup)
                            .defaultNamespace,
                        interactionId: nil,
                        fileIds: [],
                        using: dependencies
                    )
                
                return (newKeyPair, preparedRequest)
            }
            .flatMap { newKeyPair, preparedRequest -> AnyPublisher<ClosedGroupKeyPair, Error> in
                preparedRequest.send(using: dependencies)
                    .map { _ in newKeyPair }
                    .eraseToAnyPublisher()
            }
            .handleEvents(
                receiveOutput: { newKeyPair in
                    /// Store it **after** having sent out the message to the group
                    dependencies[singleton: .storage].write { db in
                        try newKeyPair.insert(db)
                        
                        // Update libSession
                        try? LibSession.update(
                            db,
                            legacyGroupSessionId: closedGroup.threadId,
                            latestKeyPair: newKeyPair,
                            members: allGroupMembers
                                .filter { $0.role == .standard || $0.role == .zombie }
                                .map { $0.profileId }
                                .asSet(),
                            admins: allGroupMembers
                                .filter { $0.role == .admin }
                                .map { $0.profileId }
                                .asSet(),
                            using: dependencies
                        )
                    }
                    
                    distributingKeyPairs.mutate {
                        if let index = ($0[closedGroup.id] ?? []).firstIndex(of: newKeyPair) {
                            $0[closedGroup.id] = ($0[closedGroup.id] ?? [])
                                .removing(index: index)
                        }
                    }
                }
            )
            .map { _ in () }
            .eraseToAnyPublisher()
    }
    
    public static func update(
        legacyGroupSessionId: String,
        with members: Set<String>,
        name: String,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Void, Error> {
        return dependencies[singleton: .storage]
            .writePublisher { db -> (SessionId, ClosedGroup, [GroupMember], Set<String>) in
                let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
                
                // Get the group, check preconditions & prepare
                guard (try? SessionThread.exists(db, id: legacyGroupSessionId)) == true else {
                    SNLog("Can't update nonexistent closed group.")
                    throw MessageSenderError.noThread
                }
                guard let closedGroup: ClosedGroup = try? ClosedGroup.fetchOne(db, id: legacyGroupSessionId) else {
                    throw MessageSenderError.invalidClosedGroupUpdate
                }
                
                // Update name if needed
                if name != closedGroup.name {
                    // Update the group
                    _ = try ClosedGroup
                        .filter(id: closedGroup.id)
                        .updateAll(db, ClosedGroup.Columns.name.set(to: name))
                    
                    // Notify the user
                    let interaction: Interaction = try Interaction(
                        threadId: legacyGroupSessionId,
                        authorId: userSessionId.hexString,
                        variant: .infoLegacyGroupUpdated,
                        body: ClosedGroupControlMessage.Kind
                            .nameChange(name: name)
                            .infoMessage(db, sender: userSessionId.hexString),
                        timestampMs: SnodeAPI.currentOffsetTimestampMs()
                    ).inserted(db)
                    
                    guard let interactionId: Int64 = interaction.id else { throw StorageError.objectNotSaved }
                    
                    // Send the update to the group
                    try MessageSender.send(
                        db,
                        message: ClosedGroupControlMessage(kind: .nameChange(name: name)),
                        interactionId: interactionId,
                        threadId: legacyGroupSessionId,
                        threadVariant: .legacyGroup,
                        using: dependencies
                    )
                    
                    // Update libSession
                    try? LibSession.update(
                        db,
                        legacyGroupSessionId: closedGroup.threadId,
                        name: name,
                        using: dependencies
                    )
                }
                
                // Retrieve member info
                guard let allGroupMembers: [GroupMember] = try? closedGroup.allMembers.fetchAll(db) else {
                    throw MessageSenderError.invalidClosedGroupUpdate
                }
                
                let standardAndZombieMemberIds: [String] = allGroupMembers
                    .filter { $0.role == .standard || $0.role == .zombie }
                    .map { $0.profileId }
                let addedMembers: Set<String> = members.subtracting(standardAndZombieMemberIds)
                
                // Add members if needed
                if !addedMembers.isEmpty {
                    do {
                        try addMembers(
                            db,
                            addedMembers: addedMembers,
                            userSessionId: userSessionId,
                            allGroupMembers: allGroupMembers,
                            closedGroup: closedGroup,
                            using: dependencies
                        )
                    }
                    catch {
                        throw MessageSenderError.invalidClosedGroupUpdate
                    }
                }
                
                // Remove members if needed
                return (
                    userSessionId,
                    closedGroup,
                    allGroupMembers,
                    Set(standardAndZombieMemberIds).subtracting(members)
                )
            }
            .flatMap { userSessionId, closedGroup, allGroupMembers, removedMembers -> AnyPublisher<Void, Error> in
                guard !removedMembers.isEmpty else {
                    return Just(())
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                
                return removeMembers(
                    removedMembers: removedMembers,
                    userSessionId: userSessionId,
                    allGroupMembers: allGroupMembers,
                    closedGroup: closedGroup,
                    using: dependencies
                )
                .catch { _ in Fail(error: MessageSenderError.invalidClosedGroupUpdate).eraseToAnyPublisher() }
                .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
    

    /// Adds `newMembers` to the group with the given closed group. This sends a `MEMBERS_ADDED` message to the group, and a
    /// `NEW` message to the members that were added (using one-on-one channels).
    private static func addMembers(
        _ db: Database,
        addedMembers: Set<String>,
        userSessionId: SessionId,
        allGroupMembers: [GroupMember],
        closedGroup: ClosedGroup,
        using dependencies: Dependencies
    ) throws {
        guard let disappearingMessagesConfig: DisappearingMessagesConfiguration = try DisappearingMessagesConfiguration.fetchOne(db, id: closedGroup.threadId) else {
            throw StorageError.objectNotFound
        }
        guard let encryptionKeyPair: ClosedGroupKeyPair = try closedGroup.fetchLatestKeyPair(db) else {
            throw StorageError.objectNotFound
        }
        
        let groupMemberIds: [String] = allGroupMembers
            .filter { $0.role == .standard }
            .map { $0.profileId }
        let groupAdminIds: [String] = allGroupMembers
            .filter { $0.role == .admin }
            .map { $0.profileId }
        let members: Set<String> = Set(groupMemberIds).union(addedMembers)
        let membersAsData: [Data] = members.map { Data(hex: $0) }
        let adminsAsData: [Data] = groupAdminIds.map { Data(hex: $0) }
        
        // Notify the user
        let interaction: Interaction = try Interaction(
            threadId: closedGroup.threadId,
            authorId: userSessionId.hexString,
            variant: .infoLegacyGroupUpdated,
            body: ClosedGroupControlMessage.Kind
                .membersAdded(members: addedMembers.map { Data(hex: $0) })
                .infoMessage(db, sender: userSessionId.hexString),
            timestampMs: SnodeAPI.currentOffsetTimestampMs()
        ).inserted(db)
        
        guard let interactionId: Int64 = interaction.id else { throw StorageError.objectNotSaved }
        
        // Update libSession
        try? LibSession.update(
            db,
            legacyGroupSessionId: closedGroup.threadId,
            members: allGroupMembers
                .filter { $0.role == .standard || $0.role == .zombie }
                .map { $0.profileId }
                .asSet()
                .union(addedMembers),
            admins: allGroupMembers
                .filter { $0.role == .admin }
                .map { $0.profileId }
                .asSet(),
            using: dependencies
        )
        
        // Send the update to the group
        try MessageSender.send(
            db,
            message: ClosedGroupControlMessage(
                kind: .membersAdded(members: addedMembers.map { Data(hex: $0) })
            ),
            interactionId: interactionId,
            threadId: closedGroup.threadId,
            threadVariant: .legacyGroup,
            using: dependencies
        )
        
        try addedMembers.forEach { member in
            // Send updates to the new members individually
            try SessionThread.fetchOrCreate(
                db,
                id: member,
                variant: .contact,
                shouldBeVisible: nil,
                calledFromConfigHandling: false,
                using: dependencies
            )
            
            try MessageSender.send(
                db,
                message: ClosedGroupControlMessage(
                    kind: .new(
                        publicKey: Data(hex: closedGroup.id),
                        name: closedGroup.name,
                        encryptionKeyPair: KeyPair(
                            publicKey: encryptionKeyPair.publicKey.bytes,
                            secretKey: encryptionKeyPair.secretKey.bytes
                        ),
                        members: membersAsData,
                        admins: adminsAsData,
                        expirationTimer: (disappearingMessagesConfig.isEnabled ?
                            UInt32(floor(disappearingMessagesConfig.durationSeconds)) :
                            0
                        )
                    )
                ),
                interactionId: nil,
                threadId: member,
                threadVariant: .contact,
                using: dependencies
            )
            
            // Add the users to the group
            try GroupMember(
                groupId: closedGroup.id,
                profileId: member,
                role: .standard,
                roleStatus: .accepted,  // Legacy group members don't have role statuses
                isHidden: false
            ).upsert(db)
        }
    }

    /// Removes `membersToRemove` from the group with the given `groupPublicKey`. Only the admin can remove members, and when they do
    /// they generate and distribute a new encryption key pair for the group. A member cannot leave a group using this method. For that they should use
    /// `leave(:using:)`.
    ///
    /// The returned promise is fulfilled when the `MEMBERS_REMOVED` message has been sent to the group AND the new encryption key pair has been
    /// generated and distributed.
    private static func removeMembers(
        removedMembers: Set<String>,
        userSessionId: SessionId,
        allGroupMembers: [GroupMember],
        closedGroup: ClosedGroup,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Void, Error> {
        guard !removedMembers.contains(userSessionId.hexString) else {
            SNLog("Invalid closed group update.")
            return Fail(error: MessageSenderError.invalidClosedGroupUpdate)
                .eraseToAnyPublisher()
        }
        guard allGroupMembers.contains(where: { $0.role == .admin && $0.profileId == userSessionId.hexString }) else {
            SNLog("Only an admin can remove members from a group.")
            return Fail(error: MessageSenderError.invalidClosedGroupUpdate)
                .eraseToAnyPublisher()
        }
        
        let groupMemberIds: [String] = allGroupMembers
            .filter { $0.role == .standard }
            .map { $0.profileId }
        let groupZombieIds: [String] = allGroupMembers
            .filter { $0.role == .zombie }
            .map { $0.profileId }
        let members: Set<String> = Set(groupMemberIds).subtracting(removedMembers)
        
        return dependencies[singleton: .storage]
            .writePublisher { db in
                // Update zombie & member list
                try GroupMember
                    .filter(GroupMember.Columns.groupId == closedGroup.threadId)
                    .filter(removedMembers.contains(GroupMember.Columns.profileId))
                    .filter([ GroupMember.Role.standard, GroupMember.Role.zombie ].contains(GroupMember.Columns.role))
                    .deleteAll(db)
                
                let interactionId: Int64?
                
                // Notify the user if needed (not if only zombie members were removed)
                if !removedMembers.subtracting(groupZombieIds).isEmpty {
                    let interaction: Interaction = try Interaction(
                        threadId: closedGroup.threadId,
                        authorId: userSessionId.hexString,
                        variant: .infoLegacyGroupUpdated,
                        body: ClosedGroupControlMessage.Kind
                            .membersRemoved(members: removedMembers.map { Data(hex: $0) })
                            .infoMessage(db, sender: userSessionId.hexString),
                        timestampMs: SnodeAPI.currentOffsetTimestampMs()
                    ).inserted(db)
                    
                    guard let newInteractionId: Int64 = interaction.id else { throw StorageError.objectNotSaved }
                    
                    interactionId = newInteractionId
                }
                else {
                    interactionId = nil
                }
                
                // Send the update to the group and generate + distribute a new encryption key pair
                return try MessageSender
                    .preparedSend(
                        db,
                        message: ClosedGroupControlMessage(
                            kind: .membersRemoved(
                                members: removedMembers.map { Data(hex: $0) }
                            )
                        ),
                        to: try Message.Destination
                            .from(db, threadId: closedGroup.threadId, threadVariant: .legacyGroup),
                        namespace: try Message.Destination
                            .from(db, threadId: closedGroup.threadId, threadVariant: .legacyGroup)
                            .defaultNamespace,
                        interactionId: interactionId,
                        fileIds: [],
                        using: dependencies
                    )
            }
            .flatMap { $0.send(using: dependencies) }
            .flatMap { _ -> AnyPublisher<Void, Error> in
                MessageSender.generateAndSendNewEncryptionKeyPair(
                    targetMembers: members,
                    userSessionId: userSessionId,
                    allGroupMembers: allGroupMembers,
                    closedGroup: closedGroup,
                    using: dependencies
                )
            }
            .eraseToAnyPublisher()
    }
    
    public static func sendLatestEncryptionKeyPair(
        _ db: Database,
        to publicKey: String,
        for groupPublicKey: String,
        using dependencies: Dependencies = Dependencies()
    ) {
        guard let thread: SessionThread = try? SessionThread.fetchOne(db, id: groupPublicKey) else {
            return SNLog("Couldn't send key pair for nonexistent closed group.")
        }
        guard let closedGroup: ClosedGroup = try? thread.closedGroup.fetchOne(db) else {
            return
        }
        guard let allGroupMembers: [GroupMember] = try? closedGroup.allMembers.fetchAll(db) else {
            return
        }
        guard allGroupMembers.contains(where: { $0.role == .standard && $0.profileId == publicKey }) else {
            return SNLog("Refusing to send latest encryption key pair to non-member.")
        }
        
        // Get the latest encryption key pair
        var maybeKeyPair: ClosedGroupKeyPair? = distributingKeyPairs.wrappedValue[groupPublicKey]?.last
        
        if maybeKeyPair == nil {
            maybeKeyPair = try? closedGroup.fetchLatestKeyPair(db)
        }
        
        guard let keyPair: ClosedGroupKeyPair = maybeKeyPair else { return }
        
        // Send it
        do {
            let proto = try SNProtoKeyPair.builder(
                publicKey: keyPair.publicKey,
                privateKey: keyPair.secretKey
            ).build()
            let plaintext = try proto.serializedData()
            let thread: SessionThread = try SessionThread.fetchOrCreate(
                db,
                id: publicKey,
                variant: .contact,
                shouldBeVisible: nil,
                calledFromConfigHandling: false,
                using: dependencies
            )
            let ciphertext = try dependencies[singleton: .crypto].tryGenerate(
                .ciphertextWithSessionProtocol(
                    db,
                    plaintext: plaintext,
                    destination: .contact(publicKey: publicKey),
                    using: dependencies
                )
            )
            
            SNLog("Sending latest encryption key pair to: \(publicKey).")
            try MessageSender.send(
                db,
                message: ClosedGroupControlMessage(
                    kind: .encryptionKeyPair(
                        publicKey: Data(hex: groupPublicKey),
                        wrappers: [
                            ClosedGroupControlMessage.KeyPairWrapper(
                                publicKey: publicKey,
                                encryptedKeyPair: ciphertext
                            )
                        ]
                    )
                ),
                interactionId: nil,
                threadId: thread.id,
                threadVariant: thread.variant,
                using: dependencies
            )
        }
        catch {}
    }
}
