// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import ImageIO
import UniformTypeIdentifiers
import libwebp

public extension Data {
    private struct ImageDimensions {
        let pixelSize: CGSize
        let depthBytes: CGFloat
    }
    
    var isValidImage: Bool {
        let imageFormat: ImageFormat = self.guessedImageFormat
        let isAnimated: Bool = (imageFormat == .gif)
        let maxFileSize: UInt = (isAnimated ?
            MediaUtils.maxFileSizeAnimatedImage :
            MediaUtils.maxFileSizeImage
        )
        
        return (
            count < maxFileSize &&
            isValidImage(type: nil, format: imageFormat) &&
            hasValidImageDimensions(isAnimated: isAnimated)
        )
    }
    
    var guessedImageFormat: ImageFormat {
        let twoBytesLength: Int = 2
        
        guard count > twoBytesLength else { return .unknown }

        var bytes: [UInt8] = [UInt8](repeating: 0, count: twoBytesLength)
        self.copyBytes(to: &bytes, from: (self.startIndex..<self.startIndex.advanced(by: twoBytesLength)))

        switch (bytes[0], bytes[1]) {
            case (0x47, 0x49): return .gif
            case (0x89, 0x50): return .png
            case (0xff, 0xd8): return .jpeg
            case (0x42, 0x4d): return .bmp
            case (0x4D, 0x4D): return .tiff // Motorola byte order TIFF
            case (0x49, 0x49): return .tiff // Intel byte order TIFF
            case (0x52, 0x49): return .webp // First two letters of WebP
                
            default: return .unknown
        }
    }
    
    // Parse the GIF header to prevent the "GIF of death" issue.
    //
    // See: https://blog.flanker017.me/cve-2017-2416-gif-remote-exec/
    // See: https://www.w3.org/Graphics/GIF/spec-gif89a.txt
    var hasValidGifSize: Bool {
        let signatureLength: Int = 3
        let versionLength: Int = 3
        let widthLength: Int = 2
        let heightLength: Int = 2
        let prefixLength: Int = (signatureLength + versionLength)
        let bufferLength: Int = (signatureLength + versionLength + widthLength + heightLength)
        
        guard count > bufferLength else { return false }

        var bytes: [UInt8] = [UInt8](repeating: 0, count: bufferLength)
        self.copyBytes(to: &bytes, from: (self.startIndex..<self.startIndex.advanced(by: bufferLength)))

        let gif87APrefix: [UInt8] = [0x47, 0x49, 0x46, 0x38, 0x37, 0x61]
        let gif89APrefix: [UInt8] = [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]
        
        guard bytes.starts(with: gif87APrefix) || bytes.starts(with: gif89APrefix) else {
            return false
        }
        
        let width: UInt = (UInt(bytes[prefixLength]) | (UInt(bytes[prefixLength + 1]) << 8))
        let height: UInt = (UInt(bytes[prefixLength + 2]) | (UInt(bytes[prefixLength + 3]) << 8))

        // We need to ensure that the image size is "reasonable"
        // We impose an arbitrary "very large" limit on image size
        // to eliminate harmful values
        let maxValidSize: UInt = (1 << 18)

        return (width > 0 && width < maxValidSize && height > 0 && height < maxValidSize)
    }
    
    var sizeForWebpData: CGSize {
        withUnsafeBytes { (unsafeBytes: UnsafeRawBufferPointer) -> CGSize in
            guard let bytes: UnsafePointer<UInt8> = unsafeBytes.bindMemory(to: UInt8.self).baseAddress else {
                return .zero
            }
            
            var webPData: WebPData = WebPData()
            webPData.bytes = bytes
            webPData.size = unsafeBytes.count
            
            guard let demuxer: OpaquePointer = WebPDemux(&webPData) else { return .zero }
            
            let canvasWidth: UInt32 = WebPDemuxGetI(demuxer, WEBP_FF_CANVAS_WIDTH)
            let canvasHeight: UInt32 = WebPDemuxGetI(demuxer, WEBP_FF_CANVAS_HEIGHT)
            let frameCount: UInt32 = WebPDemuxGetI(demuxer, WEBP_FF_FRAME_COUNT)
            WebPDemuxDelete(demuxer)
            
            guard canvasWidth > 0 && canvasHeight > 0 && frameCount > 0 else { return .zero }
            
            return CGSize(width: Int(canvasWidth), height: Int(canvasHeight))
        }
    }
    
