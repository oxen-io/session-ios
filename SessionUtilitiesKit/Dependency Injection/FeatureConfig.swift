// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

// MARK: - FeatureStorage

public class FeatureStorage {}

// MARK: - FeatureConfig<T>

public class FeatureConfig<T: FeatureOption>: FeatureStorage {
    public let identifier: String
    public let createInstance: (Dependencies) -> Feature<T>

    /// `fileprivate` to hide when accessing via `dependencies[feature: ]`
    fileprivate init(
        identifier: String,
        defaultOption: T,
        automaticChangeBehaviour: Feature<T>.ChangeBehaviour?
    ) {
        self.identifier = identifier
        self.createInstance = { _ in
            Feature<T>(
                identifier: identifier,
                options: Array(T.allCases),
                defaultOption: defaultOption,
                automaticChangeBehaviour: automaticChangeBehaviour
            )
        }
    }
}

// MARK: - Creation

public extension Dependencies {
    static func create<T: FeatureOption>(
        identifier: String,
        defaultOption: T = T.defaultOption,
        automaticChangeBehaviour: Feature<T>.ChangeBehaviour? = nil
    ) -> FeatureConfig<T> {
        return FeatureConfig(
            identifier: identifier,
            defaultOption: defaultOption,
            automaticChangeBehaviour: automaticChangeBehaviour
        )
    }
}
