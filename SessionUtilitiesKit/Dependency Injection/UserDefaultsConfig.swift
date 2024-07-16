// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

// MARK: - UserDefaultsStorage

public class UserDefaultsStorage {}

// MARK: - UserDefaultsConfig

public class UserDefaultsConfig: UserDefaultsStorage {
    public let identifier: String
    public let createInstance: (Dependencies) -> UserDefaultsType

    /// `fileprivate` to hide when accessing via `dependencies[defaults: ]`
    fileprivate init(
        identifier: String,
        createInstance: @escaping (Dependencies) -> UserDefaultsType
    ) {
        self.identifier = identifier
        self.createInstance = createInstance
    }
}

// MARK: - Creation

public extension Dependencies {
    static func create(
        identifier: String,
        createInstance: @escaping (Dependencies) -> UserDefaultsType
    ) -> UserDefaultsConfig {
        return UserDefaultsConfig(
            identifier: identifier,
            createInstance: createInstance
        )
    }
}
