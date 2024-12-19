//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//
// stringlint:disable

import UIKit
import Combine
import MobileCoreServices
import AVFoundation
import UniformTypeIdentifiers
import SessionUtilitiesKit

public enum SignalAttachmentError: Error {
    case missingData
    case fileSizeTooLarge
    case invalidData
    case couldNotParseImage
    case couldNotConvertToJpeg
    case couldNotConvertToMpeg4
    case couldNotRemoveMetadata
    case invalidFileFormat
    case couldNotResizeImage
}

extension String {
    public var filenameWithoutExtension: String {
        return (self as NSString).deletingPathExtension
    }

    public var fileExtension: String? {
        return (self as NSString).pathExtension
    }

    public func appendingFileExtension(_ fileExtension: String) -> String {
        guard let result = (self as NSString).appendingPathExtension(fileExtension) else {
            return self
        }
        return result
    }
}

extension SignalAttachmentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
            case .fileSizeTooLarge:
                return "attachmentsErrorSize".localized()
            case .invalidData, .missingData, .invalidFileFormat:
                return "attachmentsErrorNotSupported".localized()
            case .couldNotConvertToJpeg, .couldNotParseImage, .couldNotConvertToMpeg4, .couldNotResizeImage:
                return "attachmentsErrorOpen".localized()
            case .couldNotRemoveMetadata:
                return "attachmentsImageErrorMetadata".localized()
        }
    }
}

@objc
public enum TSImageQualityTier: UInt {
    case original
    case high
    case mediumHigh
    case medium
    case mediumLow
    case low
}

@objc
public enum TSImageQuality: UInt {
    case original
    case medium
    case compact

    func imageQualityTier() -> TSImageQualityTier {
        switch self {
        case .original:
            return .original
        case .medium:
            return .mediumHigh
        case .compact:
            return .medium
        }
    }
}

// Represents a possible attachment to upload.
// The attachment may be invalid.
//
// Signal attachments are subject to validation and 
// in some cases, file format conversion.
//
// This class gathers that logic.  It offers factory methods
// for attachments that do the necessary work. 
//
// The return value for the factory methods will be nil if the input is nil.
//
// [SignalAttachment hasError] will be true for non-valid attachments.
//
// TODO: Perhaps do conversion off the main thread?
public class SignalAttachment: Equatable {

    // MARK: Properties

    public let dataSource: (any DataSource)
    public var captionText: String?
    public var linkPreviewDraft: LinkPreviewDraft?
    
    public var data: Data { return dataSource.data }
    public var dataLength: UInt { return UInt(dataSource.dataLength) }
    public var dataUrl: URL? { return dataSource.dataUrl }
    public var sourceFilename: String? { return dataSource.sourceFilename?.filteredFilename }
    public var isValidImage: Bool { return dataSource.isValidImage }
    public var isValidVideo: Bool { return dataSource.isValidVideo }

    // This flag should be set for text attachments that can be sent as text messages.
    public var isConvertibleToTextMessage = false

    // This flag should be set for attachments that can be sent as contact shares.
    public var isConvertibleToContactShare = false

    // Attachment types are identified using UTType.
    public let dataType: UTType

    public var error: SignalAttachmentError? {
        didSet {
            assert(oldValue == nil)
        }
    }

    // To avoid redundant work of repeatedly compressing/uncompressing
    // images, we cache the UIImage associated with this attachment if
    // possible.
    private var cachedImage: UIImage?
    private var cachedVideoPreview: UIImage?

    private(set) public var isVoiceMessage = false

    // MARK: 

    public static let maxAttachmentsAllowed: Int = 32

    // MARK: Constructor

    // This method should not be called directly; use the factory
    // methods instead.
    private init(dataSource: (any DataSource), dataType: UTType) {
        self.dataSource = dataSource
        self.dataType = dataType
    }

    // MARK: Methods

    public var hasError: Bool { return error != nil }

    public var errorName: String? {
        guard let error = error else {
            // This method should only be called if there is an error.
            return nil
        }

        return "\(error)"
    }

    public var localizedErrorDescription: String? {
        guard let error = self.error else {
            // This method should only be called if there is an error.
            return nil
        }
        guard let errorDescription = error.errorDescription else {
            return nil
        }

        return "\(errorDescription)"
    }

