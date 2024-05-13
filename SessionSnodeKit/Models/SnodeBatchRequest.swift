// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

internal extension SnodeAPI {
    struct BatchRequest: Encodable {
        let requests: [Child]
        
        init(requests: [Info]) {
            self.requests = requests.map { $0.child }
        }
        
        // MARK: - BatchRequest.Info
        
        struct Info {
            public let responseType: Decodable.Type
            fileprivate let child: Child
            
            public init<T: Encodable, R: Codable>(request: SnodeRequest<T>, responseType: R.Type) {
                self.child = Child(request: request)
                self.responseType = Network.BatchSubResponse<R>.self
            }
            
            public init<T: Encodable>(request: SnodeRequest<T>) {
                self.init(
                    request: request,
                    responseType: NoResponse.self
                )
            }
        }
        
        // MARK: - BatchRequest.Child
        
        struct Child: Encodable {
            enum CodingKeys: String, CodingKey {
                case method
                case params
            }
            
            let endpoint: SnodeAPI.Endpoint
            
            /// The `jsonBodyEncoder` is used to avoid having to make `BatchSubRequest` a generic type (haven't found
            /// a good way to keep `BatchSubRequest` encodable using protocols unfortunately so need this work around)
            private let jsonBodyEncoder: ((inout KeyedEncodingContainer<CodingKeys>, CodingKeys) throws -> ())?
            
            init<T: Encodable>(request: SnodeRequest<T>) {
                self.endpoint = request.endpoint
                
                self.jsonBodyEncoder = { [body = request.body] container, key in
                    try container.encode(body, forKey: key)
                }
            }
            
            public func encode(to encoder: Encoder) throws {
                var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)

                try container.encode(endpoint.path, forKey: .method)
                try jsonBodyEncoder?(&container, .params)
            }
        }
    }
}
