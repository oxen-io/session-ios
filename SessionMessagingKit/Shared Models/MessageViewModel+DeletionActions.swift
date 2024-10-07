// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUIKit
import SessionSnodeKit
import SessionUtilitiesKit

public extension MessageViewModel {
    struct DeletionBehaviours {
        public enum Actions {
            case individual([Behaviour])
            case multiple([NamedAction])
            
            var count: Int {
                switch self {
                    case .individual: return 1
                    case .multiple(let namedActions): return namedActions.count
                }
            }
        }
        
        public enum Behaviour {
            case markAsDeleted(localOnly: Bool, ids: [Int64])
            case deleteFromDatabase([Int64])
            case cancelPendingSendJobs([Int64])
            case preparedRequest(Network.PreparedRequest<Void>)
        }
        
        public struct NamedAction {
            public let title: String
            public let isDefault: Bool
            public let accessibility: Accessibility
            let behaviours: [Behaviour]
            
            init(title: String, isDefault: Bool, accessibility: Accessibility, behaviours: [Behaviour]) {
                self.title = title
                self.isDefault = isDefault
                self.accessibility = accessibility
                self.behaviours = behaviours
            }
        }
        
        public let title: String
        public let body: String
        public let actions: Actions
        
        /// Collect the actions and construct a publisher which triggers each action before returning the result
        public func publisherForAction(at index: Int, using dependencies: Dependencies) -> AnyPublisher<Void, Error> {
            guard index >= 0, index < actions.count else {
                return Fail(error: StorageError.objectNotFound).eraseToAnyPublisher()
            }
            
            let behaviours: [Behaviour] = {
                switch actions {
                    case .individual(let actionBehaviours): return actionBehaviours
                    case .multiple(let namedActions): return namedActions[index].behaviours
                }
            }()
            
            var result: AnyPublisher<Void, Error> = Just(())
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
            
            behaviours.forEach { behaviour in
                switch behaviour {
                    case .cancelPendingSendJobs(let ids):
                        result = result.flatMapStorageWritePublisher(using: dependencies) { db, _ in
                            /// Cancel any `messageSend` jobs related to the message we are deleting
                            let jobs: [Job] = (try? Job
                                .filter(Job.Columns.variant == Job.Variant.messageSend)
                                .filter(ids.contains(Job.Columns.interactionId))
                                .fetchAll(db))
                                .defaulting(to: [])
                            
                            jobs.forEach { dependencies[singleton: .jobRunner].removePendingJob($0) }
                            
                            _ = try? Job.deleteAll(db, ids: jobs.compactMap { $0.id })
                        }
                    
                    case .markAsDeleted(let localOnly, let ids):
                        result = result.flatMapStorageWritePublisher(using: dependencies) { db, _ in
                            try Interaction
                                .fetchAll(db, ids: ids)
                                .map { $0.markingAsDeleted(localOnly: localOnly) }
                                .forEach { try $0.upserted(db) }
                        }
                        
                    case .deleteFromDatabase(let ids):
                        result = result.flatMapStorageWritePublisher(using: dependencies) { db, _ in
                            _ = try Interaction
                                .filter(ids: ids)
                                .deleteAll(db)
                        }
                        
                    case .preparedRequest(let preparedRequest):
                        result = result
                            .flatMap { _ in preparedRequest.send(using: dependencies) }
                            .map { _, _ in () }
                            .eraseToAnyPublisher()
                }
            }
            
            return result
        }
    }
}

