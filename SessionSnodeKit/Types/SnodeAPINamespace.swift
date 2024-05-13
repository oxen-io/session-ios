// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public extension SnodeAPI {
    enum Namespace: Int, Codable, Hashable, CustomStringConvertible {
        case `default` = 0
        
        case configUserProfile = 2
        case configContacts = 3
        case configConvoInfoVolatile = 4
        case configUserGroups = 5
        case configClosedGroupInfo = 11
        
        case legacyClosedGroup = -10
        
        /// This is used when we somehow receive a message from an unknown namespace (shouldn't really be possible)
        case unknown = -9999989
        
        /// This is a convenience namespace used to represent all other namespaces for specific API calls
        case all = -9999990
        
        // MARK: Variables
        
        var requiresReadAuthentication: Bool {
            switch self {
                // Legacy closed groups don't support authenticated retrieval
                case .legacyClosedGroup: return false
                default: return true
            }
        }
        
        var requiresWriteAuthentication: Bool {
            switch self {
                // Legacy closed groups don't support authenticated storage
                case .legacyClosedGroup: return false
                default: return true
            }
        }
        
        /// This flag indicates whether we should provide a `lastHash` when retrieving messages from the specified
        /// namespace, when `true` we will only receive messages added since the provided `lastHash`, otherwise
        /// we will retrieve **all** messages from the namespace
        public var shouldFetchSinceLastHash: Bool { true }
        
        /// This flag indicates whether we should dedupe messages from the specified namespace, when `true` we will
        /// attempt to `insert` a `SnodeReceivedMessageInfo` record (which will fail if we had already processed this
        /// message previously), when `false` we will still `upsert` a record so we don't run into the unique constraint allowing
        /// re-processing of a previously processed message
        public var shouldDedupeMessages: Bool {
            switch self {
                case .`default`, .legacyClosedGroup: return true
                    
                case .configUserProfile, .configContacts,
                    .configConvoInfoVolatile, .configUserGroups,
                    .configClosedGroupInfo, .unknown, .all:
                    return false
            }
        }
        
        var verificationString: String {
            switch self {
                case .`default`: return ""
                case .all: return "all"
                default: return "\(self.rawValue)"
            }
        }
        
        public var isConfigNamespace: Bool {
            switch self {
                case .configUserProfile, .configContacts, .configConvoInfoVolatile, .configUserGroups,
                    .configClosedGroupInfo:
                    return true
                    
                case .`default`, .legacyClosedGroup, .unknown, .all:
                    return false
            }
        }
        
        /// This value defines the order that the SharedConfigMessages should be processed in, while we re-process config
        /// messages every time we poll this will prevent an edge-case where data/logic between different config messages
        /// could be dependant on each other (eg. there could be `convoInfoVolatile` data related to a new conversation
        /// which hasn't been created yet because it's associated `contacts`/`userGroups` message hasn't yet been
        /// processed (without this we would have to wait until the next poll for it to be processed correctly)
        public var processingOrder: Int {
            switch self {
                case .configUserProfile, .configContacts: return 0
                case .configUserGroups, .configClosedGroupInfo: return 1
                case .configConvoInfoVolatile: return 2
                    
                case .`default`, .legacyClosedGroup, .unknown, .all:
                    return 3
            }
        }
        
        /// Flag which indicates whether messages from this namespace should be handled synchronously as part of the polling process
        /// or whether they can be scheduled to be handled asynchronously
        public var shouldHandleSynchronously: Bool {
            switch self {
                case .`default`, .legacyClosedGroup, .configUserProfile, .configContacts,
                    .configConvoInfoVolatile, .configUserGroups, .configClosedGroupInfo,
                    .unknown, .all:
                    return false
            }
        }
        
        /// When performing a batch request we want to try to use the amount of data available in the response as effectively as possible
        /// this priority allows us to split the response effectively between the number of namespaces we are requesting from where
        /// namespaces with the same priority will be given the same response size divider, for example:
        /// ```
        /// default          = 1
        /// config1, config2 = 2
        /// config3, config4 = 3
        ///
        /// Response data split:
        ///  _____________________________
        /// |                             |
        /// |           default           |
        /// |_____________________________|
        /// |         |         | config3 |
        /// | config1 | config2 | config4 |
        /// |_________|_________|_________|
        ///
        var batchRequestSizePriority: Int64 {
            switch self {
                case .`default`, .legacyClosedGroup: return 10
                    
                case .configUserProfile, .configContacts,
                    .configConvoInfoVolatile, .configUserGroups,
                    .configClosedGroupInfo, .unknown, .all:
                    return 1
            }
        }
        
        static func maxSizeMap(for namespaces: [Namespace]) -> [Namespace: Int64] {
            var lastSplit: Int64 = 1
            let namespacePriorityGroups: [Int64: [Namespace]] = namespaces
                .grouped { $0.batchRequestSizePriority }
            let lowestPriority: Int64 = (namespacePriorityGroups.keys.min() ?? 1)
            
            return namespacePriorityGroups
                .map { $0 }
                .sorted(by: { lhs, rhs -> Bool in lhs.key > rhs.key })
                .flatMap { priority, namespaces -> [(namespace: Namespace, maxSize: Int64)] in
                    lastSplit *= Int64(namespaces.count + (priority == lowestPriority ? 0 : 1))

                    return namespaces.map { ($0, lastSplit) }
                }
                .reduce(into: [:]) { result, next in
                    result[next.namespace] = -next.maxSize
                }
        }
        
        // MARK: - CustomStringConvertible
        
        public var description: String {
            switch self {
                case .`default`: return "default"
                case .configUserProfile: return "configUserProfile"
                case .configContacts: return "configContacts"
                case .configConvoInfoVolatile: return "configConvoInfoVolatile"
                case .configUserGroups: return "configUserGroups"
                case .configClosedGroupInfo: return "configClosedGroupInfo"
                case .legacyClosedGroup: return "legacyClosedGroup"
                
                case .unknown: return "unknown"
                case .all: return "all"
            }
        }
    }
}