    public class var missingDataErrorMessage: String {
        guard let errorDescription = SignalAttachmentError.missingData.errorDescription else {
            return ""
        }
        
        return errorDescription
    }

    public func staticThumbnail(using dependencies: Dependencies) -> UIImage? {
        if isAnimatedImage {
            return image()
        }
        else if isImage {
            return image()
        }
        else if isVideo {
            return videoPreview(using: dependencies)
        }
        else if isAudio {
            return nil
        }
        
        return nil
    }

    public func image() -> UIImage? {
        if let cachedImage = cachedImage {
            return cachedImage
        }
        guard let image = UIImage(data: dataSource.data) else {
            return nil
        }
        
        cachedImage = image
        return image
    }

    public func videoPreview(using dependencies: Dependencies) -> UIImage? {
        if let cachedVideoPreview = cachedVideoPreview {
            return cachedVideoPreview
        }

        guard let mediaUrl = dataUrl else {
            return nil
        }

        do {
            let filePath = mediaUrl.path
            guard dependencies[singleton: .fileManager].fileExists(atPath: filePath) else {
                return nil
            }

            let asset = AVURLAsset(url: mediaUrl)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let cgImage = try generator.copyCGImage(at: CMTimeMake(value: 0, timescale: 1), actualTime: nil)
            let image = UIImage(cgImage: cgImage)

            cachedVideoPreview = image
            return image

        } catch {
            return nil
        }
    }
    
    public func text() -> String? {
        guard let text = String(data: dataSource.data, encoding: .utf8) else {
            return nil
        }
        
        return text
    }
    
    public func duration() -> TimeInterval? {
        switch (isAudio, isVideo) {
            case (true, _):
                let audioPlayer: AVAudioPlayer? = try? AVAudioPlayer(data: dataSource.data)
                
                return (audioPlayer?.duration).map { $0 > 0 ? $0 : nil }
                
            case (_, true):
                return dataUrl.map { url in
                    let asset: AVURLAsset = AVURLAsset(url: url, options: nil)
                    
                    // According to the CMTime docs "value/timescale = seconds"
                    return (TimeInterval(asset.duration.value) / TimeInterval(asset.duration.timescale))
                }
                
            default: return nil
        }
    }

    // Returns the MIME type for this attachment or nil if no MIME type
    // can be identified.
    public var mimeType: String {
        guard
            let fileExtension: String = sourceFilename.map({ URL(fileURLWithPath: $0) })?.pathExtension,
            !fileExtension.isEmpty,
            let fileExtensionMimeType: String = UTType(sessionFileExtension: fileExtension)?.preferredMIMEType
        else { return (dataType.preferredMIMEType ?? UTType.mimeTypeDefault) }
        
        // UTI types are an imperfect means of representing file type;
        // file extensions are also imperfect but far more reliable and
        // comprehensive so we always prefer to try to deduce MIME type
        // from the file extension.
        return fileExtensionMimeType
    }

    // Use the filename if known. If not, e.g. if the attachment was copy/pasted, we'll generate a filename
    // like: "signal-2017-04-24-095918.zip"
    public var filenameOrDefault: String {
        if let filename = sourceFilename {
            return filename.filteredFilename
        } else {
            let kDefaultAttachmentName = "signal"

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "YYYY-MM-dd-HHmmss"
            let dateString = dateFormatter.string(from: Date())

            let withoutExtension = "\(kDefaultAttachmentName)-\(dateString)"
            if let fileExtension = self.fileExtension {
                return "\(withoutExtension).\(fileExtension)"
            }

            return withoutExtension
        }
    }

    // Returns the file extension for this attachment or nil if no file extension
    // can be identified.
    public var fileExtension: String? {
        guard
            let fileExtension: String = sourceFilename.map({ URL(fileURLWithPath: $0) })?.pathExtension,
            !fileExtension.isEmpty
        else { return dataType.sessionFileExtension(sourceFilename: sourceFilename) }
        
        return fileExtension.filteredFilename
    }

    public var isImage: Bool { dataType.isImage || dataType.isAnimated }
    public var isAnimatedImage: Bool { dataType.isAnimated }
    public var isVideo: Bool { dataType.isVideo }
    public var isAudio: Bool { dataType.isAudio }

    public var isText: Bool {
        isConvertibleToTextMessage &&
        dataType.conforms(to: .text)
    }

