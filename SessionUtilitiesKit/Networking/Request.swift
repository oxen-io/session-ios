import Foundation

// MARK: - Convenience Types

public struct Empty: Codable {
    public init() {}
}

public typealias NoBody = Empty
public typealias NoResponse = Empty

public protocol EndpointType: Hashable {
    static var name: String { get }
    static var batchRequestVariant: HTTP.BatchRequest.Child.Variant { get }
    static var excludedSubRequestHeaders: [HTTPHeader] { get }
    
    var path: String { get }
}

public extension EndpointType {
    static var batchRequestVariant: HTTP.BatchRequest.Child.Variant { .unsupported }
    static var excludedSubRequestHeaders: [HTTPHeader] { [] }
}

// MARK: - Request

public struct Request<T: Encodable, Endpoint: EndpointType> {
    public let method: HTTPMethod
    public let target: any RequestTarget
    public let endpoint: Endpoint
    public let headers: [HTTPHeader: String]
    /// This is the body value sent during the request
    ///
    /// **Warning:** The `bodyData` value should be used to when making the actual request instead of this as there
    /// is custom handling for certain data types
    public let body: T?
    
    // MARK: - Initialization

    public init(
        method: HTTPMethod = .get,
        endpoint: Endpoint,
        target: any RequestTarget,
        headers: [HTTPHeader: String] = [:],
        body: T? = nil
    ) {
        self.method = method
        self.endpoint = endpoint
        self.target = target
        self.headers = headers
        self.body = body
    }
    
    // MARK: - Internal Methods
    
    private func bodyData(using dependencies: Dependencies) throws -> Data? {
        // Note: Need to differentiate between JSON, b64 string and bytes body values to ensure they are
        // encoded correctly so the server knows how to handle them
        switch body {
            case let bodyString as String:
                // The only acceptable string body is a base64 encoded one
                guard let encodedData: Data = Data(base64Encoded: bodyString) else {
                    throw HTTPError.parsingFailed
                }
                
                return encodedData
                
            case let bodyBytes as [UInt8]:
                return Data(bodyBytes)
                
            default:
                // Having no body is fine so just return nil
                guard let body: T = body else { return nil }

                return try JSONEncoder(using: dependencies).encode(body)
        }
    }
    
    // MARK: - Request Generation
    
    public func generateUrlRequest(using dependencies: Dependencies) throws -> URLRequest {
        guard let url: URL = target.url else { throw HTTPError.invalidURL }
        
        var urlRequest: URLRequest = URLRequest(url: url)
        urlRequest.httpMethod = method.rawValue
        urlRequest.allHTTPHeaderFields = headers.toHTTPHeaders()
        urlRequest.httpBody = try bodyData(using: dependencies)
        
        return urlRequest
    }
}