    // MARK: - Initialization
    
    init?(validImageDataAt path: String, type: UTType? = nil, using dependencies: Dependencies) throws {
        let fileUrl: URL = URL(fileURLWithPath: path)
        
        guard
            let type: UTType = type,
            let fileSize: UInt64 = dependencies[singleton: .fileManager].fileSize(of: path),
            fileSize <= SNUtilitiesKit.maxFileSize,
            (type.isImage || type.isAnimated)
        else { return nil }
        
        self = try Data(contentsOf: fileUrl, options: [.dataReadingMapped])
    }
    
    // MARK: - Functions
    
    func hasValidImageDimensions(isAnimated: Bool) -> Bool {
        guard
            let dataPtr: CFData = CFDataCreate(kCFAllocatorDefault, self.bytes, self.count),
            let imageSource = CGImageSourceCreateWithData(dataPtr, nil)
        else { return false }

        return Data.hasValidImageDimension(source: imageSource, isAnimated: isAnimated)
    }
    
    func isValidImage(type: UTType?) -> Bool {
        return isValidImage(type: type, format: self.guessedImageFormat)
    }
    
    func isValidImage(type: UTType?, format: ImageFormat) -> Bool {
        // Don't trust the file extension; iOS (e.g. UIKit, Core Graphics) will happily
        // load a .gif with a .png file extension
        //
        // Instead, use the "magic numbers" in the file data to determine the image format
        //
        // If the image has a declared MIME type, ensure that agrees with the
        // deduced image format
        switch format {
            case .unknown: return false
            case .png: return (type == nil || type == .png)
            case .jpeg: return (type == nil || type == .jpeg)
                
            case .gif:
                guard hasValidGifSize else { return false }
                
                return (type == nil || type == .gif)
                
            case .tiff: return (type == nil || type == .tiff || type == .xTiff)
            case .bmp: return (type == nil || type == .bmp || type == .xWinBpm)
            case .webp: return (type == nil || type == .webP)
        }
    }
    
    static func isValidImage(at path: String, type: UTType? = nil, using dependencies: Dependencies) -> Bool {
        guard let data: Data = try? Data(validImageDataAt: path, type: type, using: dependencies) else {
            return false
        }
        
        return data.hasValidImageDimensions(isAnimated: type?.isAnimated == true)
    }
    
    static func hasValidImageDimension(source: CGImageSource, isAnimated: Bool) -> Bool {
        guard let dimensions: ImageDimensions = imageDimensions(source: source) else { return false }

        // We only support (A)RGB and (A)Grayscale, so worst case is 4.
        let worseCastComponentsPerPixel: CGFloat = 4
        let bytesPerPixel: CGFloat = (worseCastComponentsPerPixel * dimensions.depthBytes)
        let expectedBytePerPixel: CGFloat = 4
        let maxValidImageDimension: CGFloat = CGFloat(isAnimated ?
            MediaUtils.maxAnimatedImageDimensions :
            MediaUtils.maxStillImageDimensions
        )
        let maxBytes: CGFloat = (maxValidImageDimension * maxValidImageDimension * expectedBytePerPixel)
        let actualBytes: CGFloat = (dimensions.pixelSize.width * dimensions.pixelSize.height * bytesPerPixel)
        
        return (actualBytes <= maxBytes)
    }
    
    static func hasAlpha(forValidImageFilePath filePath: String) -> Bool {
        let fileUrl: URL = URL(fileURLWithPath: filePath)
        let options: [String: Any] = [kCGImageSourceShouldCache as String: NSNumber(booleanLiteral: false)]
        
        guard
            let imageSource = CGImageSourceCreateWithURL(fileUrl as CFURL, nil),
            let properties: [CFString: Any] = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, options as CFDictionary) as? [CFString: Any],
            let hasAlpha: Bool = properties[kCGImagePropertyHasAlpha] as? Bool
        else { return false }
        
