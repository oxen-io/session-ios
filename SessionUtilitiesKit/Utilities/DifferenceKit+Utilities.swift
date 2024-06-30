// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import DifferenceKit

extension String: Differentiable {}

extension ArraySection: Identifiable {
    public var id: String {
        "\(model.differenceIdentifier)\(elements.count)"
    }
}
