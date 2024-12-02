// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public protocol BatchRequestChildRetrievable {
    var requests: [Network.BatchRequest.Child] { get }
}

public extension Network {
    struct BatchRequest: Encodable, BatchRequestChildRetrievable {
        /// The servers currently have a limit for the number of requests a `BatchRequest` can have, when using this we should avoid
        /// trying to make calls that exceed this limit as they will fail
        public static let childRequestLimit: Int = 20
        
        public enum CodingKeys: String, CodingKey {
            // Storage Server keys
            case requests
        }
        
        let requestsKey: CodingKeys?
        public let requests: [Child]
        
        public init(requestsKey: CodingKeys? = nil, requests: [any ErasedPreparedRequest]) {
            self.requestsKey = requestsKey
            self.requests = requests.map { Child(request: $0) }
            
            if requests.count > BatchRequest.childRequestLimit {
                Log.warn("[BatchRequest] Constructed request with \(requests.count) subrequests when the limit is \(BatchRequest.childRequestLimit)")
            }
        }
        
        // MARK: - Encodable
        
        public func encode(to encoder: Encoder) throws {
            switch requestsKey {
                case .requests:
                    var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)

                    try container.encode(requests, forKey: .requests)
                    
                case .none:
                    var container: SingleValueEncodingContainer = encoder.singleValueContainer()

                    try container.encode(requests)
            }
        }
        
        // MARK: - BatchRequest.Child
        
        public struct Child: Encodable {
            public enum Variant {
                case unsupported
                case sogs
                case storageServer
            }
            
            enum CodingKeys: String, CodingKey {
                case method
                
                // SOGS keys
                case path
                case headers
                case json
                case b64
                case bytes
                
                // Storage Server keys
                case params
            }
            
            let request: any ErasedPreparedRequest
            
            public func encode(to encoder: Encoder) throws {
                try request.encodeForBatchRequest(to: encoder)
            }
        }
    }
}
