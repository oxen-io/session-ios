// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import DifferenceKit
import SessionUIKit

public protocol SessionTableSection: Differentiable, Equatable {
    var title: String? { get }
    var style: SessionTableSectionStyle { get }
    var footer: String? { get }
}

extension SessionTableSection {
    public var title: String? { nil }
    public var style: SessionTableSectionStyle { .none }
    public var footer: String? { nil }
}

public enum SessionTableSectionStyle: Equatable, Hashable, Differentiable {
    case none
    case titleRoundedContent
    case titleEdgeToEdgeContent
    case titleNoBackgroundContent
    case titleSeparator
    case padding
    case loadMore
    
    var height: CGFloat {
        switch self {
            case .none: return 0
            case .titleRoundedContent, .titleEdgeToEdgeContent, .titleNoBackgroundContent:
                return UITableView.automaticDimension
                
            case .titleSeparator: return Separator.height
            case .padding: return Values.smallSpacing
            case .loadMore: return 40
        }
    }
    
    /// These values should always be consistent with the padding in `SessionCell` to ensure the text lines up
    var edgePadding: CGFloat {
        switch self {
            case .titleRoundedContent, .titleNoBackgroundContent:
                // Align to the start of the text in the cell
                return (Values.largeSpacing + Values.mediumSpacing)
            
            case .titleEdgeToEdgeContent, .titleSeparator: return Values.largeSpacing
            case .none, .padding, .loadMore: return 0
        }
    }
}
