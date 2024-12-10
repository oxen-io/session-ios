// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import CoreServices
import UniformTypeIdentifiers
import SignalUtilitiesKit
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let giphyDownloader: SingletonConfig<ProxiedContentDownloader> = Dependencies.create(
        identifier: "giphyDownloader",
        createInstance: { dependencies in
            ProxiedContentDownloader(
                downloadFolderName: "GIFs", // stringlint:ignore
                using: dependencies
            )
        }
    )
}

// MARK: - Log.Category

public extension Log.Category {
    static let giphy: Log.Category = .create("Giphy", defaultLevel: .info)
}

// MARK: - GiphyFormat

// There's no UTI type for webp!
enum GiphyFormat {
    case gif, mp4, jpg
}

enum GiphyError: Error, CustomStringConvertible {
    case assertionError(description: String)
    case fetchFailure
    
    var description: String {
        return "errorUnknown".localized()
    }
}

// Represents a "rendition" of a GIF.
// Giphy offers a plethora of renditions for each image.
// They vary in content size (i.e. width,  height), 
// format (.jpg, .gif, .mp4, webp, etc.),
// quality, etc.
// stringlint:ignore_contents
class GiphyRendition: ProxiedContentAssetDescription {
    let format: GiphyFormat
    let name: String
    let width: UInt
    let height: UInt
    let fileSize: UInt

    init?(
        format: GiphyFormat,
        name: String,
        width: UInt,
        height: UInt,
        fileSize: UInt,
        url: NSURL
    ) {
        self.format = format
        self.name = name
        self.width = width
        self.height = height
        self.fileSize = fileSize

        let fileExtension = GiphyRendition.fileExtension(forFormat: format)
        super.init(url: url, fileExtension: fileExtension)
    }

    private class func fileExtension(forFormat format: GiphyFormat) -> String {
        switch format {
            case .gif: return "gif"
            case .mp4: return "mp4"
            case .jpg: return "jpg"
        }
    }

    public var type: UTType {
        switch format {
            case .gif: return .gif
            case .mp4: return .mpeg4Movie
            case .jpg: return .jpeg
        }
    }

    public var isStill: Bool {
        return name.hasSuffix("_still")
    }

    public var isDownsampled: Bool {
        return name.hasSuffix("_downsampled")
    }

    public func log() {
        Log.verbose(.giphy, "\t \(format), \(name), \(width), \(height), \(fileSize)")
    }
    
    public static func == (lhs: GiphyRendition, rhs: GiphyRendition) -> Bool {
        return (
            lhs.url == rhs.url &&
            lhs.fileExtension == rhs.fileExtension &&
            lhs.format == rhs.format &&
            lhs.name == rhs.name &&
            lhs.width == rhs.width &&
            lhs.height == rhs.height &&
            lhs.fileSize == rhs.fileSize
        )
    }
}

// Represents a single Giphy image.
class GiphyImageInfo: NSObject {
    let giphyId: String
    let renditions: [GiphyRendition]
    // We special-case the "original" rendition because it is the 
    // source of truth for the aspect ratio of the image.
    let originalRendition: GiphyRendition

    init(giphyId: String,
         renditions: [GiphyRendition],
         originalRendition: GiphyRendition) {
        self.giphyId = giphyId
        self.renditions = renditions
        self.originalRendition = originalRendition
    }

    // TODO: We may need to tweak these constants.
    let kMaxDimension = UInt(618)
    let kMinPreviewDimension = UInt(60)
    let kMinSendingDimension = UInt(101)
    let kPreferedPreviewFileSize = UInt(256 * 1024)
    let kPreferedSendingFileSize = UInt(3 * 1024 * 1024)

    private enum PickingStrategy {
        case smallerIsBetter, largerIsBetter
    }

    public func log() {
        Log.verbose(.giphy, "GiphyId: \(giphyId), \(renditions.count)")
        for rendition in renditions {
            rendition.log()
        }
    }

    public func pickStillRendition() -> GiphyRendition? {
        // Stills are just temporary placeholders, so use the smallest still possible.
        return pickRendition(renditionType: .stillPreview, pickingStrategy: .smallerIsBetter, maxFileSize: kPreferedPreviewFileSize)
    }

