// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import AVFoundation

public enum MediaError: Error {
    case failure(description: String)
}

public enum MediaUtils {
    public static var maxFileSizeAnimatedImage: UInt { SNUtilitiesKitConfiguration.maxFileSize }
    public static var maxFileSizeImage: UInt { SNUtilitiesKitConfiguration.maxFileSize }
    public static var maxFileSizeVideo: UInt { SNUtilitiesKitConfiguration.maxFileSize }
    public static var maxFileSizeAudio: UInt { SNUtilitiesKitConfiguration.maxFileSize }
    public static var maxFileSizeGeneric: UInt { SNUtilitiesKitConfiguration.maxFileSize }

    public static let maxAnimatedImageDimensions: UInt = 1 * 1024
    public static let maxStillImageDimensions: UInt = 8 * 1024
    public static let maxVideoDimensions: CGFloat = 3 * 1024
    
    public static func thumbnail(forImageAtPath path: String, maxDimension: CGFloat) throws -> UIImage {
        SNLog("thumbnailing image: \(path)")

        guard FileManager.default.fileExists(atPath: path) else {
            throw MediaError.failure(description: "Media file missing.")
        }
        guard Data.isValidImage(at: path) else {
            throw MediaError.failure(description: "Invalid image.")
        }
        guard let originalImage = UIImage(contentsOfFile: path) else {
            throw MediaError.failure(description: "Could not load original image.")
        }
        guard let thumbnailImage = originalImage.resized(maxDimensionPoints: maxDimension) else {
            throw MediaError.failure(description: "Could not thumbnail image.")
        }
        return thumbnailImage
    }

    public static func thumbnail(forVideoAtPath path: String, maxDimension: CGFloat) throws -> UIImage {
        SNLog("thumbnailing video: \(path)")

        guard isVideoOfValidContentTypeAndSize(path: path) else {
            throw MediaError.failure(description: "Media file has missing or invalid length.")
        }

        let maxSize = CGSize(width: maxDimension, height: maxDimension)
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url, options: nil)
        guard isValidVideo(asset: asset) else {
            throw MediaError.failure(description: "Invalid video.")
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = maxSize
        generator.appliesPreferredTrackTransform = true
        let time: CMTime = CMTimeMake(value: 1, timescale: 60)
        let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
        let image = UIImage(cgImage: cgImage)
        return image
    }

    public static func isValidVideo(path: String) -> Bool {
        guard isVideoOfValidContentTypeAndSize(path: path) else {
            SNLog("Media file has missing or invalid length.")
            return false
        }

        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url, options: nil)
        return isValidVideo(asset: asset)
    }

    private static func isVideoOfValidContentTypeAndSize(path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else {
            SNLog("Media file missing.")
            return false
        }
        let fileExtension = URL(fileURLWithPath: path).pathExtension
        guard let contentType = MimeTypeUtil.mimeType(for: fileExtension) else {
            SNLog("Media file has unknown content type.")
            return false
        }
        guard MimeTypeUtil.isVideo(contentType) else {
            SNLog("Media file has invalid content type.")
            return false
        }

        guard let fileSize = FileSystem.fileSize(of: path) else {
            SNLog("Media file has unknown length.")
            return false
        }
        return UInt(fileSize) <= SNUtilitiesKitConfiguration.maxFileSize
    }

    private static func isValidVideo(asset: AVURLAsset) -> Bool {
        var maxTrackSize = CGSize.zero
        for track: AVAssetTrack in asset.tracks(withMediaType: .video) {
            let trackSize: CGSize = track.naturalSize
            maxTrackSize.width = max(maxTrackSize.width, trackSize.width)
            maxTrackSize.height = max(maxTrackSize.height, trackSize.height)
        }
        if maxTrackSize.width < 1.0 || maxTrackSize.height < 1.0 {
            SNLog("Invalid video size: \(maxTrackSize)")
            return false
        }
        if maxTrackSize.width > maxVideoDimensions || maxTrackSize.height > maxVideoDimensions {
            SNLog("Invalid video dimensions: \(maxTrackSize)")
            return false
        }
        return true
    }
}
