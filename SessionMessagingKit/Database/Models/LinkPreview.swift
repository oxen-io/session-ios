// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SignalCoreKit
import SessionUtilitiesKit
import SessionSnodeKit

public struct LinkPreview: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "linkPreview" }
    internal static let interactionForeignKey = ForeignKey(
        [Columns.url],
        to: [Interaction.Columns.linkPreviewUrl]
    )
    internal static let interactions = hasMany(Interaction.self, using: Interaction.linkPreviewForeignKey)
    public static let attachment = hasOne(Attachment.self, using: Attachment.linkPreviewForeignKey)
    
    /// We want to cache url previews to the nearest 100,000 seconds (~28 hours - simpler than 86,400) to ensure the user isn't shown a preview that is too stale
    internal static let timstampResolution: Double = 100000
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case url
        case timestamp
        case variant
        case title
        case attachmentId
    }
    
    public enum Variant: Int, Codable, Hashable, DatabaseValueConvertible {
        case standard
        case openGroupInvitation
    }
    
    /// The url for the link preview
    public let url: String
    
    /// The number of seconds since epoch rounded down to the nearest 100,000 seconds (~day) - This
    /// allows us to optimise against duplicate urls without having “stale” data last too long
    public let timestamp: TimeInterval
    
    /// The type of link preview
    public let variant: Variant
    
    /// The title for the link
    public let title: String?
    
    /// The id for the attachment for the link preview image
    public let attachmentId: String?
    
    // MARK: - Relationships
    
    public var attachment: QueryInterfaceRequest<Attachment> {
        request(for: LinkPreview.attachment)
    }
    
    // MARK: - Initialization
    
    public init(
        url: String,
        timestamp: TimeInterval = LinkPreview.timestampFor(
            sentTimestampMs: Double(SnodeAPI.currentOffsetTimestampMs())  // Default to now
        ),
        variant: Variant = .standard,
        title: String?,
        attachmentId: String? = nil
    ) {
        self.url = url
        self.timestamp = timestamp
        self.variant = variant
        self.title = title
        self.attachmentId = attachmentId
    }
}

// MARK: - Protobuf

public extension LinkPreview {
    init?(_ db: Database, proto: SNProtoDataMessage, sentTimestampMs: TimeInterval) throws {
        guard let previewProto = proto.preview.first else { throw LinkPreviewError.noPreview }
        guard URL(string: previewProto.url) != nil else { throw LinkPreviewError.invalidInput }
        guard LinkPreview.isValidLinkUrl(previewProto.url) else { throw LinkPreviewError.invalidInput }
        
        // Try to get an existing link preview first
        let timestamp: TimeInterval = LinkPreview.timestampFor(sentTimestampMs: sentTimestampMs)
        let maybeLinkPreview: LinkPreview? = try? LinkPreview
            .filter(LinkPreview.Columns.url == previewProto.url)
            .filter(LinkPreview.Columns.timestamp == timestamp)
            .fetchOne(db)
        
        if let linkPreview: LinkPreview = maybeLinkPreview {
            self = linkPreview
            return
        }
        
        self.url = previewProto.url
        self.timestamp = timestamp
        self.variant = .standard
        self.title = LinkPreview.normalizeTitle(title: previewProto.title)
        
        if let imageProto = previewProto.image {
            let attachment: Attachment = Attachment(proto: imageProto)
            try attachment.insert(db)
            
            self.attachmentId = attachment.id
        }
        else {
            self.attachmentId = nil
        }
        
        // Make sure the quote is valid before completing
        guard self.title != nil || self.attachmentId != nil else { throw LinkPreviewError.invalidInput }
    }
}

// MARK: - Convenience

public extension LinkPreview {
    struct URLMatchResult {
        let urlString: String
        let matchRange: NSRange
    }
    
