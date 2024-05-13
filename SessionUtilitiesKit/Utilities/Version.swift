// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public struct Version: Comparable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    
    public var stringValue: String { "\(major).\(minor).\(patch)" }
    
    // MARK: - Initialization
    
    public init(
        major: Int,
        minor: Int,
        patch: Int
    ) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }
    
    // MARK: - Functions
    
    public static func from(_ versionString: String) -> Version {
        var tokens: [Int] = versionString
            .split(separator: ".")  // stringlint:disable
            .map { (Int($0) ?? 0) }
        
        // Extend to '{major}.{minor}.{patch}' if any parts were omitted
        while tokens.count < 3 {
            tokens.append(0)
        }
        
        return Version(major: tokens[0], minor: tokens[1], patch: tokens[2])
    }
    
    // MARK: - Comparable
    
    public static func == (lhs: Version, rhs: Version) -> Bool {
        return (
            lhs.major == rhs.major &&
            lhs.minor == rhs.minor &&
            lhs.patch == rhs.patch
        )
    }
    
    public static func < (lhs: Version, rhs: Version) -> Bool {
        guard lhs.major == rhs.major else { return (lhs.major < rhs.major) }
        guard lhs.minor == rhs.minor else { return (lhs.minor < rhs.minor) }
        
        return (lhs.patch < rhs.patch)
    }
}

public enum FeatureVersion: Int, Codable, Equatable, Hashable, DatabaseValueConvertible {
    case legacyDisappearingMessages
    case newDisappearingMessages
}
