//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

import UIKit
import SessionUtilitiesKit

public class ImageEditorStrokeItem: ImageEditorItem {
    // Until we need to serialize these items,
    // just use UIColor.
    public let color: UIColor

    public typealias StrokeSample = ImageEditorSample

    public let unitSamples: [StrokeSample]

    // Expressed as a "Unit" value as a fraction of
    // min(width, height) of the destination viewport.
    public let unitStrokeWidth: CGFloat

    public init(color: UIColor, unitSamples: [StrokeSample], unitStrokeWidth: CGFloat) {
        self.color = color
        self.unitSamples = unitSamples
        self.unitStrokeWidth = unitStrokeWidth

        super.init(itemType: .stroke)
    }

    public init(itemId: String, color: UIColor, unitSamples: [StrokeSample], unitStrokeWidth: CGFloat) {
        self.color = color
        self.unitSamples = unitSamples
        self.unitStrokeWidth = unitStrokeWidth

        super.init(itemId: itemId, itemType: .stroke)
    }

    public class func defaultUnitStrokeWidth() -> CGFloat {
        return 0.02
    }

    public class func strokeWidth(forUnitStrokeWidth unitStrokeWidth: CGFloat, dstSize: CGSize) -> CGFloat {
        return unitStrokeWidth.clamp01() * min(dstSize.width, dstSize.height)
    }
}