    static func timestampFor(sentTimestampMs: Double) -> TimeInterval {
        // We want to round the timestamp down to the nearest 100,000 seconds (~28 hours - simpler
        // than 86,400) to optimise LinkPreview storage without having too stale data
        return (floor(sentTimestampMs / 1000 / LinkPreview.timstampResolution) * LinkPreview.timstampResolution)
    }
    
    static func generateAttachmentIfPossible(imageData: Data?, mimeType: String) throws -> Attachment? {
        guard let imageData: Data = imageData, !imageData.isEmpty else { return nil }
        guard let fileExtension: String = MimeTypeUtil.fileExtension(for: mimeType) else { return nil }
        
        let filePath = FileSystem.temporaryFilePath(fileExtension: fileExtension)
        try imageData.write(to: NSURL.fileURL(withPath: filePath), options: .atomicWrite)
        let dataSource: DataSourcePath = DataSourcePath(filePath: filePath, shouldDeleteOnDeinit: true)
        
        return Attachment(contentType: mimeType, dataSource: dataSource)
    }
    
    static func isValidLinkUrl(_ urlString: String) -> Bool {
        return URL(string: urlString) != nil
    }
    
    static func allPreviewUrls(forMessageBodyText body: String) -> [String] {
        return allPreviewUrlMatches(forMessageBodyText: body).map { $0.urlString }
    }
    
    // MARK: - Private Methods
    
    private static func allPreviewUrlMatches(forMessageBodyText body: String) -> [URLMatchResult] {
        let detector: NSDataDetector
        do {
            detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        }
        catch {
            return []
        }

        var urlMatches: [URLMatchResult] = []
        let matches = detector.matches(in: body, options: [], range: NSRange(location: 0, length: body.count))
        for match in matches {
            guard let matchURL = match.url else { continue }
            
            // If the URL entered didn't have a scheme it will default to 'http', we want to catch this and
            // set the scheme to 'https' instead as we don't load previews for 'http' so this will result
            // in more previews actually getting loaded without forcing the user to enter 'https://' before
            // every URL they enter
            let urlString: String = (matchURL.absoluteString == "http://\(body)" ?
                "https://\(body)" :
                matchURL.absoluteString
            )
            
            if isValidLinkUrl(urlString) {
                let matchResult = URLMatchResult(urlString: urlString, matchRange: match.range)
                urlMatches.append(matchResult)
            }
        }
        
        return urlMatches
    }
    
    fileprivate static func normalizeTitle(title: String?) -> String? {
        guard var result: String = title, !result.isEmpty else { return nil }
        
        // Truncate title after 2 lines of text.
        let maxLineCount = 2
        var components = result.components(separatedBy: .newlines)
        
        if components.count > maxLineCount {
            components = Array(components[0..<maxLineCount])
            result =  components.joined(separator: "\n")
        }
        
        let maxCharacterCount = 2048
        if result.count > maxCharacterCount {
            let endIndex = result.index(result.startIndex, offsetBy: maxCharacterCount)
            result = String(result[..<endIndex])
        }
        
        return result.filterStringForDisplay()
    }
    
    // MARK: - Text Parsing

    private static var previewUrlCache: Atomic<NSCache<NSString, NSString>> = Atomic(NSCache())

    static func previewUrl(
        for body: String?,
        selectedRange: NSRange? = nil,
        using dependencies: Dependencies = Dependencies()
    ) -> String? {
        guard dependencies[singleton: .storage, key: .areLinkPreviewsEnabled] else { return nil }
        guard let body: String = body else { return nil }

        if let cachedUrl = previewUrlCache.wrappedValue.object(forKey: body as NSString) as String? {
            guard cachedUrl.count > 0 else {
                return nil
            }
            
            return cachedUrl
        }
        
        let previewUrlMatches: [URLMatchResult] = allPreviewUrlMatches(forMessageBodyText: body)
        
        guard let urlMatch: URLMatchResult = previewUrlMatches.first else {
            // Use empty string to indicate "no preview URL" in the cache.
            previewUrlCache.mutate { $0.setObject("", forKey: body as NSString) }
            return nil
        }

        if let selectedRange: NSRange = selectedRange {
            let cursorAtEndOfMatch: Bool = (
                (urlMatch.matchRange.location + urlMatch.matchRange.length) == selectedRange.location
            )
            
            if selectedRange.location != body.count, (urlMatch.matchRange.intersection(selectedRange) != nil || cursorAtEndOfMatch) {
                // we don't want to cache the result here, as we want to fetch the link preview
                // if the user moves the cursor.
                return nil
            }
        }

        previewUrlCache.mutate { $0.setObject(urlMatch.urlString as NSString, forKey: body as NSString) }
        
        return urlMatch.urlString
    }
}