    public func pickPreviewRendition() -> GiphyRendition? {
        // Try to pick a small file...
        if let rendition = pickRendition(renditionType: .animatedLowQuality, pickingStrategy: .largerIsBetter, maxFileSize: kPreferedPreviewFileSize) {
            return rendition
        }
        // ...but gradually relax the file restriction...
        if let rendition = pickRendition(renditionType: .animatedLowQuality, pickingStrategy: .smallerIsBetter, maxFileSize: kPreferedPreviewFileSize * 2) {
            return rendition
        }
        // ...and relax even more until we find an animated rendition.
        return pickRendition(renditionType: .animatedLowQuality, pickingStrategy: .smallerIsBetter, maxFileSize: kPreferedPreviewFileSize * 3)
    }

    public func pickSendingRendition() -> GiphyRendition? {
        // Try to pick a small file...
        if let rendition = pickRendition(renditionType: .animatedHighQuality, pickingStrategy: .largerIsBetter, maxFileSize: kPreferedSendingFileSize) {
            return rendition
        }
        // ...but gradually relax the file restriction...
        if let rendition = pickRendition(renditionType: .animatedHighQuality, pickingStrategy: .smallerIsBetter, maxFileSize: kPreferedSendingFileSize * 2) {
            return rendition
        }
        // ...and relax even more until we find an animated rendition.
        return pickRendition(renditionType: .animatedHighQuality, pickingStrategy: .smallerIsBetter, maxFileSize: kPreferedSendingFileSize * 3)
    }

    enum RenditionType {
        case stillPreview, animatedLowQuality, animatedHighQuality
    }

    // Picking a rendition must be done very carefully.
    //
    // * We want to avoid incomplete renditions.
    // * We want to pick a rendition of "just good enough" quality.
    private func pickRendition(renditionType: RenditionType, pickingStrategy: PickingStrategy, maxFileSize: UInt) -> GiphyRendition? {
        var bestRendition: GiphyRendition?

        for rendition in renditions {
            switch renditionType {
            case .stillPreview:
                // Accept GIF or JPEG stills.  In practice we'll
                // usually select a JPEG since they'll be smaller.
                guard [.gif, .jpg].contains(rendition.format) else {
                    continue
                }
                // Only consider still renditions.
                guard rendition.isStill else {
                        continue
                }
                // Accept still renditions without a valid file size.  Note that fileSize
                // will be zero for renditions without a valid file size, so they will pass
                // the maxFileSize test.
                //
                // Don't worry about max content size; still images are tiny in comparison
                // with animated renditions.
                guard rendition.width >= kMinPreviewDimension &&
                    rendition.height >= kMinPreviewDimension &&
                    rendition.fileSize <= maxFileSize
                    else {
                        continue
                }
            case .animatedLowQuality:
                // Only use GIFs for animated renditions.
                guard rendition.format == .gif else {
                    continue
                }
                // Ignore stills.
                guard !rendition.isStill else {
                        continue
                }
                // Ignore "downsampled" renditions which skip frames, etc.
                guard !rendition.isDownsampled else {
                        continue
                }
                guard rendition.width >= kMinPreviewDimension &&
                    rendition.width <= kMaxDimension &&
                    rendition.height >= kMinPreviewDimension &&
                    rendition.height <= kMaxDimension &&
                    rendition.fileSize > 0 &&
                    rendition.fileSize <= maxFileSize
                    else {
                        continue
                }
            case .animatedHighQuality:
                // Only use GIFs for animated renditions.
                guard rendition.format == .gif else {
                    continue
                }
                // Ignore stills.
                guard !rendition.isStill else {
                    continue
                }
                // Ignore "downsampled" renditions which skip frames, etc.
                guard !rendition.isDownsampled else {
                    continue
                }
                guard rendition.width >= kMinSendingDimension &&
                    rendition.width <= kMaxDimension &&
                    rendition.height >= kMinSendingDimension &&
                    rendition.height <= kMaxDimension &&
                    rendition.fileSize > 0 &&
                    rendition.fileSize <= maxFileSize
                    else {
                        continue
                }
            }

            if let currentBestRendition = bestRendition {
                if rendition.width == currentBestRendition.width &&
                    rendition.fileSize > 0 &&
                    currentBestRendition.fileSize > 0 &&
                    rendition.fileSize < currentBestRendition.fileSize {
                    // If two renditions have the same content size, prefer
                    // the rendition with the smaller file size, e.g.
                    // prefer JPEG over GIF for stills.
                    bestRendition = rendition
                } else if pickingStrategy == .smallerIsBetter {
                    // "Smaller is better"
                    if rendition.width < currentBestRendition.width {
                        bestRendition = rendition
                    }
                } else {
                    // "Larger is better"
                    if rendition.width > currentBestRendition.width {
                        bestRendition = rendition
                    }
                }
            } else {
                bestRendition = rendition
            }
        }

        return bestRendition
    }
}

