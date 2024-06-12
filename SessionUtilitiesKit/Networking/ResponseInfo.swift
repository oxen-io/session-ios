// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public protocol ResponseInfoType: Decodable {
    var code: Int { get }
    var headers: [String: String] { get }
}

public extension Network {
    struct ResponseInfo: ResponseInfoType {
        public let code: Int
        public let headers: [String: String]
        
        public init(code: Int, headers: [String: String] = [:]) {
            self.code = code
            self.headers = headers
        }
    }
}