public extension MessageViewModel.DeletionBehaviours {
    static func deletionActions(
        for cellViewModels: [MessageViewModel],
        with threadData: SessionThreadViewModel,
        using dependencies: Dependencies
    ) -> MessageViewModel.DeletionBehaviours? {
        enum SelectedMessageState {
            case pendingOnly
            case mixedPendingAndSent
            
            case incomingOnly
            case outgoingOnly
            case deletedOnly
            case controlMessageOnly
            
            case mixedIncomingAndOutgoing
            case mixedDeletedAndControlMessage
            case mixed
        }
        
        /// First determine the state of the selected messages
        let state: SelectedMessageState = {
            let allStates: Set<RecipientState.State> = Set(cellViewModels.map { $0.state })
            let allVariants: Set<Interaction.Variant> = Set(cellViewModels.map { $0.variant })
            let allHashes: Set<String> = Set(cellViewModels.compactMap { $0.serverHash ?? $0.openGroupServerMessageId.map { "\($0)" } })
            
            /// Determine the message types
            let deletedMessageVariants: Set<Interaction.Variant> = Set(Interaction.Variant.allCases.filter { $0.isDeletedMessage })
            let controlMessageVariants: Set<Interaction.Variant> = Set(Interaction.Variant.allCases.filter { $0.isInfoMessage })
            let isIncomingOnly: Bool = (allVariants == [.standardIncoming])
            let isOutgoingOnly: Bool = (allVariants == [.standardOutgoing])
            let isDeletedOnly: Bool = allVariants.subtracting(deletedMessageVariants).isEmpty
            let isControlMessageOnly: Bool = allVariants.subtracting(controlMessageVariants).isEmpty
            
            switch (isIncomingOnly, isOutgoingOnly, isDeletedOnly, isControlMessageOnly) {
                case (true, false, false, false): return .incomingOnly
                case (false, true, false, false):
                    /// Determine the message statuses (if a message doesn't have a `serverHash` or an `openGroupMessageId` then consider
                    /// it to be the same as a "pending" message)
                    let pendingStates: Set<RecipientState.State> = [.failed, .sending]
                    let sentStates: Set<RecipientState.State> = [.sent, .failedToSync, .syncing]
                    let isPendingOnly: Bool = allStates.subtracting(pendingStates).isEmpty
                    let isSentOnly: Bool = allStates.subtracting(sentStates).isEmpty
                  
                    switch (isPendingOnly, isSentOnly, allHashes.count == cellViewModels.count) {
                        case (true, false, _): return .pendingOnly
                        case (false, true, true): return .outgoingOnly
                        default: return .mixedPendingAndSent
                    }
                    
                case (false, false, true, false): return .deletedOnly
                case (false, false, false, true): return .controlMessageOnly
                default: break
            }
            
            /// Handle the combination types
            let isIncomingAndOutgoing: Bool = allVariants.subtracting([.standardIncoming, .standardOutgoing]).isEmpty
            let isDeletedAndControlMessageOnly: Bool = allVariants
                .subtracting(controlMessageVariants)
                .subtracting(deletedMessageVariants)
                .isEmpty
            
            switch (isIncomingAndOutgoing, isDeletedAndControlMessageOnly) {
                case (true, false): return .mixedIncomingAndOutgoing
                case (false, true): return .mixedDeletedAndControlMessage
                default: return .mixed
            }
        }()
        
        /// The user can only delete messages which are within the same group of states, either "pending" messages (`failed` & `sending`)
        /// or "sent" messages (all other states), selecting a combination of states is not valid and shouldn't allow deletion
        guard state != .mixedPendingAndSent else { return nil }
        
        /// The remaining deletion options are more complicated to determine
        return dependencies[singleton: .storage].read { [dependencies] db -> MessageViewModel.DeletionBehaviours? in
            let isAdmin: Bool = {
                switch threadData.threadVariant {
                    case .contact: return false
                    case .group, .legacyGroup: return (threadData.currentUserIsClosedGroupAdmin == true)
                    case .community:
                        guard
                            let server: String = threadData.openGroupServer,
                            let roomToken: String = threadData.openGroupRoomToken
                        else { return false }
                        
                        return dependencies[singleton: .openGroupManager].isUserModeratorOrAdmin(
                            db,
                            publicKey: threadData.currentUserSessionId,
                            for: roomToken,
                            on: server
                        )
                }
            }()
            
            switch (state, isAdmin) {
                /// Support local deletion only in all conversation types when all selcted messages are:
                /// • Pending messages
                /// • Deleted messages
                /// • Control messages
                case (.pendingOnly, _), (.deletedOnly, _), (.controlMessageOnly, _), (.mixedDeletedAndControlMessage, _):
                    return MessageViewModel.DeletionBehaviours(
                        title: "deleteMessage"
                            .putNumber(cellViewModels.count)
                            .localized(),
                        body: (cellViewModels.count == 1 ?
                            "deleteMessageDescriptionDevice".localized() :
                            "deleteMessagesDescriptionDevice".localized()
                        ),
                        actions: .individual([
                            .cancelPendingSendJobs(cellViewModels.map { $0.id }),
                            .deleteFromDatabase(cellViewModels.map { $0.id })
                        ])
                    )
                    
                /// Support local "mark as deleted" in all conversation types when all selcted messages are:
                /// • Incoming messages (when not an admin)
                case (.incomingOnly, false):
                    return MessageViewModel.DeletionBehaviours(
                        title: "deleteMessage"
                            .putNumber(cellViewModels.count)
                            .localized(),
                        body: (cellViewModels.count == 1 ?
                            "deleteMessageDescriptionDevice".localized() :
                            "deleteMessagesDescriptionDevice".localized()
                        ),
                        actions: .individual([
                            .cancelPendingSendJobs(cellViewModels.map { $0.id }),
                            .markAsDeleted(localOnly: true, ids: cellViewModels.map { $0.id })
                        ])
                    )
                    
                /// Support either local deletion or network deletion when:
                /// • All messages were sent by the current user; or
                /// • The current user is an admin
                case (.outgoingOnly, _), (.incomingOnly, true), (.mixedIncomingAndOutgoing, true):
                    return MessageViewModel.DeletionBehaviours(
                        title: "deleteMessage"
                            .putNumber(cellViewModels.count)
                            .localized(),
                        body: (cellViewModels.count == 1 ?
                            "deleteMessageConfirm".localized() :
                            "deleteMessagesConfirm".localized()
                        ),
                        actions: .multiple([
                            NamedAction(
                                title: "deleteMessageDeviceOnly".localized(),
                                isDefault: !isAdmin, /// Default to "delete for me" for non-admins
                                accessibility: Accessibility(identifier: "Delete for me"),
                                behaviours: [
                                    .cancelPendingSendJobs(cellViewModels.map { $0.id }),
                                    .markAsDeleted(localOnly: true, ids: cellViewModels.map { $0.id })
                                ]
                            ),
                            NamedAction(
                                title: (threadData.threadIsNoteToSelf ?
                                    "deleteMessageDevicesAll".localized() :
                                    "deleteMessageEveryone".localized()
                                ),
                                isDefault: isAdmin, /// Default to "delete for everyone" for admins
                                accessibility: Accessibility(identifier: "Delete for everyone"),
                                behaviours: try {
                                    /// The non-local deletion behaviours differ depending on the type of conversation
                                    switch (threadData.threadVariant, isAdmin) {
                                        /// **Note to Self or Contact Conversation**
                                        /// Delete from all participant devices via an `UnsendRequest` (these will trigger their own sync messages)
                                        /// Delete from the current users swarm
                                        /// Delete from the current device
                                        case (.contact, _):
                                            let serverHashes: [String] = cellViewModels.compactMap { $0.serverHash }
                                            let unsendRequests: [Network.PreparedRequest<Void>] = try cellViewModels.map { model in
                                                try MessageSender.preparedSend(
                                                    db,
                                                    message: UnsendRequest(
                                                        timestamp: UInt64(model.timestampMs),
                                                        author: (model.variant == .standardOutgoing ?
                                                            threadData.currentUserSessionId :
                                                            model.authorId
                                                        )
                                                    )
                                                    .with(
                                                        expiresInSeconds: model.expiresInSeconds,
                                                        expiresStartedAtMs: model.expiresStartedAtMs
                                                    ),
                                                    to: .contact(publicKey: model.threadId),
                                                    namespace: .default,
                                                    interactionId: nil,
                                                    fileIds: [],
                                                    using: dependencies
                                                )
                                            }
                                            
                                            /// Batch requests have a limited number of subrequests so make sure to chunk
                                            /// the unsend requests accordingly
                                            return [.cancelPendingSendJobs(cellViewModels.map { $0.id })]
                                                .appending(
                                                    contentsOf: try unsendRequests
                                                        .chunked(by: Network.BatchRequest.childRequestLimit)
                                                        .map { unsendRequestChunk in
                                                                .preparedRequest(
                                                                    try SnodeAPI.preparedBatch(
                                                                        requests: unsendRequestChunk,
                                                                        requireAllBatchResponses: false,
                                                                        swarmPublicKey: threadData.threadId,
                                                                        using: dependencies
                                                                    ).map { _, _ in () }
                                                                )
                                                        }
                                                )
                                                .appending(
                                                    .preparedRequest(
                                                        try SnodeAPI.preparedDeleteMessages(
                                                            serverHashes: serverHashes,
                                                            requireSuccessfulDeletion: false,
                                                            authMethod: try Authentication.with(
                                                                db,
                                                                swarmPublicKey: threadData.currentUserSessionId,
                                                                using: dependencies
                                                            ),
                                                            using: dependencies
                                                        )
                                                        .map { _, _ in () }
                                                    )
                                                )
                                                .appending(.markAsDeleted(localOnly: false, ids: cellViewModels.map { $0.id }))
                                            
                                        /// **Legacy Group Conversation**
                                        /// Delete from all participant devices via an `UnsendRequest`
                                        /// Delete from the current device
                                        ///
                                        /// **Note:** We **cannot** delete from the legacy group swarm
                                        case (.legacyGroup, _):
                                            let unsendRequests: [Network.PreparedRequest<Void>] = try cellViewModels.map { model in
                                                try MessageSender.preparedSend(
                                                    db,
                                                    message: UnsendRequest(
                                                        timestamp: UInt64(model.timestampMs),
                                                        author: (model.variant == .standardOutgoing ?
                                                            threadData.currentUserSessionId :
                                                            model.authorId
                                                        )
                                                    )
                                                    .with(
                                                        expiresInSeconds: model.expiresInSeconds,
                                                        expiresStartedAtMs: model.expiresStartedAtMs
                                                    ),
                                                    to: .closedGroup(groupPublicKey: model.threadId),
                                                    namespace: .legacyClosedGroup,
                                                    interactionId: nil,
                                                    fileIds: [],
                                                    using: dependencies
                                                )
                                            }
                                            
                                            /// Batch requests have a limited number of subrequests so make sure to chunk
                                            /// the unsend requests accordingly
                                            return [.cancelPendingSendJobs(cellViewModels.map { $0.id })]
                                                .appending(
                                                    contentsOf: try unsendRequests
                                                        .chunked(by: Network.BatchRequest.childRequestLimit)
                                                        .map { unsendRequestChunk in
                                                                .preparedRequest(
                                                                    try SnodeAPI.preparedBatch(
                                                                        requests: unsendRequestChunk,
                                                                        requireAllBatchResponses: false,
                                                                        swarmPublicKey: threadData.threadId,
                                                                        using: dependencies
                                                                    ).map { _, _ in () }
                                                                )
                                                        }
                                                )
                                                .appending(.markAsDeleted(localOnly: false, ids: cellViewModels.map { $0.id }))
                                            
                                        /// **Group Conversation for Non Admin**
                                        /// Delete from all participant devices via an `GroupUpdateDeleteMemberContentMessage`
                                        /// Delete from the current device
                                        case (.group, false):
                                            let serverHashes: [String] = cellViewModels.compactMap { $0.serverHash }
                                            
                                            return [
                                                .cancelPendingSendJobs(cellViewModels.map { $0.id }),
                                                /// **Note:** No signature for member delete content
                                                .preparedRequest(try MessageSender
                                                    .preparedSend(
                                                        db,
                                                        message: GroupUpdateDeleteMemberContentMessage(
                                                            memberSessionIds: [],
                                                            messageHashes: serverHashes,
                                                            sentTimestamp: dependencies[cache: .snodeAPI].currentOffsetTimestampMs(),
                                                            authMethod: nil,
                                                            using: dependencies
                                                        ),
                                                        to: .closedGroup(groupPublicKey: threadData.threadId),
                                                        namespace: .groupMessages,
                                                        interactionId: nil,
                                                        fileIds: [],
                                                        using: dependencies
                                                    )),
                                                .markAsDeleted(localOnly: false, ids: cellViewModels.map { $0.id })
                                            ]
                                            
                                        /// **Group Conversation for Admin**
                                        /// Delete from all participant devices via an `GroupUpdateDeleteMemberContentMessage`
                                        /// Delete from the group swarm
                                        /// Delete from the current device
                                        case (.group, true):
                                            guard
                                                let ed25519SecretKey: Data = try? ClosedGroup
                                                    .filter(id: threadData.threadId)
                                                    .select(.groupIdentityPrivateKey)
                                                    .asRequest(of: Data.self)
                                                    .fetchOne(db)
                                            else {
                                                Log.error("[ConversationViewModel] Failed to retrieve groupIdentityPrivateKey when trying to delete messages from group.")
                                                throw StorageError.objectNotFound
                                            }
                                            
                                            let serverHashes: [String] = cellViewModels.compactMap { $0.serverHash }
                                            
                                            return [
                                                .cancelPendingSendJobs(cellViewModels.map { $0.id }),
                                                .preparedRequest(try MessageSender
                                                    .preparedSend(
                                                        db,
                                                        message: GroupUpdateDeleteMemberContentMessage(
                                                            memberSessionIds: [],
                                                            messageHashes: serverHashes,
                                                            sentTimestamp: dependencies[cache: .snodeAPI].currentOffsetTimestampMs(),
                                                            authMethod: Authentication.groupAdmin(
                                                                groupSessionId: SessionId(.group, hex: threadData.threadId),
                                                                ed25519SecretKey: Array(ed25519SecretKey)
                                                            ),
                                                            using: dependencies
                                                        ),
                                                        to: .closedGroup(groupPublicKey: threadData.threadId),
                                                        namespace: .groupMessages,
                                                        interactionId: nil,
                                                        fileIds: [],
                                                        using: dependencies
                                                    )),
                                                .preparedRequest(try SnodeAPI
                                                    .preparedDeleteMessages(
                                                        serverHashes: serverHashes,
                                                        requireSuccessfulDeletion: false,
                                                        authMethod: Authentication.groupAdmin(
                                                            groupSessionId: SessionId(.group, hex: threadData.threadId),
                                                            ed25519SecretKey: Array(ed25519SecretKey)
                                                        ),
                                                        using: dependencies
                                                    )
                                                        .map { _, _ in () }),
                                                .markAsDeleted(localOnly: false, ids: cellViewModels.map { $0.id })
                                            ]
                                            
                                        /// **Community Conversation**
                                        /// Delete from the SOGS
                                        /// Delete from the current device
                                        case (.community, _):
                                            guard
                                                let server: String = threadData.openGroupServer,
                                                let roomToken: String = threadData.openGroupRoomToken
                                            else {
                                                Log.error("[ConversationViewModel] Failed to retrieve community info when trying to delete messages.")
                                                throw StorageError.objectNotFound
                                            }
                                            
                                            let deleteRequests: [Network.PreparedRequest] = try cellViewModels
                                                .compactMap { $0.openGroupServerMessageId }
                                                .map { messageId in
                                                    try OpenGroupAPI
                                                        .preparedMessageDelete(
                                                            db,
                                                            id: messageId,
                                                            in: roomToken,
                                                            on: server,
                                                            using: dependencies
                                                        )
                                                }
                                            
                                            /// Batch requests have a limited number of subrequests so make sure to chunk
                                            /// the unsend requests accordingly
                                            return [.cancelPendingSendJobs(cellViewModels.map { $0.id })]
                                                .appending(
                                                    contentsOf: try deleteRequests
                                                        .chunked(by: Network.BatchRequest.childRequestLimit)
                                                        .map { deleteRequestsChunk in
                                                                .preparedRequest(
                                                                    try OpenGroupAPI.preparedBatch(
                                                                        db,
                                                                        server: server,
                                                                        requests: deleteRequestsChunk,
                                                                        using: dependencies
                                                                    )
                                                                    .map { _, _ in () }
                                                                )
                                                        }
                                                )
                                                .appending(.deleteFromDatabase(cellViewModels.map { $0.id }))
                                    }
                                }()
                            )
                        ])
                    )
                    
                /// These remaining cases are not supported
                case (.mixedPendingAndSent, _), (.mixed, _), (.mixedIncomingAndOutgoing, false): return nil
            }
        }
    }
}