    public var isUrl: Bool {
        dataType.conforms(to: .url)
    }

    public class func pasteboardHasPossibleAttachment() -> Bool {
        return UIPasteboard.general.numberOfItems > 0
    }

    public class func pasteboardHasText() -> Bool {
        guard
            UIPasteboard.general.numberOfItems > 0,
            let pasteboardUTIdentifiers: [[String]] = UIPasteboard.general.types(forItemSet: IndexSet(integer: 0)),
            let pasteboardUTTypes: Set<UTType> = pasteboardUTIdentifiers.first.map({ Set($0.compactMap { UTType($0) }) })
        else { return false }

        // The pasteboard can be populated with multiple UTI types
        // with different payloads.  iMessage for example will copy
        // an animated GIF to the pasteboard with the following UTI
        // types:
        //
        // * "public.url-name"
        // * "public.utf8-plain-text"
        // * "com.compuserve.gif"
        //
        // We want to paste the animated GIF itself, not it's name.
        //
        // In general, our rule is to prefer non-text pasteboard
        // contents, so we return true IFF there is a text UTI type
        // and there is no non-text UTI type.
        guard !pasteboardUTTypes.contains(where: { !$0.conforms(to: .text) }) else { return false }
        
        return pasteboardUTTypes.contains(where: { $0.conforms(to: .text) || $0.conforms(to: .url) })
    }

    // Returns an attachment from the pasteboard, or nil if no attachment
    // can be found.
    //
    // NOTE: The attachment returned by this method may not be valid.
    //       Check the attachment's error property.
    public class func attachmentFromPasteboard(using dependencies: Dependencies) -> SignalAttachment? {
        guard
            UIPasteboard.general.numberOfItems > 0,
            let pasteboardUTIdentifiers: [[String]] = UIPasteboard.general.types(forItemSet: IndexSet(integer: 0)),
            let pasteboardUTTypes: Set<UTType> = pasteboardUTIdentifiers.first.map({ Set($0.compactMap { UTType($0) }) })
        else { return nil }
        
        for type in UTType.supportedInputImageTypes {
            if pasteboardUTTypes.contains(type) {
                guard let data: Data = dataForFirstPasteboardItem(type: type) else { return nil }
                
                // Pasted images _SHOULD _NOT_ be resized, if possible.
                let dataSource = DataSourceValue(data: data, dataType: type, using: dependencies)
                return attachment(dataSource: dataSource, type: type, imageQuality: .original, using: dependencies)
            }
        }
        for type in UTType.supportedVideoTypes {
            if pasteboardUTTypes.contains(type) {
                guard let data = dataForFirstPasteboardItem(type: type) else { return nil }
                
                let dataSource = DataSourceValue(data: data, dataType: type, using: dependencies)
                return videoAttachment(dataSource: dataSource, type: type, using: dependencies)
            }
        }
        for type in UTType.supportedAudioTypes {
            if pasteboardUTTypes.contains(type) {
                guard let data = dataForFirstPasteboardItem(type: type) else { return nil }
                
                let dataSource = DataSourceValue(data: data, dataType: type, using: dependencies)
                return audioAttachment(dataSource: dataSource, type: type, using: dependencies)
            }
        }

        let type: UTType = pasteboardUTTypes[pasteboardUTTypes.startIndex]
        guard let data = dataForFirstPasteboardItem(type: type) else { return nil }
        
        let dataSource = DataSourceValue(data: data, dataType: type, using: dependencies)
        return genericAttachment(dataSource: dataSource, type: type, using: dependencies)
    }

    // This method should only be called for dataUTIs that
    // are appropriate for the first pasteboard item.
    private class func dataForFirstPasteboardItem(type: UTType) -> Data? {
        guard
            UIPasteboard.general.numberOfItems > 0,
            let dataValues: [Data] = UIPasteboard.general.data(
                forPasteboardType: type.identifier,
                inItemSet: IndexSet(integer: 0)
            ),
            !dataValues.isEmpty
        else { return nil }
        
        return dataValues[0]
    }

    // MARK: Image Attachments