// MARK: - Drafts

public extension LinkPreview {
    private struct Contents {
        public var title: String?
        public var imageUrl: String?

        public init(title: String?, imageUrl: String? = nil) {
            self.title = title
            self.imageUrl = imageUrl
        }
    }
    
    private static let serialQueue = DispatchQueue(label: "org.signal.linkPreview")
    
    // This cache should only be accessed on serialQueue.
    //
    // We should only maintain a "cache" of the last known draft.
    private static var linkPreviewDraftCache: LinkPreviewDraft?
    
    // Twitter doesn't return OpenGraph tags to Signal
    // `curl -A Signal "https://twitter.com/signalapp/status/1280166087577997312?s=20"`
    // If this ever changes, we can switch back to our default User-Agent
    private static let userAgentString = "WhatsApp"
    
    private static func cachedLinkPreview(forPreviewUrl previewUrl: String) -> LinkPreviewDraft? {
        return serialQueue.sync {
            guard let linkPreviewDraft = linkPreviewDraftCache,
                linkPreviewDraft.urlString == previewUrl else {
                return nil
            }
            return linkPreviewDraft
        }
    }
    
    private static func setCachedLinkPreview(
        _ linkPreviewDraft: LinkPreviewDraft,
        forPreviewUrl previewUrl: String,
        using dependencies: Dependencies = Dependencies()
    ) {
        assert(previewUrl == linkPreviewDraft.urlString)

        // Exit early if link previews are not enabled in order to avoid
        // tainting the cache.
        guard dependencies[singleton: .storage, key: .areLinkPreviewsEnabled] else { return }

        serialQueue.sync {
            linkPreviewDraftCache = linkPreviewDraft
        }
    }
    
