// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public enum ContentProxy {

    public static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        let proxyHost = "contentproxy.signal.org"
        let proxyPort = 443
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 1,
            "HTTPProxy": proxyHost,
            "HTTPPort": proxyPort,
            "HTTPSEnable": 1,
            "HTTPSProxy": proxyHost,
            "HTTPSPort": proxyPort
        ]
        return configuration
    }

    static let userAgent = "Signal iOS (+https://signal.org/download)"

    public static func configureProxiedRequest(request: inout URLRequest) -> Bool {
        request.addValue(userAgent, forHTTPHeaderField: "User-Agent")

        padRequestSize(request: &request)

        guard let url = request.url,
        let scheme = url.scheme,
            scheme.lowercased() == "https" else {
                return false
        }
        return true
    }

    public static func padRequestSize(request: inout URLRequest) {
        // Generate 1-64 chars of padding.
        let paddingLength: Int = 1 + Int(arc4random_uniform(64))
        let padding = self.padding(withLength: paddingLength)
        assert(padding.count == paddingLength)
        request.addValue(padding, forHTTPHeaderField: "X-SignalPadding")
    }

    private static func padding(withLength length: Int) -> String {
        // Pick a random ASCII char in the range 48-122
        var result = ""
        // Min and max values, inclusive.
        let minValue: UInt32 = 48
        let maxValue: UInt32 = 122
        for _ in 1...length {
            let value = minValue + arc4random_uniform(maxValue - minValue + 1)
            assert(value >= minValue)
            assert(value <= maxValue)
            result += String(UnicodeScalar(UInt8(value)))
        }
        return result
    }
}