    // Factory method for an image attachment.
    //
    // NOTE: The attachment returned by this method may not be valid.
    //       Check the attachment's error property.
    private class func imageAttachment(dataSource: (any DataSource)?, type: UTType, imageQuality: TSImageQuality, using dependencies: Dependencies) -> SignalAttachment {
        assert(dataSource != nil)
        guard var dataSource = dataSource else {
            let attachment = SignalAttachment(dataSource: DataSourceValue.empty(using: dependencies), dataType: type)
            attachment.error = .missingData
            return attachment
        }

        let attachment = SignalAttachment(dataSource: dataSource, dataType: type)

        guard UTType.supportedInputImageTypes.contains(type) else {
            attachment.error = .invalidFileFormat
            return attachment
        }

        guard dataSource.dataLength > 0 else {
            attachment.error = .invalidData
            return attachment
        }

        if UTType.supportedAnimatedImageTypes.contains(type) {
            guard dataSource.dataLength <= MediaUtils.maxFileSizeAnimatedImage else {
                attachment.error = .fileSizeTooLarge
                return attachment
            }

            // Never re-encode animated images (i.e. GIFs) as JPEGs.
            return attachment
        } else {
            guard let image = UIImage(data: dataSource.data) else {
                attachment.error = .couldNotParseImage
                return attachment
            }
            attachment.cachedImage = image

            let isValidOutput = isValidOutputImage(image: image, dataSource: dataSource, type: type, imageQuality: imageQuality)

            if let sourceFilename = dataSource.sourceFilename,
                let sourceFileExtension = sourceFilename.fileExtension,
                ["heic", "heif"].contains(sourceFileExtension.lowercased()) {

                // If a .heic file actually contains jpeg data, update the extension to match.
                //
                // Here's how that can happen:
                // In iOS11, the Photos.app records photos with HEIC UTIType, with the .HEIC extension.
                // Since HEIC isn't a valid output format for Signal, we'll detect that and convert to JPEG,
                // updating the extension as well. No problem.
                // However the problem comes in when you edit an HEIC image in Photos.app - the image is saved
                // in the Photos.app as a JPEG, but retains the (now incongruous) HEIC extension in the filename.
                assert(type == .jpeg || !isValidOutput)

                let baseFilename = sourceFilename.filenameWithoutExtension
                dataSource.sourceFilename = baseFilename.appendingFileExtension("jpg")
            }

            if isValidOutput {
                return removeImageMetadata(attachment: attachment, using: dependencies)
            } else {
                return compressImageAsJPEG(image: image, attachment: attachment, filename: dataSource.sourceFilename, imageQuality: imageQuality, using: dependencies)
            }
        }
    }

    // If the proposed attachment already conforms to the
    // file size and content size limits, don't recompress it.
    private class func isValidOutputImage(image: UIImage?, dataSource: (any DataSource)?, type: UTType, imageQuality: TSImageQuality) -> Bool {
        guard
            image != nil,
            let dataSource = dataSource,
            UTType.supportedOutputImageTypes.contains(type)
        else { return false }
        
        return (
            doesImageHaveAcceptableFileSize(dataSource: dataSource, imageQuality: imageQuality) &&
            dataSource.dataLength <= MediaUtils.maxFileSizeImage
        )
    }

    // Factory method for an image attachment.
    //
    // NOTE: The attachment returned by this method may nil or not be valid.
    //       Check the attachment's error property.
    public class func imageAttachment(image: UIImage?, type: UTType, filename: String?, imageQuality: TSImageQuality, using dependencies: Dependencies) -> SignalAttachment {
        guard let image: UIImage = image else {
            let dataSource = DataSourceValue.empty(using: dependencies)
            dataSource.sourceFilename = filename
            let attachment = SignalAttachment(dataSource: dataSource, dataType: type)
            attachment.error = .missingData
            return attachment
        }

        // Make a placeholder attachment on which to hang errors if necessary.
        let dataSource = DataSourceValue.empty(using: dependencies)
        dataSource.sourceFilename = filename
        let attachment = SignalAttachment(dataSource: dataSource, dataType: type)
        attachment.cachedImage = image

        return compressImageAsJPEG(image: image, attachment: attachment, filename: filename, imageQuality: imageQuality, using: dependencies)
    }

    private class func compressImageAsJPEG(image: UIImage, attachment: SignalAttachment, filename: String?, imageQuality: TSImageQuality, using dependencies: Dependencies) -> SignalAttachment {
        assert(attachment.error == nil)

