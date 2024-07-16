// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

// MARK: - FeatureStorage

public extension FeatureStorage {
    static let serviceNetwork: FeatureConfig<ServiceNetwork> = Dependencies.create(
        identifier: "serviceNetwork",
        defaultOption: .mainnet
    )
}

// MARK: - ServiceNetwork Feature

public enum ServiceNetwork: Int, FeatureOption {
    case mainnet = 1
    case testnet = 2
    
    // MARK: - Feature Option
    
    public static var defaultOption: ServiceNetwork = .mainnet
    
    public var title: String {
        switch self {
            case .mainnet: return "Mainnet"
            case .testnet: return "Testnet"
        }
    }
    
    public var subtitle: String? {
        switch self {
            case .mainnet: return "This is the production service node network."
            case .testnet: return "This is the test service node network, it should be used for testing features which are currently in development and may be unstable."
        }
    }
}
