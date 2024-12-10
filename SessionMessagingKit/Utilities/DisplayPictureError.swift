// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public enum DisplayPictureError: LocalizedError {
    case imageTooLarge
    case writeFailed
    case encryptionFailed
    case uploadFailed
    case uploadMaxFileSizeExceeded
    case invalidCall
    case invalidFilename
    
    var localizedDescription: String {
        switch self {
            case .imageTooLarge: return "Display picture too large."
            case .writeFailed: return "Display picture write failed."
            case .encryptionFailed: return "Display picture encryption failed."
            case .uploadFailed: return "Display picture upload failed."
            case .uploadMaxFileSizeExceeded: return "Maximum file size exceeded."
            case .invalidCall: return "Attempted to remove display picture using the wrong method."
            case .invalidFilename: return "Filename would have resulted in an invalid path."
        }
    }
}
