// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine

public enum HTTP {
    private struct Certificates {
        let isValid: Bool
        let certificates: [SecCertificate]
    }
    
    private static let seedNodeURLSession = URLSession(configuration: .ephemeral, delegate: seedNodeURLSessionDelegate, delegateQueue: nil)
    private static let seedNodeURLSessionDelegate = SeedNodeURLSessionDelegateImplementation()
    private static let snodeURLSession = URLSession(configuration: .ephemeral, delegate: snodeURLSessionDelegate, delegateQueue: nil)
    private static let snodeURLSessionDelegate = SnodeURLSessionDelegateImplementation()

    // MARK: - Certificates
    
    /// **Note:** These certificates will need to be regenerated and replaced at the start of April 2025, iOS has a restriction after iOS 13
    /// where certificates can have a maximum lifetime of 825 days (https://support.apple.com/en-au/HT210176) as a result we
    /// can't use the 10 year certificates that the other platforms use
    private static let storageSeedCertificates: Atomic<Certificates> = {
        let certFileNames: [String] = [
            "seed1-2023-2y",
            "seed2-2023-2y",
            "seed3-2023-2y"
        ]
        let paths: [String] = certFileNames.compactMap { Bundle.main.path(forResource: $0, ofType: "der") }
        let certData: [Data] = paths.compactMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
        let certificates: [SecCertificate] = certData.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        
        guard certificates.count == certFileNames.count else {
            return Atomic(Certificates(isValid: false, certificates: []))
        }
        
        return Atomic(Certificates(isValid: true, certificates: certificates))
    }()
    
    // MARK: - Settings
    
    public static let defaultTimeout: TimeInterval = 10

    // MARK: - Seed Node URL Session Delegate Implementation
    
