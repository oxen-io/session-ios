//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

import UIKit
import SignalUtilitiesKit

@objc class OWSImagePickerController: UIImagePickerController {

    // MARK: Orientation

    override public var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return (UIDevice.current.isIPad ? .all : .portrait)
    }
}
