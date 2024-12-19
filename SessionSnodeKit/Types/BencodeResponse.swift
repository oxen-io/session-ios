// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public struct BencodeResponse<T: Decodable> {
    public let info: T
    public let data: Data?
}

extension BencodeResponse: Decodable {
    public init(from decoder: Decoder) throws {
        var container: UnkeyedDecodingContainer = try decoder.unkeyedContainer()
        
        /// The first element will be the request info
        info = try {
            /// First try to decode it directly
            if let info: T = try? container.decode(T.self) {
                return info
            }
            
            /// If that failed then we need to reset the container and try decode it as a JSON string
            container = try decoder.unkeyedContainer()
            let infoString: String = try container.decode(String.self)
            let infoData: Data = try infoString.data(using: .ascii) ?? { throw NetworkError.parsingFailed }()
            
            /// Pass the `dependencies` through to the `JSONDecoder` if we have them, if
            /// we don't then it's the responsibility of the decoding type to throw when `dependencies`
            /// isn't present but is required
            let jsonDecoder: JSONDecoder = (decoder.dependencies.map { JSONDecoder(using: $0) } ?? JSONDecoder())
            return try jsonDecoder.decode(T.self, from: infoData)
        }()
        
        
        /// The second element (if present) will be the response data and should just
        guard container.count == 2 else {
            data = nil
            return
        }
        
        data = try container.decode(Data.self)
    }
}

extension BencodeResponse: Equatable where T: Equatable {}
extension BencodeResponse: Encodable where T: Encodable {}