enum GiphyAPI {
    private static let kGiphyBaseURL = "https://api.giphy.com"
    private static let urlSession: URLSession = {
        let configuration: URLSessionConfiguration = ContentProxy.sessionConfiguration()
        
        // Don't use any caching to protect privacy of these requests.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringCacheData
        
        return URLSession(configuration: configuration)
    }()

    // MARK: - Search
    
    // This is the Signal iOS API key.
    private static let kGiphyApiKey = "ZsUpUm2L6cVbvei347EQNp7HrROjbOdc"      // stringlint:ignore
    private static let kGiphyPageSize = 20
    
    // stringlint:ignore_contents
    public static func trending() -> AnyPublisher<[GiphyImageInfo], Error> {
        let urlString = "/v1/gifs/trending?api_key=\(kGiphyApiKey)&limit=\(kGiphyPageSize)"
        
        guard let url: URL = URL(string: "\(kGiphyBaseURL)\(urlString)") else {
            return Fail(error: NetworkError.invalidURL)
                .eraseToAnyPublisher()
        }
        
        return urlSession
            .dataTaskPublisher(for: url)
            .mapError { urlError in
                Log.verbose(.giphy, "Search request failed: \(urlError)")
                
                // URLError codes are negative values
                return NetworkError.unknown
            }
            .map { data, _ in
                Log.verbose(.giphy, "Search request succeeded")
                
                guard let imageInfos = self.parseGiphyImages(responseData: data) else {
                    Log.error(.giphy, "Unable to parse trending images")
                    return []
                }
                
                return imageInfos
            }
            .eraseToAnyPublisher()
    }

    // stringlint:ignore_contents
    public static func search(query: String) -> AnyPublisher<[GiphyImageInfo], Error> {
        let kGiphyPageOffset = 0
        
        guard
            let queryEncoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let url: URL = URL(
                string: [
                    kGiphyBaseURL,
                    "/v1/gifs/search?api_key=\(kGiphyApiKey)",
                    "&offset=\(kGiphyPageOffset)",
                    "&limit=\(kGiphyPageSize)",
                    "&q=\(queryEncoded)"
                ].joined()
            )
        else {
            return Fail(error: NetworkError.invalidURL)
                .eraseToAnyPublisher()
        }
        
        var request: URLRequest = URLRequest(url: url)
        
        guard ContentProxy.configureProxiedRequest(request: &request) else {
            Log.error(.giphy, "Could not configure query: \(query).")
            return Fail(error: NetworkError.invalidPreparedRequest)
                .eraseToAnyPublisher()
        }
        
        return urlSession
            .dataTaskPublisher(for: request)
            .mapError { urlError in
                Log.error(.giphy, "Search request failed: \(urlError)")
                
                // URLError codes are negative values
                return NetworkError.unknown
            }
            .tryMap { data, _ -> [GiphyImageInfo] in
                Log.verbose(.giphy, "Search request succeeded")
                
                guard let imageInfos = self.parseGiphyImages(responseData: data) else {
                    throw NetworkError.invalidResponse
                }
                
                return imageInfos
            }
            .eraseToAnyPublisher()
    }

    // MARK: - Parse API Responses

    // stringlint:ignore_contents
    private static func parseGiphyImages(responseData: Data?) -> [GiphyImageInfo]? {
        guard let responseData: Data = responseData else {
            Log.error(.giphy, "Missing response.")
            return nil
        }
        guard let responseDict: [String: Any] = try? JSONSerialization
            .jsonObject(with: responseData, options: [ .fragmentsAllowed ]) as? [String: Any] else {
            Log.error(.giphy, "Invalid response.")
            return nil
        }
        guard let imageDicts = responseDict["data"] as? [[String: Any]] else {
            Log.error(.giphy, "Invalid response data.")
            return nil
        }
        return imageDicts.compactMap { imageDict in
            return parseGiphyImage(imageDict: imageDict)
        }
    }