    private final class SeedNodeURLSessionDelegateImplementation : NSObject, URLSessionDelegate {

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard HTTP.storageSeedCertificates.wrappedValue.isValid else {
                SNLog("Failed to set load seed node certificates.")
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            guard let trust = challenge.protectionSpace.serverTrust else {
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            // Mark the seed node certificates as trusted
            guard SecTrustSetAnchorCertificates(trust, HTTP.storageSeedCertificates.wrappedValue.certificates as CFArray) == errSecSuccess else {
                SNLog("Failed to set seed node certificates.")
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            
            // Check that the presented certificate is one of the seed node certificates
            var error: CFError?
            guard SecTrustEvaluateWithError(trust, &error) else {
                // Extract the result for further processing (since we are defaulting to `invalid` we
                // don't care if extracting the result type fails)
                var result: SecTrustResultType = .invalid
                _ = SecTrustGetTrustResult(trust, &result)
                
                switch result {
                    case .proceed, .unspecified:
                        /// Unspecified indicates that evaluation reached an (implicitly trusted) anchor certificate without any evaluation
                        /// failures, but never encountered any explicitly stated user-trust preference. This is the most common return
                        /// value. The Keychain Access utility refers to this value as the "Use System Policy," which is the default user setting.
                        return completionHandler(.useCredential, URLCredential(trust: trust))
                    
                    case .recoverableTrustFailure:
                        /// A recoverable failure generally suggests that the certificate was mostly valid but something minor didn't line up,
                        /// while we don't want to recover in this case it's probably a good idea to include the reason in the logs to simplify
                        /// debugging if it does end up happening
                        let reason: String = {
                            guard
                                let validationResult: [String: Any] = SecTrustCopyResult(trust) as? [String: Any],
                                let details: [String: Any] = (validationResult["TrustResultDetails"] as? [[String: Any]])?
                                    .reduce(into: [:], { result, next in next.forEach { result[$0.key] = $0.value } })
                            else { return "Unknown" }

                            return "\(details)"
                        }()
                        
                        SNLog("Failed to validate a seed certificate with a recoverable error: \(reason)")
                        return completionHandler(.cancelAuthenticationChallenge, nil)
                        
                    default:
                        SNLog("Failed to validate a seed certificate with an unrecoverable error.")
                        return completionHandler(.cancelAuthenticationChallenge, nil)
                }
            }
            
            return completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }
    
    // MARK: - Snode URL Session Delegate Implementation
    
    private final class SnodeURLSessionDelegateImplementation : NSObject, URLSessionDelegate {

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            // Snode to snode communication uses self-signed certificates but clients can safely ignore this
            completionHandler(.useCredential, URLCredential(trust: challenge.protectionSpace.serverTrust!))
        }
    }
    
    // MARK: - Execution
        
    public static func execute(
        _ method: HTTPMethod,
        _ url: String,
        timeout: TimeInterval = HTTP.defaultTimeout,
        useSeedNodeURLSession: Bool = false
    ) -> AnyPublisher<Data, Error> {
        return execute(
            method,
            url,
            body: nil,
            timeout: timeout,
            useSeedNodeURLSession: useSeedNodeURLSession
        )
    }
    
    public static func execute(
        _ method: HTTPMethod,
        _ url: String,
        headers: [String: String]? = nil,
        body: Data?,
        timeout: TimeInterval = HTTP.defaultTimeout,
        useSeedNodeURLSession: Bool = false
    ) -> AnyPublisher<Data, Error> {
        guard let url: URL = URL(string: url) else {
            return Fail<Data, Error>(error: HTTPError.invalidURL)
                .eraseToAnyPublisher()
        }
        
        let requestName: String = "\(method.rawValue) request to \(url)"
        let urlSession: URLSession = (useSeedNodeURLSession ? seedNodeURLSession : snodeURLSession)
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.httpBody = body
        request.timeoutInterval = timeout
        request.allHTTPHeaderFields?.removeValue(forKey: "User-Agent")
        request.setValue("WhatsApp", forHTTPHeaderField: "User-Agent") // Set a fake value
        request.setValue("en-us", forHTTPHeaderField: "Accept-Language") // Set a fake value
        headers?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        return urlSession
            .dataTaskPublisher(for: request)
            .mapError { error in
                SNLog("\(requestName) failed due to error: \(error).")
                
                // Override the actual error so that we can correctly catch failed requests
                // in sendOnionRequest(invoking:on:with:)
                switch (error as NSError).code {
                    case NSURLErrorTimedOut: return HTTPError.timeout
                    case NSURLErrorCancelled: return HTTPError.cancelled
                    default: return HTTPError.httpRequestFailed(statusCode: 0, data: nil)
                }
            }
            .tryMap { data, response in try checkForError(requestName, data: data, response: response) }
            .eraseToAnyPublisher()
    }
    
    public static func checkForError(
        _ requestName: String,
        data: Data,
        response: URLResponse
    ) throws -> Data {
        guard let httpResponse: HTTPURLResponse = response as? HTTPURLResponse else {
            SNLog("\(requestName) failed.")
            throw HTTPError.httpRequestFailed(statusCode: 0, data: data)
        }
        
        return try checkForError(requestName, data: data, statusCode: httpResponse.statusCode)
            .defaulting(to: data)
    }
    
    @discardableResult public static func checkForError(
        _ requestName: String,
        data: Data? = nil,
        statusCode: Int
    ) throws -> Data? {
        // Ignore valid status codes
        guard !(200...299).contains(statusCode) else { return data }
        
        let jsonDict: [String: Any]? = {
            guard let data: Data = data else { return nil }
            
            if let processedJson: [String: Any] = try? JSONSerialization.jsonObject(with: data, options: [ .fragmentsAllowed ]) as? [String: Any] {
                return processedJson
            }
            else if let result: String = String(data: data, encoding: .utf8) {
                return [ "result": result ]
            }
            
            return nil
        }()
        
        let jsonDescription: String = (jsonDict?.prettifiedDescription ?? "no debugging info provided")
        SNLog("\(requestName) failed with status code: \(statusCode) (\(jsonDescription)).")
        throw HTTPError.httpRequestFailed(statusCode: UInt(statusCode), data: data)
    }
}
