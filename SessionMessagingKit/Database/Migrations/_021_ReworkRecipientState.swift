// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

enum _021_ReworkRecipientState: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "ReworkRecipientState"
    static let needsConfigSync: Bool = false
    static let minExpectedRunDuration: TimeInterval = 0.1
    static var requirements: [MigrationRequirement] = []
    static let fetchedTables: [(TableRecord & FetchableRecord).Type] = []
    static let createdOrAlteredTables: [(TableRecord & FetchableRecord).Type] = []
    static let droppedTables: [(TableRecord & FetchableRecord).Type] = [
        _001_InitialSetupMigration.LegacyRecipientState.self
    ]
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        typealias LegacyState = _001_InitialSetupMigration.LegacyRecipientState
        
        /// First we need to add the new columns to the `Interaction` table
        try db.alter(table: Interaction.self) { t in
            t.add(.state, .integer)
                .notNull()
                .indexed()                                            // Quicker querying
                .defaults(to: Interaction.State.sending)
            t.add(.recipientReadTimestampMs, .integer)
            t.add(.mostRecentFailureText, .text)
        }
        
        /// As part of this change we have added two new `State` types: `deleted` and `localOnly` which
        /// will simplify some querying and logic for behaviours which have multiple `Interaction.Variant` cases
        try Interaction
            .filter(Interaction.Columns.variant == Interaction.Variant.standardIncomingDeleted)
            .updateAll(db, Interaction.Columns.state.set(to: Interaction.State.deleted))
        try Interaction
            .filter(Interaction.Variant.variantsWhichAreLocalOnly.contains(Interaction.Columns.variant))
            .updateAll(db, Interaction.Columns.state.set(to: Interaction.State.localOnly))
        
        /// Part of the logic in the `FailedMessageSendsJob` is to update all pending sends to be in the "failed" state but
        /// this migration will run before that gets the chance to so we need to trigger the same transition here to ensure that
        /// when we move the data from the `LegacyState` across to the `Interaction` it's already in the correct state
        try LegacyState
            .filter(LegacyState.Columns.state == LegacyState.State.sending)
            .updateAll(db, LegacyState.Columns.state.set(to: LegacyState.State.failed))
        try LegacyState
            .filter(LegacyState.Columns.state == LegacyState.State.syncing)
            .updateAll(db, LegacyState.Columns.state.set(to: LegacyState.State.failedToSync))
        
        /// In the old logic there would be a `LegacyState` for every participant in a `ClosedGroup` conversation and
        /// there were special rules around how to merge the states for display purposes so we want to replicate that
        /// behaviour here (the default `sending` state will be handled on the column itself so we only need to deal with
        /// other behaviours here)
        let recipientStates: [LegacyState] = try LegacyState.fetchAll(db)
            .grouped(by: \.interactionId)
            .reduce(into: []) { result, next in
                guard next.value.count > 1 else {
                    result.append(contentsOf: next.value)
                    return
                }
                
                // If there is a single "failed" state, consider this message "failed"
                if let legacyState: LegacyState = next.value.first(where: { $0.state == .failed }) {
                    result.append(legacyState)
                    return
                }
                
                // If there is a single "failedToSync" state, consider this message "failedToSync"
                if let legacyState: LegacyState = next.value.first(where: { $0.state == .failedToSync }) {
                    result.append(legacyState)
                    return
                }
                
                // There isn't really a simple way to combine other combinations (the query would
                // pick the smallest, and there was UI logic which would just default to "sent") so
                // just go with the smallest
                result.append(next.value.sorted(by: { $0.state.rawValue < $1.state.rawValue })[0])
            }
        
        /// Group the `recipientStates` by each of their properties so we can bulk update their associated
        /// interactions
        let recipientStatesByState: [LegacyState.State: [LegacyState]] = recipientStates
            .grouped(by: \.state)
        let recipientStatesByMostRecentFailureText: [String?: [LegacyState]] = recipientStates
            .filter { legacyState in legacyState.mostRecentFailureText != nil } // Filter out nulls
            .filter { legacyState in legacyState.state != .sent } // No need to keep failure text after send
            .grouped(by: \.mostRecentFailureText)
        
        /// Add the `state` and `mostRecentFailureText` values directly to their interactions
        try recipientStatesByState.forEach { legacyState, states in
            try Interaction
                .filter(ids: states.map { $0.interactionId })
                .updateAll(db, Interaction.Columns.state.set(to: legacyState.interactionState))
        }
        try recipientStatesByMostRecentFailureText.forEach { failureText, states in
            try Interaction
                .filter(ids: states.map { $0.interactionId })
                .updateAll(db, Interaction.Columns.mostRecentFailureText.set(to: failureText))
        }
        
        /// Any interactions which didn't have a `LegacyState` or a `MessageSendJob` should be considered `sent` (as
        /// the old UI behaviour was to render any messages without a `LegacyState` as `sent`)
        let interactionIdsWithMessageSendJobs: Set<Int64> = try Job
            .filter(Job.Columns.variant == Job.Variant.messageSend)
            .filter(Job.Columns.interactionId != nil)
            .select(.interactionId)
            .asRequest(of: Int64.self)
            .fetchSet(db)
        let interactionIdsToExclude: Set<Int64> = Set(recipientStates.map { $0.interactionId })
            .union(interactionIdsWithMessageSendJobs)
        try Interaction
            .filter(!interactionIdsToExclude.contains(Interaction.Columns.id))
            .updateAll(db, Interaction.Columns.state.set(to: Interaction.State.sent))
        
        /// The timestamps are unlikely to have duplicates so we just need to add those individually
        try recipientStates
            .filter { $0.readTimestampMs != nil }
            .forEach { state in
                try Interaction
                    .filter(id: state.interactionId)
                    .updateAll(db, Interaction.Columns.recipientReadTimestampMs.set(to: state.readTimestampMs))
            }
        
        /// Finally we can drop the old recipient states table
        try db.drop(table: _001_InitialSetupMigration.LegacyRecipientState.self)
        
        Storage.update(progress: 1, for: self, in: target) // In case this is the last migration
    }
}

private extension _001_InitialSetupMigration.LegacyRecipientState.State {
    var interactionState: Interaction.State {
        switch self {
            case .sending: return .sending
            case .failed: return .failed
            case .skipped: return .failed    // Have removed the 'skipped' status
            case .sent: return .sent
            case .failedToSync: return .failedToSync
            case .syncing: return .syncing
        }
    }
}