    // Giphy API results are often incomplete or malformed, so we need to be defensive.
    // stringlint:ignore_contents
    private static func parseGiphyImage(imageDict: [String: Any]) -> GiphyImageInfo? {
        guard let giphyId = imageDict["id"] as? String else {
            Log.warn(.giphy, "Image dict missing id.")
            return nil
        }
        guard giphyId.count > 0 else {
            Log.warn(.giphy, "Image dict has invalid id.")
            return nil
        }
        guard let renditionDicts = imageDict["images"] as? [String: Any] else {
            Log.warn(.giphy, "Image dict missing renditions.")
            return nil
        }
        var renditions = [GiphyRendition]()
        for (renditionName, renditionDict) in renditionDicts {
            guard let renditionDict = renditionDict as? [String: Any] else {
                Log.warn(.giphy, "Invalid rendition dict.")
                continue
            }
            guard let rendition = parseGiphyRendition(renditionName: renditionName,
                                                      renditionDict: renditionDict) else {
                                                        continue
            }
            renditions.append(rendition)
        }
        guard renditions.count > 0 else {
            Log.warn(.giphy, "Image has no valid renditions.")
            return nil
        }

        guard let originalRendition = findOriginalRendition(renditions: renditions) else {
            Log.warn(.giphy, "Image has no original rendition.")
            return nil
        }

        return GiphyImageInfo(
            giphyId: giphyId,
            renditions: renditions,
            originalRendition: originalRendition
        )
    }

    // stringlint:ignore_contents
    private static func findOriginalRendition(renditions: [GiphyRendition]) -> GiphyRendition? {
        for rendition in renditions where rendition.name == "original" {
            return rendition
        }
        return nil
    }

    // Giphy API results are often incomplete or malformed, so we need to be defensive.
    //
    // We should discard renditions which are missing or have invalid properties.
    // stringlint:ignore_contents
    private static func parseGiphyRendition(
        renditionName: String,
        renditionDict: [String: Any]
    ) -> GiphyRendition? {
        guard let width = parsePositiveUInt(dict: renditionDict, key: "width", typeName: "rendition") else {
            return nil
        }
        guard let height = parsePositiveUInt(dict: renditionDict, key: "height", typeName: "rendition") else {
            return nil
        }
        // Be lenient when parsing file sizes - we don't require them for stills.
        let fileSize = parseLenientUInt(dict: renditionDict, key: "size")
        guard let urlString = renditionDict["url"] as? String else {
            return nil
        }
        guard urlString.count > 0 else {
            Log.warn(.giphy, "Rendition has invalid url.")
            return nil
        }
        guard let url = NSURL(string: urlString) else {
            Log.warn(.giphy, "Rendition url could not be parsed.")
            return nil
        }
        guard let fileExtension = url.pathExtension?.lowercased() else {
            Log.warn(.giphy, "Rendition url missing file extension.")
            return nil
        }
        var format = GiphyFormat.gif
        if fileExtension == "gif" {
            format = .gif
        } else if fileExtension == "jpg" {
            format = .jpg
        } else if fileExtension == "mp4" {
            format = .mp4
        } else if fileExtension == "webp" {
            return nil
        } else {
            Log.warn(.giphy, "Invalid file extension: \(fileExtension).")
            return nil
        }

        return GiphyRendition(
            format: format,
            name: renditionName,
            width: width,
            height: height,
            fileSize: fileSize,
            url: url
        )
    }

    private static func parsePositiveUInt(dict: [String: Any], key: String, typeName: String) -> UInt? {
        guard let value = dict[key] else {
            return nil
        }
        guard let stringValue = value as? String else {
            return nil
        }
        guard let parsedValue = UInt(stringValue) else {
            return nil
        }
        guard parsedValue > 0 else {
            Log.verbose(.giphy, "\(typeName) has non-positive \(key): \(parsedValue).")
            return nil
        }
        return parsedValue
    }

    private static func parseLenientUInt(dict: [String: Any], key: String) -> UInt {
        let defaultValue = UInt(0)

        guard let value = dict[key] else {
            return defaultValue
        }
        guard let stringValue = value as? String else {
            return defaultValue
        }
        guard let parsedValue = UInt(stringValue) else {
            return defaultValue
        }
        return parsedValue
    }
}