    static func tryToBuildPreviewInfo(
        previewUrl: String?,
        using dependencies: Dependencies
    ) -> AnyPublisher<LinkPreviewDraft, Error> {
        guard dependencies[singleton: .storage, key: .areLinkPreviewsEnabled] else {
            return Fail(error: LinkPreviewError.featureDisabled)
                .eraseToAnyPublisher()
        }
        guard let previewUrl: String = previewUrl else {
            return Fail(error: LinkPreviewError.invalidInput)
                .eraseToAnyPublisher()
        }
        
        if let cachedInfo = cachedLinkPreview(forPreviewUrl: previewUrl) {
            return Just(cachedInfo)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        return downloadLink(url: previewUrl)
            .flatMap { data, response in
                parseLinkDataAndBuildDraft(
                    linkData: data,
                    response: response,
                    linkUrlString: previewUrl,
                    using: dependencies
                )
            }
            .tryMap { linkPreviewDraft -> LinkPreviewDraft in
                guard linkPreviewDraft.isValid() else { throw LinkPreviewError.noPreview }
                
                setCachedLinkPreview(linkPreviewDraft, forPreviewUrl: previewUrl)

                return linkPreviewDraft
            }
            .eraseToAnyPublisher()
    }

    private static func downloadLink(
        url urlString: String,
        remainingRetries: UInt = 3
    ) -> AnyPublisher<(Data, URLResponse), Error> {
        Logger.verbose("url: \(urlString)")

        // let sessionConfiguration = ContentProxy.sessionConfiguration() // Loki: Signal's proxy appears to have been banned by YouTube
        let sessionConfiguration = URLSessionConfiguration.ephemeral

        // Don't use any caching to protect privacy of these requests.
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        
        guard
            var request: URLRequest = URL(string: urlString).map({ URLRequest(url: $0) }),
            ContentProxy.configureProxiedRequest(request: &request)
        else {
            return Fail(error: LinkPreviewError.assertionFailure)
                .eraseToAnyPublisher()
        }
        
        request.setValue(self.userAgentString, forHTTPHeaderField: "User-Agent") // Set a fake value

        let session: URLSession = URLSession(configuration: sessionConfiguration)
        
        return session
            .dataTaskPublisher(for: request)
            .mapError { _ -> Error in HTTPError.generic }   // URLError codes are negative values
            .tryMap { data, response -> (Data, URLResponse) in
                guard let urlResponse: HTTPURLResponse = response as? HTTPURLResponse else {
                    throw LinkPreviewError.assertionFailure
                }
                if let contentType: String = urlResponse.allHeaderFields["Content-Type"] as? String {
                    guard contentType.lowercased().hasPrefix("text/") else {
                        throw LinkPreviewError.invalidContent
                    }
                }
                guard data.count > 0 else { throw LinkPreviewError.invalidContent }
                
                return (data, response)
            }
            .catch { error -> AnyPublisher<(Data, URLResponse), Error> in
                guard isRetryable(error: error), remainingRetries > 0 else {
                    return Fail(error: LinkPreviewError.couldNotDownload)
                        .eraseToAnyPublisher()
                }
                
                return LinkPreview
                    .downloadLink(
                        url: urlString,
                        remainingRetries: (remainingRetries - 1)
                    )
            }
            .eraseToAnyPublisher()
    }
    
    private static func parseLinkDataAndBuildDraft(
        linkData: Data,
        response: URLResponse,
        linkUrlString: String,
        using dependencies: Dependencies
    ) -> AnyPublisher<LinkPreviewDraft, Error> {
        do {
            let contents = try parse(linkData: linkData, response: response)

            let title = contents.title
            guard let imageUrl = contents.imageUrl else {
                return Just(LinkPreviewDraft(urlString: linkUrlString, title: title))
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            }

            guard URL(string: imageUrl) != nil else {
                return Just(LinkPreviewDraft(urlString: linkUrlString, title: title))
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            }
            guard let imageFileExtension = fileExtension(forImageUrl: imageUrl) else {
                return Just(LinkPreviewDraft(urlString: linkUrlString, title: title))
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            }
            guard let imageMimeType = mimetype(forImageFileExtension: imageFileExtension) else {
                return Just(LinkPreviewDraft(urlString: linkUrlString, title: title))
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            }

            return LinkPreview
                .downloadImage(url: imageUrl, imageMimeType: imageMimeType, using: dependencies)
                .map { imageData -> LinkPreviewDraft in
                    // We always recompress images to Jpeg
                    LinkPreviewDraft(urlString: linkUrlString, title: title, jpegImageData: imageData)
                }
                .catch { _ -> AnyPublisher<LinkPreviewDraft, Error> in
                    return Just(LinkPreviewDraft(urlString: linkUrlString, title: title))
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                .eraseToAnyPublisher()
        } catch {
            return Fail(error: error)
                .eraseToAnyPublisher()
        }
    }
    
    private static func parse(linkData: Data, response: URLResponse) throws -> Contents {
        guard let linkText = String(bytes: linkData, encoding: response.stringEncoding ?? .utf8) else {
            print("Could not parse link text.")
            throw LinkPreviewError.invalidInput
        }
        
        let content = HTMLMetadata.construct(parsing: linkText)

        var title: String?
        let rawTitle = content.ogTitle ?? content.titleTag
        if
            let decodedTitle: String = decodeHTMLEntities(inString: rawTitle ?? ""),
            let normalizedTitle: String = LinkPreview.normalizeTitle(title: decodedTitle),
            normalizedTitle.count > 0
        {
            title = normalizedTitle
        }

        Logger.verbose("title: \(String(describing: title))")

        guard let rawImageUrlString = content.ogImageUrlString ?? content.faviconUrlString else {
            return Contents(title: title)
        }
        guard let imageUrlString = decodeHTMLEntities(inString: rawImageUrlString)?.ows_stripped() else {
            return Contents(title: title)
        }

        return Contents(title: title, imageUrl: imageUrlString)
    }
    
    private static func downloadImage(
        url urlString: String,
        imageMimeType: String,
        using dependencies: Dependencies
    ) -> AnyPublisher<Data, Error> {
        guard
            let url = URL(string: urlString),
            let assetDescription: ProxiedContentAssetDescription = ProxiedContentAssetDescription(
                url: url as NSURL
            )
        else {
            return Fail(error: LinkPreviewError.invalidInput)
                .eraseToAnyPublisher()
        }
        
        return dependencies[singleton: .proxiedContentDownloader]
            .requestAsset(
                assetDescription: assetDescription,
                priority: .high,
                shouldIgnoreSignalProxy: true
            )
            .tryMap { asset, _ -> Data in
                let imageSize = Data.imageSize(for: asset.filePath, mimeType: imageMimeType)
                
                guard imageSize.width > 0, imageSize.height > 0 else {
                    throw LinkPreviewError.invalidContent
                }
                
                guard let data: Data = try? Data(contentsOf: URL(fileURLWithPath: asset.filePath)) else {
                    throw LinkPreviewError.assertionFailure
                }

                guard let srcImage = UIImage(data: data) else { throw LinkPreviewError.invalidContent }
                
                // Loki: If it's a GIF then ensure its validity and don't download it as a JPG
                if
                    imageMimeType == MimeTypeUtil.MimeType.imageGif &&
                    data.isValidImage(mimeType: MimeTypeUtil.MimeType.imageGif)
                {
                    return data
                }

                let maxImageSize: CGFloat = 1024
                let shouldResize = imageSize.width > maxImageSize || imageSize.height > maxImageSize
                
                guard shouldResize else {
                    guard let dstData = srcImage.jpegData(compressionQuality: 0.8) else {
                        throw LinkPreviewError.invalidContent
                    }
                    
                    return dstData
                }

                guard
                    let dstImage = srcImage.resized(maxDimensionPoints: maxImageSize),
                    let dstData = dstImage.jpegData(compressionQuality: 0.8)
                else { throw LinkPreviewError.invalidContent }
                
                return dstData
            }
            .mapError { _ -> Error in LinkPreviewError.couldNotDownload }
            .eraseToAnyPublisher()
    }
    
    private static func isRetryable(error: Error) -> Bool {
        if (error as NSError).domain == kCFErrorDomainCFNetwork as String {
            // Network failures are retried.
            return true
        }
        
        return false
    }
    
    private static func fileExtension(forImageUrl urlString: String) -> String? {
        guard let imageUrl = URL(string: urlString) else { return nil }
        
        let imageFilename = imageUrl.lastPathComponent
        let imageFileExtension = (imageFilename as NSString).pathExtension.lowercased()
        
        guard imageFileExtension.count > 0 else {
            // TODO: For those links don't have a file extension, we should figure out a way to know the image mime type
            return "png"
        }
        
        return imageFileExtension
    }
    
    private static func mimetype(forImageFileExtension imageFileExtension: String) -> String? {
        guard imageFileExtension.count > 0 else { return nil }
        
        return MimeTypeUtil.mimeType(for: imageFileExtension)
    }
    
    private static func decodeHTMLEntities(inString value: String) -> String? {
        guard let data = value.data(using: .utf8) else { return nil }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]

        guard let attributedString = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return nil
        }

        return attributedString.string
    }
}