        if imageQuality == .original &&
            attachment.dataLength < MediaUtils.maxFileSizeGeneric &&
            UTType.supportedOutputImageTypes.contains(attachment.dataType) {
            // We should avoid resizing images attached "as documents" if possible.
            return attachment
        }

        var imageUploadQuality = imageQuality.imageQualityTier()

        while true {
            let maxSize = maxSizeForImage(image: image, imageUploadQuality: imageUploadQuality)
            var dstImage: UIImage! = image
            if image.size.width > maxSize ||
                image.size.height > maxSize {
                guard let resizedImage = imageScaled(image, toMaxSize: maxSize) else {
                    attachment.error = .couldNotResizeImage
                    return attachment
                }
                dstImage = resizedImage
            }
            guard let jpgImageData = dstImage.jpegData(compressionQuality: jpegCompressionQuality(imageUploadQuality: imageUploadQuality)) else {
                attachment.error = .couldNotConvertToJpeg
                return attachment
            }

            let dataSource = DataSourceValue(data: jpgImageData, fileExtension: "jpg", using: dependencies)
            let baseFilename = filename?.filenameWithoutExtension
            let jpgFilename = baseFilename?.appendingFileExtension("jpg")
            dataSource.sourceFilename = jpgFilename

            if doesImageHaveAcceptableFileSize(dataSource: dataSource, imageQuality: imageQuality) &&
                dataSource.dataLength <= MediaUtils.maxFileSizeImage {
                let recompressedAttachment = SignalAttachment(dataSource: dataSource, dataType: .jpeg)
                recompressedAttachment.cachedImage = dstImage
                return recompressedAttachment
            }

            // If the JPEG output is larger than the file size limit,
            // continue to try again by progressively reducing the
            // image upload quality.
            switch imageUploadQuality {
            case .original:
                imageUploadQuality = .high
            case .high:
                imageUploadQuality = .mediumHigh
            case .mediumHigh:
                imageUploadQuality = .medium
            case .medium:
                imageUploadQuality = .mediumLow
            case .mediumLow:
                imageUploadQuality = .low
            case .low:
                attachment.error = .fileSizeTooLarge
                return attachment
            }
        }
    }

    // NOTE: For unknown reasons, resizing images with UIGraphicsBeginImageContext()
    // crashes reliably in the share extension after screen lock's auth UI has been presented.
    // Resizing using a CGContext seems to work fine.
    private class func imageScaled(_ uiImage: UIImage, toMaxSize maxSize: CGFloat) -> UIImage? {
        guard let cgImage = uiImage.cgImage else {
            return nil
        }

        // It's essential that we work consistently in "CG" coordinates (which are
        // pixels and don't reflect orientation), not "UI" coordinates (which
        // are points and do reflect orientation).
        let scrSize = CGSize(width: cgImage.width, height: cgImage.height)
        var maxSizeRect = CGRect.zero
        maxSizeRect.size = CGSize(width: maxSize, height: maxSize)
        let newSize = AVMakeRect(aspectRatio: scrSize, insideRect: maxSizeRect).size

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo = [
            CGBitmapInfo(rawValue: CGImageByteOrderInfo.orderDefault.rawValue),
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)]
        guard let context = CGContext.init(data: nil,
                                           width: Int(newSize.width),
                                           height: Int(newSize.height),
                                           bitsPerComponent: 8,
                                           bytesPerRow: 0,
                                           space: colorSpace,
                                           bitmapInfo: bitmapInfo.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high

        var drawRect = CGRect.zero
        drawRect.size = newSize
        context.draw(cgImage, in: drawRect)

        guard let newCGImage = context.makeImage() else {
            return nil
        }
        return UIImage(cgImage: newCGImage,
                       scale: uiImage.scale,
                       orientation: uiImage.imageOrientation)
    }

    private class func doesImageHaveAcceptableFileSize(dataSource: (any DataSource), imageQuality: TSImageQuality) -> Bool {
        switch imageQuality {
        case .original:
            return true
        case .medium:
            return dataSource.dataLength < UInt(1024 * 1024)
        case .compact:
            return dataSource.dataLength < UInt(400 * 1024)
        }
    }