        return hasAlpha
    }
    
    private static func imageDimensions(source: CGImageSource) -> ImageDimensions? {
        guard
            let properties: [CFString: Any] = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width: Double = properties[kCGImagePropertyPixelWidth] as? Double,
            let height: Double = properties[kCGImagePropertyPixelHeight] as? Double,
            // The number of bits in each color sample of each pixel. The value of this key is a CFNumberRef
            let depthBits: UInt = properties[kCGImagePropertyDepth] as? UInt
        else { return nil }
        
        // This should usually be 1.
        let depthBytes: CGFloat = ceil(CGFloat(depthBits) / 8.0)

        // The color model of the image such as "RGB", "CMYK", "Gray", or "Lab"
        // The value of this key is CFStringRef
        guard
            let colorModel = properties[kCGImagePropertyColorModel] as? String,
            (
                colorModel != (kCGImagePropertyColorModelRGB as String) ||
                colorModel != (kCGImagePropertyColorModelGray as String)
            )
        else { return nil }

        return ImageDimensions(pixelSize: CGSize(width: width, height: height), depthBytes: depthBytes)
    }
    
    static func imageSize(for path: String, type: UTType?, using dependencies: Dependencies) -> CGSize {
        let fileUrl: URL = URL(fileURLWithPath: path)
        let isAnimated: Bool = (type?.isAnimated ?? false)
        
        guard
            let data: Data = try? Data(validImageDataAt: path, type: type, using: dependencies),
            let pixelSize: CGSize = imageSize(at: path, with: data, type: type, isAnimated: isAnimated)
        else { return .zero }
        
        guard type != .webP else { return pixelSize }
                
        // With CGImageSource we avoid loading the whole image into memory.
        let options: [String: Any] = [kCGImageSourceShouldCache as String: NSNumber(booleanLiteral: false)]
        
        guard
            let imageSource = CGImageSourceCreateWithURL(fileUrl as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, options as CFDictionary) as? [AnyHashable: Any],
            let width: CGFloat = properties[kCGImagePropertyPixelWidth as String] as? CGFloat,
            let height: CGFloat = properties[kCGImagePropertyPixelHeight as String] as? CGFloat
        else { return .zero }
        
        guard let orientation: UIImage.Orientation = (properties[kCGImagePropertyOrientation as String] as? Int).map({ UIImage.Orientation(exif: $0) }) else {
            return CGSize(width: width, height: height)
        }
        
        return apply(orientation: orientation, to: CGSize(width: width, height: height))
    }
                     
    private static func apply(orientation: UIImage.Orientation, to imageSize: CGSize) -> CGSize {
        switch orientation {
            case .up,               // EXIF = 1
                .upMirrored,        // EXIF = 2
                .down,              // EXIF = 3
                .downMirrored:      // EXIF = 4
                return imageSize
                
            case .leftMirrored,     // EXIF = 5
                .left,              // EXIF = 6
                .rightMirrored,     // EXIF = 7
                .right:             // EXIF = 8
                return CGSize(width: imageSize.height, height: imageSize.width)
                
                
            @unknown default: return imageSize
        }
    }
    
    private static func imageSize(at path: String, with data: Data?, type: UTType?, isAnimated: Bool) -> CGSize? {
        let fileUrl: URL = URL(fileURLWithPath: path)
        
        // Need to custom handle WebP images via libwebp
        guard type != .webP else {
            guard let targetData: Data = (data ?? (try? Data(contentsOf: fileUrl, options: [.dataReadingMapped]))) else {
                return nil
            }
            
            let imageSize: CGSize = targetData.sizeForWebpData
            
            guard imageSize.width > 0, imageSize.height > 0 else { return nil }
            
            return imageSize
        }
        
        // Otherwise use our custom code
        guard
            let imageSource = CGImageSourceCreateWithURL(fileUrl as CFURL, nil),
            let dimensions: ImageDimensions = imageDimensions(source: imageSource),
            dimensions.pixelSize.width > 0,
            dimensions.pixelSize.height > 0,
            dimensions.depthBytes > 0
        else { return nil }
        
        return dimensions.pixelSize
    }
}

private extension UIImage.Orientation {
    init?(exif: Int) {
        switch exif {
            case 1: self = .up
            case 2: self = .upMirrored
            case 3: self = .down
            case 4: self = .downMirrored
            case 5: self = .leftMirrored
            case 6: self = .left
            case 7: self = .rightMirrored
            case 8: self = .right
            default: return nil
        }
    }
}
