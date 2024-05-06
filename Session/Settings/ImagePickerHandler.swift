// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUtilitiesKit

class ImagePickerHandler: NSObject, UIImagePickerControllerDelegate & UINavigationControllerDelegate {
    private let onTransition: (UIViewController, TransitionType) -> Void
    private let onImageDataPicked: (Data) -> Void
    
    // MARK: - Initialization
    
    init(
        onTransition: @escaping (UIViewController, TransitionType) -> Void,
        onImageDataPicked: @escaping (Data) -> Void
    ) {
        self.onTransition = onTransition
        self.onImageDataPicked = onImageDataPicked
    }
    
    // MARK: - UIImagePickerControllerDelegate
    
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
    
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        guard
            let imageUrl: URL = info[.imageURL] as? URL,
            let rawAvatar: UIImage = info[.originalImage] as? UIImage
        else {
            picker.presentingViewController?.dismiss(animated: true)
            return
        }
        
        picker.presentingViewController?.dismiss(animated: true) { [weak self] in
            // Check if the user selected an animated image (if so then don't crop, just
            // set the avatar directly
            guard
                let resourceValues: URLResourceValues = (try? imageUrl.resourceValues(forKeys: [.typeIdentifierKey])),
                let type: Any = resourceValues.allValues.first?.value,
                let utiTypeString: String = type as? String,
                MimeTypeUtil.isAnimated(utiType: utiTypeString)
            else {
                let viewController: CropScaleImageViewController = CropScaleImageViewController(
                    srcImage: rawAvatar,
                    successCompletion: { resultImageData in
                        self?.onImageDataPicked(resultImageData)
                    }
                )
                self?.onTransition(viewController, .present)
                return
            }
            
            guard let imageData: Data = try? Data(contentsOf: URL(fileURLWithPath: imageUrl.path)) else { return }
            
            self?.onImageDataPicked(imageData)
        }
    }
}