    private class func maxSizeForImage(image: UIImage, imageUploadQuality: TSImageQualityTier) -> CGFloat {
        switch imageUploadQuality {
        case .original:
            return max(image.size.width, image.size.height)
        case .high:
            return 2048
        case .mediumHigh:
            return 1536
        case .medium:
            return 1024
        case .mediumLow:
            return 768
        case .low:
            return 512
        }
    }

    private class func jpegCompressionQuality(imageUploadQuality: TSImageQualityTier) -> CGFloat {
        switch imageUploadQuality {
        case .original:
            return 1
        case .high:
            return 0.9
        case .mediumHigh:
            return 0.8
        case .medium:
            return 0.7
        case .mediumLow:
            return 0.6
        case .low:
            return 0.5
        }
    }

    private class func removeImageMetadata(attachment: SignalAttachment, using dependencies: Dependencies) -> SignalAttachment {
        guard let source = CGImageSourceCreateWithData(attachment.data as CFData, nil) else {
            let attachment = SignalAttachment(dataSource: DataSourceValue.empty(using: dependencies), dataType: attachment.dataType)
            attachment.error = .missingData
            return attachment
        }

        guard let type = CGImageSourceGetType(source) else {
            let attachment = SignalAttachment(dataSource: DataSourceValue.empty(using: dependencies), dataType: attachment.dataType)
            attachment.error = .invalidFileFormat
            return attachment
        }

        let count = CGImageSourceGetCount(source)
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData as CFMutableData, type, count, nil) else {
            attachment.error = .couldNotRemoveMetadata
            return attachment
        }

        let removeMetadataProperties: [String: AnyObject] =
        [
            kCGImagePropertyExifDictionary as String: kCFNull,
            kCGImagePropertyExifAuxDictionary as String: kCFNull,
            kCGImagePropertyGPSDictionary as String: kCFNull,
            kCGImagePropertyTIFFDictionary as String: kCFNull,
            kCGImagePropertyJFIFDictionary as String: kCFNull,
            kCGImagePropertyPNGDictionary as String: kCFNull,
            kCGImagePropertyIPTCDictionary as String: kCFNull,
            kCGImagePropertyMakerAppleDictionary as String: kCFNull
        ]

        for index in 0...count-1 {
            CGImageDestinationAddImageFromSource(destination, source, index, removeMetadataProperties as CFDictionary)
        }

