// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

// MARK: - ConfigColumnAssignment

public struct ConfigColumnAssignment {
    var column: ColumnExpression
    var assignment: ColumnAssignment
    
    init(
        column: ColumnExpression,
        assignment: ColumnAssignment
    ) {
        self.column = column
        self.assignment = assignment
    }
}

// MARK: - ColumnExpression

extension ColumnExpression {
    public func set(to value: (any SQLExpressible)?) -> ConfigColumnAssignment {
        ConfigColumnAssignment(column: self, assignment: self.set(to: value))
    }
}

// MARK: - QueryInterfaceRequest

public extension QueryInterfaceRequest where RowDecoder: FetchableRecord & TableRecord {
    
    // MARK: -- updateAll
    
    @discardableResult
    func updateAll(
        _ db: Database,
        _ assignments: ConfigColumnAssignment...
    ) throws -> Int {
        return try updateAll(db, assignments)
    }
    
    @discardableResult
    func updateAll(
        _ db: Database,
        _ assignments: [ConfigColumnAssignment]
    ) throws -> Int {
        return try self.updateAll(db, assignments.map { $0.assignment })
    }
    
    @discardableResult
    func updateAllAndConfig(
        _ db: Database,
        calledFromConfig: Bool = false,
        _ assignments: ConfigColumnAssignment...
    ) throws -> Int {
        return try updateAllAndConfig(db, calledFromConfig: calledFromConfig, assignments)
    }
    
    @discardableResult
    func updateAllAndConfig(
        _ db: Database,
        calledFromConfig: Bool = false,
        _ assignments: [ConfigColumnAssignment]
    ) throws -> Int {
        let targetAssignments: [ColumnAssignment] = assignments.map { $0.assignment }
        
        // Before we do anything custom make sure the changes actually do need to be synced
        guard LibSession.assignmentsRequireConfigUpdate(assignments) else {
            return try self.updateAll(db, targetAssignments)
        }
        
        return try self.updateAndFetchAllAndUpdateConfig(db, calledFromConfig: calledFromConfig, assignments).count
    }
    
    // MARK: -- updateAndFetchAll
    
    @discardableResult
    func updateAndFetchAllAndUpdateConfig(
        _ db: Database,
        calledFromConfig: Bool = false,
        _ assignments: ConfigColumnAssignment...
    ) throws -> [RowDecoder] {
        return try updateAndFetchAllAndUpdateConfig(db, calledFromConfig: calledFromConfig, assignments)
    }
    
    @discardableResult
    func updateAndFetchAllAndUpdateConfig(
        _ db: Database,
        calledFromConfig: Bool = false,
        _ assignments: [ConfigColumnAssignment]
    ) throws -> [RowDecoder] {
        // First perform the actual updates
        let updatedData: [RowDecoder] = try self.updateAndFetchAll(db, assignments.map { $0.assignment })
        
        // Then check if any of the changes could affect the config
        guard
            !calledFromConfig &&
                LibSession.assignmentsRequireConfigUpdate(assignments)
        else { return updatedData }
        
        defer {
            // If we changed a column that requires a config update then we may as well automatically
            // enqueue a new config sync job once the transaction completes (but only enqueue it once
            // per transaction - doing it more than once is pointless)
            let userPublicKey: String = getUserHexEncodedPublicKey(db)
            
            db.afterNextTransactionNestedOnce(dedupeId: LibSession.syncDedupeId(userPublicKey)) { db in
                ConfigurationSyncJob.enqueue(db, publicKey: userPublicKey)
            }
        }
        
        // Update the config dump state where needed
        switch self {
            case is QueryInterfaceRequest<Contact>:
                return try LibSession.updatingContacts(db, updatedData)
                
            case is QueryInterfaceRequest<Profile>:
                return try LibSession.updatingProfiles(db, updatedData)
                
            case is QueryInterfaceRequest<SessionThread>:
                return try LibSession.updatingThreads(db, updatedData)
                
            default: return updatedData
        }
    }
}
