// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit.UIImage

public extension UIImage {
    func normalizedImage() -> UIImage {
        guard
            let imgRef: CGImage = self.cgImage,
            imageOrientation != .up
        else { return self }
        
        // The actual resize: draw the image on a new context, applying a transform matrix
        let bounds: CGRect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = self.scale
        format.opaque = false
        
        let renderer: UIGraphicsImageRenderer = UIGraphicsImageRenderer(bounds: bounds, format: format)

        return renderer.image { rendererContext in
            rendererContext.cgContext.draw(imgRef, in: bounds, byTiling: false)
        }
    }
    
    func resized(to targetSize: CGSize) -> UIImage? {
        guard let imgRef: CGImage = self.cgImage else { return nil }
        
        // the below values are regardless of orientation : for UIImages from Camera, width>height (landscape)
        //
        // Note: Not equivalent to self.size (which is dependant on the imageOrientation)!
        let srcSize: CGSize = CGSize(width: imgRef.width, height: imgRef.height)
        var dstSize: CGSize = targetSize
        
        // Don't resize if we already meet the required destination size
        guard dstSize != srcSize else { return self }
        
        let scaleRatio: CGFloat = (dstSize.width / srcSize.width)
        let orient: UIImage.Orientation = self.imageOrientation
        var transform: CGAffineTransform = .identity
        
        switch orient {
            case .up: break                      // EXIF = 1
            case .upMirrored:                    // EXIF = 2
                transform = CGAffineTransform(translationX: srcSize.width, y: 0)
                    .scaledBy(x: -1, y: 1)
                
            case .down:                          // EXIF = 3
                transform = CGAffineTransform(translationX: srcSize.width, y: srcSize.height)
                    .rotated(by: CGFloat.pi)

            case .downMirrored:                  // EXIF = 4
                transform = CGAffineTransform(translationX: 0, y: srcSize.height)
                    .scaledBy(x: 1, y: -1)
                
            case .leftMirrored:                  // EXIF = 5
                dstSize = CGSize(width: dstSize.height, height: dstSize.width)
                transform = CGAffineTransform(translationX: srcSize.height, y: srcSize.width)
                    .scaledBy(x: -1, y: 1)
                    .rotated(by: (3 * (CGFloat.pi / 2)))
                
            case .left:                          // EXIF = 6
                dstSize = CGSize(width: dstSize.height, height: dstSize.width)
                transform = CGAffineTransform(translationX: 0, y: srcSize.width)
                    .scaledBy(x: -1, y: 1)
                    .rotated(by: (3 * (CGFloat.pi / 2)))
                
            case .rightMirrored:                 // EXIF = 7
                dstSize = CGSize(width: dstSize.height, height: dstSize.width)
                transform = CGAffineTransform(scaleX: -1, y: 1)
                    .rotated(by: (CGFloat.pi / 2))
                
            case .right:                         // EXIF = 8
                dstSize = CGSize(width: dstSize.height, height: dstSize.width)
                transform = CGAffineTransform(translationX: srcSize.height, y: 0)
                    .rotated(by: (CGFloat.pi / 2))
            
            @unknown default: return nil
        }

        // The actual resize: draw the image on a new context, applying a transform matrix
        let bounds: CGRect = CGRect(x: 0, y: 0, width: dstSize.width, height: dstSize.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = self.scale
        format.opaque = false
        
        let renderer: UIGraphicsImageRenderer = UIGraphicsImageRenderer(bounds: bounds, format: format)

        return renderer.image { rendererContext in
            rendererContext.cgContext.interpolationQuality = .high
            
            switch orient {
                case .right, .left:
                    rendererContext.cgContext.scaleBy(x: -scaleRatio, y: scaleRatio)
                    rendererContext.cgContext.translateBy(x: -srcSize.height, y: 0)
                    
                default:
                    rendererContext.cgContext.scaleBy(x: scaleRatio, y: -scaleRatio)
                    rendererContext.cgContext.translateBy(x: 0, y: -srcSize.height)
            }
            
            rendererContext.cgContext.concatenate(transform)
            
            // we use srcSize (and not dstSize) as the size to specify is in user space (and we use the CTM to apply a
            // scaleRatio)
            rendererContext.cgContext.draw(
                imgRef,
                in: CGRect(x: 0, y: 0, width: srcSize.width, height: srcSize.height),
                byTiling: false
            )
        }
    }
    
    func resized(toFillPixelSize dstSize: CGSize) -> UIImage {
        let normalized: UIImage = self.normalizedImage()
        
        guard
            let normalizedRef: CGImage = normalized.cgImage,
            let imgRef: CGImage = self.cgImage
        else { return self }
        
        // Get the size in pixels, not points
        let srcSize: CGSize = CGSize(width: normalizedRef.width, height: normalizedRef.height)
        let widthRatio: CGFloat = (srcSize.width / srcSize.height)
        let heightRatio: CGFloat = (srcSize.height / srcSize.height)
        let drawRect: CGRect = {
            guard widthRatio <= heightRatio else {
                let targetWidth: CGFloat = (dstSize.height * srcSize.width / srcSize.height)
                
                return CGRect(
                    x: (targetWidth - dstSize.width) * -0.5,
                    y: 0,
                    width: targetWidth,
                    height: dstSize.height
                )
            }
            
            let targetHeight: CGFloat = (dstSize.width * srcSize.height / srcSize.width)
            
            return CGRect(
                x: 0,
                y: (targetHeight - dstSize.height) * -0.5,
                width: dstSize.width,
                height: targetHeight
            )
        }()
        
        let bounds: CGRect = CGRect(x: 0, y: 0, width: dstSize.width, height: dstSize.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1    // We are specifying a specific pixel size rather than a point size
        format.opaque = false
        
        let renderer: UIGraphicsImageRenderer = UIGraphicsImageRenderer(bounds: bounds, format: format)

        return renderer.image { rendererContext in
            rendererContext.cgContext.interpolationQuality = .high
            
            // we use srcSize (and not dstSize) as the size to specify is in user space (and we use the CTM to apply a
            // scaleRatio)
            rendererContext.cgContext.draw(imgRef, in: drawRect, byTiling: false)
        }
    }
    
    func resized(maxDimensionPoints: CGFloat) -> UIImage? {
        let originalSize: CGSize = self.size
        let maxOriginalDimensionPoints: CGFloat = max(originalSize.width, originalSize.height)
        
        guard originalSize.width > 0 && originalSize.height > 0 else { return nil }
        
        // Don't bother scaling an image that is already smaller than the max dimension.
        guard maxOriginalDimensionPoints > maxDimensionPoints else { return self }
        
        let thumbnailSize: CGSize = {
            guard originalSize.width <= originalSize.height else {
                return CGSize(
                    width: maxDimensionPoints,
                    height: round(maxDimensionPoints * originalSize.height / originalSize.width)
                )
            }
            
            return CGSize(
                width: round(maxDimensionPoints * originalSize.width / originalSize.height),
                height: maxDimensionPoints
            )
        }()
        
        guard thumbnailSize.width > 0 && thumbnailSize.height > 0 else { return nil }
        
        return resized(to: thumbnailSize)
    }
}