        if CGImageDestinationFinalize(destination) {
            guard let dataSource = DataSourceValue(data: mutableData as Data, dataType: attachment.dataType, using: dependencies) else {
                attachment.error = .couldNotRemoveMetadata
                return attachment
            }

            let strippedAttachment = SignalAttachment(dataSource: dataSource, dataType: attachment.dataType)
            return strippedAttachment

        } else {
            attachment.error = .couldNotRemoveMetadata
            return attachment
        }
    }

    // MARK: Video Attachments

    // Factory method for video attachments.
    //
    // NOTE: The attachment returned by this method may not be valid.
    //       Check the attachment's error property.
    private class func videoAttachment(dataSource: (any DataSource)?, type: UTType, using dependencies: Dependencies) -> SignalAttachment {
        guard let dataSource = dataSource else {
            let dataSource = DataSourceValue.empty(using: dependencies)
            let attachment = SignalAttachment(dataSource: dataSource, dataType: type)
            attachment.error = .missingData
            return attachment
        }

        return newAttachment(
            dataSource: dataSource,
            type: type,
            validTypes: UTType.supportedVideoTypes,
            maxFileSize: MediaUtils.maxFileSizeVideo,
            using: dependencies
        )
    }

    public class func copyToVideoTempDir(url fromUrl: URL, using dependencies: Dependencies) throws -> URL {
        let baseDir = SignalAttachment.videoTempPath(using: dependencies)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? dependencies[singleton: .fileManager].ensureDirectoryExists(at: baseDir.path)
        let toUrl = baseDir.appendingPathComponent(fromUrl.lastPathComponent)

        try dependencies[singleton: .fileManager].copyItem(at: fromUrl, to: toUrl)

        return toUrl
    }

    private class func videoTempPath(using dependencies: Dependencies) -> URL {
        let videoDir = URL(fileURLWithPath: dependencies[singleton: .fileManager].temporaryDirectory)
            .appendingPathComponent("video")
        try? dependencies[singleton: .fileManager].ensureDirectoryExists(at: videoDir.path)
        return videoDir
    }

    public class func compressVideoAsMp4(
        dataSource: (any DataSource),
        type: UTType,
        using dependencies: Dependencies
    ) -> (AnyPublisher<SignalAttachment, Error>, AVAssetExportSession?) {
        guard let url = dataSource.dataUrl else {
            let attachment = SignalAttachment(dataSource: DataSourceValue.empty(using: dependencies), dataType: type)
            attachment.error = .missingData
            return (
                Just(attachment)
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher(),
                nil
            )
        }

        let asset = AVAsset(url: url)

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
            let attachment = SignalAttachment(dataSource: DataSourceValue.empty(using: dependencies), dataType: type)
            attachment.error = .couldNotConvertToMpeg4
            return (
                Just(attachment)
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher(),
                nil
            )
        }

        exportSession.shouldOptimizeForNetworkUse = true
        exportSession.outputFileType = AVFileType.mp4
        exportSession.metadataItemFilter = AVMetadataItemFilter.forSharing()

        let exportURL = videoTempPath(using: dependencies)
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        exportSession.outputURL = exportURL

        let publisher = Deferred {
            Future<SignalAttachment, Error> { resolver in
                exportSession.exportAsynchronously {
                    let baseFilename = dataSource.sourceFilename
                    let mp4Filename = baseFilename?.filenameWithoutExtension.appendingFileExtension("mp4")
                    
                    guard let dataSource = DataSourcePath(fileUrl: exportURL, sourceFilename: baseFilename, shouldDeleteOnDeinit: true, using: dependencies) else {
                        let attachment = SignalAttachment(dataSource: DataSourceValue.empty(using: dependencies), dataType: type)
                        attachment.error = .couldNotConvertToMpeg4
                        resolver(Result.success(attachment))
                        return
                    }
                    
                    dataSource.sourceFilename = mp4Filename
                    
                    let attachment = SignalAttachment(dataSource: dataSource, dataType: .mpeg4Movie)
                    resolver(Result.success(attachment))
                }
            }
        }
        .eraseToAnyPublisher()

        return (publisher, exportSession)
    }

    public struct VideoCompressionResult {
        public let attachmentPublisher: AnyPublisher<SignalAttachment, Error>
        public let exportSession: AVAssetExportSession?

        fileprivate init(attachmentPublisher: AnyPublisher<SignalAttachment, Error>, exportSession: AVAssetExportSession?) {
            self.attachmentPublisher = attachmentPublisher
            self.exportSession = exportSession
        }
    }

    public class func compressVideoAsMp4(dataSource: (any DataSource), type: UTType, using dependencies: Dependencies) -> VideoCompressionResult {
        let (attachmentPublisher, exportSession) = compressVideoAsMp4(dataSource: dataSource, type: type, using: dependencies)
        return VideoCompressionResult(attachmentPublisher: attachmentPublisher, exportSession: exportSession)
    }

    public class func isInvalidVideo(dataSource: (any DataSource), type: UTType) -> Bool {
        guard UTType.supportedVideoTypes.contains(type) else {
            // not a video
            return false
        }

        guard isValidOutputVideo(dataSource: dataSource, type: type) else {
            // found a video which needs to be converted
            return true
        }

        // It is a video, but it's not invalid
        return false
    }

    private class func isValidOutputVideo(dataSource: (any DataSource)?, type: UTType) -> Bool {
        guard
            let dataSource = dataSource,
            UTType.supportedOutputVideoTypes.contains(type),
            dataSource.dataLength <= MediaUtils.maxFileSizeVideo
        else { return false }
        
        return false
    }

    // MARK: Audio Attachments

    // Factory method for audio attachments.
    //
    // NOTE: The attachment returned by this method may not be valid.
    //       Check the attachment's error property.
    private class func audioAttachment(dataSource: (any DataSource)?, type: UTType, using dependencies: Dependencies) -> SignalAttachment {
        return newAttachment(
            dataSource: dataSource,
            type: type,
            validTypes: UTType.supportedAudioTypes,
            maxFileSize: MediaUtils.maxFileSizeAudio,
            using: dependencies
        )
    }

    // MARK: Generic Attachments

    // Factory method for generic attachments.
    //
    // NOTE: The attachment returned by this method may not be valid.
    //       Check the attachment's error property.
    private class func genericAttachment(dataSource: (any DataSource)?, type: UTType, using dependencies: Dependencies) -> SignalAttachment {
        return newAttachment(
            dataSource: dataSource,
            type: type,
            validTypes: nil,
            maxFileSize: MediaUtils.maxFileSizeGeneric,
            using: dependencies
        )
    }

    // MARK: Voice Messages

    public class func voiceMessageAttachment(dataSource: (any DataSource)?, type: UTType, using dependencies: Dependencies) -> SignalAttachment {
        let attachment = audioAttachment(dataSource: dataSource, type: type, using: dependencies)
        attachment.isVoiceMessage = true
        return attachment
    }

    // MARK: Attachments

    // Factory method for non-image Attachments.
    //
    // NOTE: The attachment returned by this method may not be valid.
    //       Check the attachment's error property.
    public class func attachment(dataSource: (any DataSource)?, type: UTType, using dependencies: Dependencies) -> SignalAttachment {
        return attachment(dataSource: dataSource, type: type, imageQuality: .original, using: dependencies)
    }

    // Factory method for attachments of any kind.
    //
    // NOTE: The attachment returned by this method may not be valid.
    //       Check the attachment's error property.
    public class func attachment(dataSource: (any DataSource)?, type: UTType, imageQuality: TSImageQuality, using dependencies: Dependencies) -> SignalAttachment {
        if UTType.supportedInputImageTypes.contains(type) {
            return imageAttachment(dataSource: dataSource, type: type, imageQuality: imageQuality, using: dependencies)
        } else if UTType.supportedVideoTypes.contains(type) {
            return videoAttachment(dataSource: dataSource, type: type, using: dependencies)
        } else if UTType.supportedAudioTypes.contains(type) {
            return audioAttachment(dataSource: dataSource, type: type, using: dependencies)
        }
        
        return genericAttachment(dataSource: dataSource, type: type, using: dependencies)
    }

    public class func empty(using dependencies: Dependencies) -> SignalAttachment {
        return SignalAttachment.attachment(
            dataSource: DataSourceValue.empty(using: dependencies),
            type: .content,
            imageQuality: .original,
            using: dependencies
        )
    }

    // MARK: Helper Methods

    private class func newAttachment(
        dataSource: (any DataSource)?,
        type: UTType,
        validTypes: Set<UTType>?,
        maxFileSize: UInt,
        using dependencies: Dependencies
    ) -> SignalAttachment {
        guard let dataSource = dataSource else {
            let attachment = SignalAttachment(dataSource: DataSourceValue.empty(using: dependencies), dataType: type)
            attachment.error = .missingData
            return attachment
        }

        let attachment = SignalAttachment(dataSource: dataSource, dataType: type)

        if let validTypes: Set<UTType> = validTypes {
            guard validTypes.contains(type) else {
                attachment.error = .invalidFileFormat
                return attachment
            }
        }

        guard dataSource.dataLength > 0 else {
            assert(dataSource.dataLength > 0)
            attachment.error = .invalidData
            return attachment
        }

        guard dataSource.dataLength <= maxFileSize else {
            attachment.error = .fileSizeTooLarge
            return attachment
        }

        // Attachment is valid
        return attachment
    }
    
    // MARK: - Equatable
    
    public static func == (lhs: SignalAttachment, rhs: SignalAttachment) -> Bool {
        switch (lhs.dataSource, rhs.dataSource) {
            case (let lhsDataSource as DataSourcePath, let rhsDataSource as DataSourcePath):
                guard lhsDataSource == rhsDataSource else { return false }
                break

            case (let lhsDataSource as DataSourceValue, let rhsDataSource as DataSourceValue):
                guard lhsDataSource == rhsDataSource else { return false }
                break

            default: return false
        }
        
        return (
            lhs.dataType == rhs.dataType &&
            lhs.captionText == rhs.captionText &&
            lhs.linkPreviewDraft == rhs.linkPreviewDraft &&
            lhs.isConvertibleToTextMessage == rhs.isConvertibleToTextMessage &&
            lhs.isConvertibleToContactShare == rhs.isConvertibleToContactShare &&
            lhs.cachedImage == rhs.cachedImage &&
            lhs.cachedVideoPreview == rhs.cachedVideoPreview &&
            lhs.isVoiceMessage == rhs.isVoiceMessage
        )
    }
}
