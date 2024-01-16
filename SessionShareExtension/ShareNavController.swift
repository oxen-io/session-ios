// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import CoreServices
import SignalUtilitiesKit
import SessionUIKit
import SessionUtilitiesKit
import SessionMessagingKit
import SignalCoreKit

final class ShareNavController: UINavigationController, ShareViewDelegate {
    public static var attachmentPrepPublisher: AnyPublisher<[SignalAttachment], Error>?
    
    /// The `ShareNavController` is initialized from a storyboard so we need to manually initialize this
    private let dependencies: Dependencies = Dependencies()
    private let versionMigrationsComplete: Atomic<Bool> = Atomic(false)
    
    // MARK: - Error
    
    enum ShareViewControllerError: Error {
        case assertionError(description: String)
        case unsupportedMedia
        case notRegistered
        case obsoleteShare
    }
    
    // MARK: - Lifecycle
    
    override func loadView() {
        super.loadView()
        
        view.themeBackgroundColor = .backgroundPrimary

        /// This should be the first thing we do (Note: If you leave the share context and return to it the context will already exist, trying
        /// to override it results in the share context crashing so ensure it doesn't exist first)
        if !dependencies.hasInitialised(singleton: .appContext) {
            dependencies.set(singleton: .appContext, to: ShareAppExtensionContext(rootViewController: self))
            Dependencies.setIsRTLRetriever(requiresMainThread: false) { ShareAppExtensionContext.determineDeviceRTL() }
        }
        
        Logger.info("")

        AppVersion.configure(using: dependencies)

        Cryptography.seedRandom()

        // We don't need to use DeviceSleepManager in the SAE.

        // We don't need to use applySignalAppearence in the SAE.

        if SNUtilitiesKit.isRunningTests {
            // TODO: Do we need to implement isRunningTests in the SAE context?
            return
        }

        AppSetup.setupEnvironment(
            migrationsCompletion: { [weak self, dependencies] result, needsConfigSync in
                switch result {
                    case .failure: SNLog("[SessionShareExtension] Failed to complete migrations")
                    case .success:
                        DispatchQueue.main.async {
                            // Need to manually trigger these since we don't have a "mainWindow" here
                            // and the current theme might have been changed since the share extension
                            // was last opened
                            ThemeManager.applySavedTheme(using: dependencies)
                            
                            // performUpdateCheck must be invoked after Environment has been initialized because
                            // upgrade process may depend on Environment.
                            self?.versionMigrationsDidComplete(needsConfigSync: needsConfigSync)
                        }
                }
            },
            using: dependencies
        )

        // We don't need to use "screen protection" in the SAE.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground),
            name: .sessionDidEnterBackground,
            object: nil
        )
        
        /// **Note:** If the user opens, dismisses and re-opens the share extension it'll actually use the same instance which
        /// results in the `AppSetup` not actually running (and the UI not actually being loaded correctly) - in order to avoid this
        /// we call `checkIsAppReady` explicitly here assuming that either the `AppSetup` _hasn't_ complete or won't ever
        /// get run
        checkIsAppReady(migrationsCompleted: versionMigrationsComplete.wrappedValue)
    }
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        
        // Note: The share extension doesn't have a proper window so we need to manually update
        // the ThemeManager from here
        ThemeManager.traitCollectionDidChange(previousTraitCollection)
    }

    func versionMigrationsDidComplete(needsConfigSync: Bool) {
        AssertIsOnMainThread()

        Logger.debug("")

        // If we need a config sync then trigger it now
        if needsConfigSync {
            dependencies[singleton: .storage].write { [dependencies] db in
                ConfigurationSyncJob.enqueue(
                    db,
                    sessionIdHexString: getUserSessionId(db, using: dependencies).hexString,
                    using: dependencies
                )
            }
        }

        versionMigrationsComplete.mutate { $0 = true }
        checkIsAppReady(migrationsCompleted: true)
    }

    func checkIsAppReady(migrationsCompleted: Bool) {
        AssertIsOnMainThread()

        // App isn't ready until storage is ready AND all version migrations are complete.
        guard migrationsCompleted else { return }
        guard dependencies[singleton: .storage].isValid else {
            // If the database is invalid then the UI will handle it
            showLockScreenOrMainContent()
            return
        }
        guard !dependencies[singleton: .appReadiness].isAppReady else {
            // Only mark the app as ready once.
            showLockScreenOrMainContent()
            return
        }

        SignalUtilitiesKit.Configuration.performMainSetup(using: dependencies)

        Logger.debug("")

        // Note that this does much more than set a flag;
        // it will also run all deferred blocks.
        dependencies[singleton: .appReadiness].setAppReady()

        // We don't need to use messageFetcherJob in the SAE.
        // We don't need to use SyncPushTokensJob in the SAE.
        // We don't need to use DeviceSleepManager in the SAE.

        AppVersion.shared.saeLaunchDidComplete(using: dependencies)

        showLockScreenOrMainContent()

        // We don't need to use OWSMessageReceiver in the SAE.
        // We don't need to use OWSBatchMessageProcessor in the SAE.
        // We don't need to fetch the local profile in the SAE
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        dependencies[singleton: .appReadiness].runNowOrWhenAppDidBecomeReady { [weak self] in
            AssertIsOnMainThread()
            self?.showLockScreenOrMainContent()
        }
    }

    @objc
    public func applicationDidEnterBackground() {
        AssertIsOnMainThread()

        Logger.info("")
        
        if dependencies[singleton: .storage, key: .isScreenLockEnabled] {
            self.dismiss(animated: false) { [weak self] in
                AssertIsOnMainThread()
                self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)

        // Share extensions reside in a process that may be reused between usages.
        // That isn't safe; the codebase is full of statics (e.g. singletons) which
        // we can't easily clean up.
        exit(0)
    }
    
    // MARK: - Updating
    
    private func showLockScreenOrMainContent() {
        if dependencies[singleton: .storage, key: .isScreenLockEnabled] {
            showLockScreen()
        }
        else {
            showMainContent()
        }
    }
    
    private func showLockScreen() {
        let screenLockVC = SAEScreenLockViewController(shareViewDelegate: self)
        setViewControllers([ screenLockVC ], animated: false)
    }
    
    private func showMainContent() {
        let threadPickerVC: ThreadPickerVC = ThreadPickerVC(using: dependencies)
        threadPickerVC.shareNavController = self
        
        setViewControllers([ threadPickerVC ], animated: false)
        
        let publisher = buildAttachments()
        ModalActivityIndicatorViewController
            .present(
                fromViewController: self,
                canCancel: false,
                message: "vc_share_loading_message".localized()
            ) { activityIndicator in
                publisher
                    .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                    .receive(on: DispatchQueue.main)
                    .sinkUntilComplete(
                        receiveCompletion: { _ in activityIndicator.dismiss { } }
                    )
            }
        ShareNavController.attachmentPrepPublisher = publisher
    }
    
    func shareViewWasUnlocked() {
        showMainContent()
    }
    
    func shareViewWasCompleted() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
    
    func shareViewWasCancelled() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
    
    func shareViewFailed(error: Error) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.shareViewFailed(error: error)
            }
            return
        }
        
        let modal: ConfirmationModal = ConfirmationModal(
            targetView: self.view,
            info: ConfirmationModal.Info(
                title: "Session",
                body: .text(error.localizedDescription),
                cancelTitle: "BUTTON_OK".localized(),
                cancelStyle: .alert_text,
                afterClosed: { [weak self] in self?.extensionContext?.cancelRequest(withError: error) }
            )
        )
        self.present(modal, animated: true)
    }
    
    // MARK: Attachment Prep
    private class func itemMatchesSpecificUtiType(itemProvider: NSItemProvider, utiType: String) -> Bool {
        // URLs, contacts and other special items have to be detected separately.
        // Many shares (e.g. pdfs) will register many UTI types and/or conform to kUTTypeData.
        guard itemProvider.registeredTypeIdentifiers.count == 1 else {
            return false
        }
        guard let firstUtiType = itemProvider.registeredTypeIdentifiers.first else {
            return false
        }
        
        return (firstUtiType == utiType)
    }

    private class func isVisualMediaItem(itemProvider: NSItemProvider) -> Bool {
        return (
            itemProvider.hasItemConformingToTypeIdentifier(kUTTypeImage as String) ||
            itemProvider.hasItemConformingToTypeIdentifier(kUTTypeMovie as String)
        )
    }

    private class func isUrlItem(itemProvider: NSItemProvider) -> Bool {
        return itemMatchesSpecificUtiType(
            itemProvider: itemProvider,
            utiType: kUTTypeURL as String
        )
    }

    private class func isContactItem(itemProvider: NSItemProvider) -> Bool {
        return itemMatchesSpecificUtiType(
            itemProvider: itemProvider,
            utiType: kUTTypeContact as String
        )
    }

    private class func utiType(itemProvider: NSItemProvider) -> String? {
        Logger.info("utiTypeForItem: \(itemProvider.registeredTypeIdentifiers)")

        if isUrlItem(itemProvider: itemProvider) {
            return kUTTypeURL as String
        }
        else if isContactItem(itemProvider: itemProvider) {
            return kUTTypeContact as String
        }

        // Use the first UTI that conforms to "data".
        let matchingUtiType = itemProvider.registeredTypeIdentifiers.first { (utiType: String) -> Bool in
            UTTypeConformsTo(utiType as CFString, kUTTypeData)
        }
        return matchingUtiType
    }

    private class func createDataSource(utiType: String, url: URL, customFileName: String?) -> (any DataSource)? {
        if utiType == (kUTTypeURL as String) {
            // Share URLs as text messages whose text content is the URL
            return DataSourceValue(text: url.absoluteString)
        }
        else if UTTypeConformsTo(utiType as CFString, kUTTypeText) {
            // Share text as oversize text messages.
            //
            // NOTE: SharingThreadPickerViewController will try to unpack them
            //       and send them as normal text messages if possible.
            return DataSourcePath(fileUrl: url, shouldDeleteOnDeinit: false)
        }
        
        guard let dataSource: DataSourcePath = DataSourcePath(fileUrl: url, shouldDeleteOnDeinit: false) else {
            return nil
        }

        // Fallback to the last part of the URL
        dataSource.sourceFilename = (customFileName ?? url.lastPathComponent)
        
        return dataSource
    }

    private class func preferredItemProviders(inputItem: NSExtensionItem) -> [NSItemProvider]? {
        guard let attachments = inputItem.attachments else { return nil }

        var visualMediaItemProviders = [NSItemProvider]()
        var hasNonVisualMedia = false
        
        for attachment in attachments {
            if isVisualMediaItem(itemProvider: attachment) {
                visualMediaItemProviders.append(attachment)
            }
            else {
                hasNonVisualMedia = true
            }
        }
        
        // Only allow multiple-attachment sends if all attachments
        // are visual media.
        if visualMediaItemProviders.count > 0 && !hasNonVisualMedia {
            return visualMediaItemProviders
        }

        // A single inputItem can have multiple attachments, e.g. sharing from Firefox gives
        // one url attachment and another text attachment, where the the url would be https://some-news.com/articles/123-cat-stuck-in-tree
        // and the text attachment would be something like "Breaking news - cat stuck in tree"
        //
        // FIXME: For now, we prefer the URL provider and discard the text provider, since it's more useful to share the URL than the caption
        // but we *should* include both. This will be a bigger change though since our share extension is currently heavily predicated
        // on one itemProvider per share.

        // Prefer a URL provider if available
        if let preferredAttachment = attachments.first(where: { (attachment: Any) -> Bool in
            guard let itemProvider = attachment as? NSItemProvider else {
                return false
            }
            
            return isUrlItem(itemProvider: itemProvider)
        }) {
            return [preferredAttachment]
        }

        // else return whatever is available
        if let itemProvider = inputItem.attachments?.first {
            return [itemProvider]
        }
        else {
            owsFailDebug("Missing attachment.")
        }
        
        return []
    }

    private func selectItemProviders() -> AnyPublisher<[NSItemProvider], Error> {
        guard let inputItems = self.extensionContext?.inputItems else {
            let error = ShareViewControllerError.assertionError(description: "no input item")
            return Fail(error: error)
                .eraseToAnyPublisher()
        }

        for inputItemRaw in inputItems {
            guard let inputItem = inputItemRaw as? NSExtensionItem else {
                Logger.error("invalid inputItem \(inputItemRaw)")
                continue
            }
            
            if let itemProviders = ShareNavController.preferredItemProviders(inputItem: inputItem) {
                return Just(itemProviders)
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            }
        }
        let error = ShareViewControllerError.assertionError(description: "no input item")
        return Fail(error: error)
            .eraseToAnyPublisher()
    }
    
    // MARK: - LoadedItem

    private
    struct LoadedItem {
        let itemProvider: NSItemProvider
        let itemUrl: URL
        let utiType: String

        var customFileName: String?
        var isConvertibleToTextMessage = false
        var isConvertibleToContactShare = false

        init(itemProvider: NSItemProvider,
             itemUrl: URL,
             utiType: String,
             customFileName: String? = nil,
             isConvertibleToTextMessage: Bool = false,
             isConvertibleToContactShare: Bool = false) {
            self.itemProvider = itemProvider
            self.itemUrl = itemUrl
            self.utiType = utiType
            self.customFileName = customFileName
            self.isConvertibleToTextMessage = isConvertibleToTextMessage
            self.isConvertibleToContactShare = isConvertibleToContactShare
        }
    }
    
    private func loadItemProvider(itemProvider: NSItemProvider) -> AnyPublisher<LoadedItem, Error> {
        Logger.info("attachment: \(itemProvider)")

        // We need to be very careful about which UTI type we use.
        //
        // * In the case of "textual" shares (e.g. web URLs and text snippets), we want to
        //   coerce the UTI type to kUTTypeURL or kUTTypeText.
        // * We want to treat shared files as file attachments.  Therefore we do not
        //   want to treat file URLs like web URLs.
        // * UTIs aren't very descriptive (there are far more MIME types than UTI types)
        //   so in the case of file attachments we try to refine the attachment type
        //   using the file extension.
        guard let srcUtiType = ShareNavController.utiType(itemProvider: itemProvider) else {
            let error = ShareViewControllerError.unsupportedMedia
            return Fail(error: error)
                .eraseToAnyPublisher()
        }
        Logger.debug("matched utiType: \(srcUtiType)")

        return Deferred {
            Future<LoadedItem, Error> { resolver in
                let loadCompletion: NSItemProvider.CompletionHandler = { [weak self] value, error in
                    guard self != nil else { return }
                    if let error: Error = error {
                        resolver(Result.failure(error))
                        return
                    }
                    
                    guard let value = value else {
                        resolver(
                            Result.failure(ShareViewControllerError.assertionError(description: "missing item provider"))
                        )
                        return
                    }
                    
                    Logger.info("value type: \(type(of: value))")
                    
                    switch value {
                        case let data as Data:
                            let customFileName = "Contact.vcf"
                            let customFileExtension = MimeTypeUtil.fileExtension(forUtiType: srcUtiType)
                            
                            guard let tempFilePath = try? FileSystem.write(data: data, toTemporaryFileWithExtension: customFileExtension) else {
                                resolver(
                                    Result.failure(ShareViewControllerError.assertionError(description: "Error writing item data: \(String(describing: error))"))
                                )
                                return
                            }
                            let fileUrl = URL(fileURLWithPath: tempFilePath)
                            
                            resolver(
                                Result.success(
                                    LoadedItem(
                                        itemProvider: itemProvider,
                                        itemUrl: fileUrl,
                                        utiType: srcUtiType,
                                        customFileName: customFileName,
                                        isConvertibleToContactShare: false
                                    )
                                )
                            )
                            
                        case let string as String:
                            Logger.debug("string provider: \(string)")
                            guard let data = string.filterStringForDisplay().data(using: String.Encoding.utf8) else {
                                resolver(
                                    Result.failure(ShareViewControllerError.assertionError(description: "Error writing item data: \(String(describing: error))"))
                                )
                                return
                            }
                            guard let tempFilePath: String = try? FileSystem.write(data: data, toTemporaryFileWithExtension: "txt") else {
                                resolver(
                                    Result.failure(ShareViewControllerError.assertionError(description: "Error writing item data: \(String(describing: error))"))
                                )
                                return
                            }
                            
                            let fileUrl = URL(fileURLWithPath: tempFilePath)
                            
                            let isConvertibleToTextMessage = !itemProvider.registeredTypeIdentifiers.contains(kUTTypeFileURL as String)
                            
                            if UTTypeConformsTo(srcUtiType as CFString, kUTTypeText) {
                                resolver(
                                    Result.success(
                                        LoadedItem(
                                            itemProvider: itemProvider,
                                            itemUrl: fileUrl,
                                            utiType: srcUtiType,
                                            isConvertibleToTextMessage: isConvertibleToTextMessage
                                        )
                                    )
                                )
                            }
                            else {
                                resolver(
                                    Result.success(
                                        LoadedItem(
                                            itemProvider: itemProvider,
                                            itemUrl: fileUrl,
                                            utiType: kUTTypeText as String,
                                            isConvertibleToTextMessage: isConvertibleToTextMessage
                                        )
                                    )
                                )
                            }
                            
                        case let url as URL:
                            // If the share itself is a URL (e.g. a link from Safari), try to send this as a text message.
                            let isConvertibleToTextMessage = (
                                itemProvider.registeredTypeIdentifiers.contains(kUTTypeURL as String) &&
                                !itemProvider.registeredTypeIdentifiers.contains(kUTTypeFileURL as String)
                            )
                            
                            if isConvertibleToTextMessage {
                                resolver(
                                    Result.success(
                                        LoadedItem(
                                            itemProvider: itemProvider,
                                            itemUrl: url,
                                            utiType: kUTTypeURL as String,
                                            isConvertibleToTextMessage: isConvertibleToTextMessage
                                        )
                                    )
                                )
                            }
                            else {
                                resolver(
                                    Result.success(
                                        LoadedItem(
                                            itemProvider: itemProvider,
                                            itemUrl: url,
                                            utiType: srcUtiType,
                                            isConvertibleToTextMessage: isConvertibleToTextMessage
                                        )
                                    )
                                )
                            }
                            
                        case let image as UIImage:
                            if let data = image.pngData() {
                                let tempFilePath: String = FileSystem.temporaryFilePath(fileExtension: "png")
                                do {
                                    let url = NSURL.fileURL(withPath: tempFilePath)
                                    try data.write(to: url)
                                    
                                    resolver(
                                        Result.success(
                                            LoadedItem(
                                                itemProvider: itemProvider,
                                                itemUrl: url,
                                                utiType: srcUtiType
                                            )
                                        )
                                    )
                                }
                                catch {
                                    resolver(
                                        Result.failure(ShareViewControllerError.assertionError(description: "couldn't write UIImage: \(String(describing: error))"))
                                    )
                                }
                            }
                            else {
                                resolver(
                                    Result.failure(ShareViewControllerError.assertionError(description: "couldn't convert UIImage to PNG: \(String(describing: error))"))
                                )
                            }
                            
                        default:
                            // It's unavoidable that we may sometimes receives data types that we
                            // don't know how to handle.
                            resolver(
                                Result.failure(ShareViewControllerError.assertionError(description: "unexpected value: \(String(describing: value))"))
                            )
                    }
                }
                
                itemProvider.loadItem(forTypeIdentifier: srcUtiType, options: nil, completionHandler: loadCompletion)
            }
        }
        .eraseToAnyPublisher()
    }
    
    private func buildAttachment(forLoadedItem loadedItem: LoadedItem) -> AnyPublisher<SignalAttachment, Error> {
        let itemProvider = loadedItem.itemProvider
        let itemUrl = loadedItem.itemUrl
        let utiType = loadedItem.utiType

        var url = itemUrl
        do {
            if isVideoNeedingRelocation(itemProvider: itemProvider, itemUrl: itemUrl) {
                url = try SignalAttachment.copyToVideoTempDir(url: itemUrl, using: dependencies)
            }
        } catch {
            let error = ShareViewControllerError.assertionError(description: "Could not copy video")
            return Fail(error: error)
                .eraseToAnyPublisher()
        }

        Logger.debug("building DataSource with url: \(url), utiType: \(utiType)")

        guard let dataSource = ShareNavController.createDataSource(utiType: utiType, url: url, customFileName: loadedItem.customFileName) else {
            let error = ShareViewControllerError.assertionError(description: "Unable to read attachment data")
            return Fail(error: error)
                .eraseToAnyPublisher()
        }

        // start with base utiType, but it might be something generic like "image"
        var specificUTIType = utiType
        if utiType == (kUTTypeURL as String) {
            // Use kUTTypeURL for URLs.
        } else if UTTypeConformsTo(utiType as CFString, kUTTypeText) {
            // Use kUTTypeText for text.
        } else if url.pathExtension.count > 0 {
            // Determine a more specific utiType based on file extension
            if let typeExtension = MimeTypeUtil.utiType(forFileExtension: url.pathExtension) {
                Logger.debug("utiType based on extension: \(typeExtension)")
                specificUTIType = typeExtension
            }
        }

        guard !SignalAttachment.isInvalidVideo(dataSource: dataSource, dataUTI: specificUTIType) else {
            // This can happen, e.g. when sharing a quicktime-video from iCloud drive.
            let (publisher, _) = SignalAttachment.compressVideoAsMp4(dataSource: dataSource, dataUTI: specificUTIType, using: dependencies)
            return publisher
        }

        let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: specificUTIType, imageQuality: .medium)
        if loadedItem.isConvertibleToContactShare {
            Logger.info("isConvertibleToContactShare")
            attachment.isConvertibleToContactShare = true
        } else if loadedItem.isConvertibleToTextMessage {
            Logger.info("isConvertibleToTextMessage")
            attachment.isConvertibleToTextMessage = true
        }
        return Just(attachment)
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }

    private func buildAttachments() -> AnyPublisher<[SignalAttachment], Error> {
        return selectItemProviders()
            .tryFlatMap { [weak self] itemProviders -> AnyPublisher<[SignalAttachment], Error> in
                guard let strongSelf = self else {
                    throw ShareViewControllerError.assertionError(description: "expired")
                }

                var loadPublishers = [AnyPublisher<SignalAttachment, Error>]()

                for itemProvider in itemProviders.prefix(SignalAttachment.maxAttachmentsAllowed) {
                    let loadPublisher = strongSelf.loadItemProvider(itemProvider: itemProvider)
                        .flatMap { loadedItem -> AnyPublisher<SignalAttachment, Error> in
                            return strongSelf.buildAttachment(forLoadedItem: loadedItem)
                        }
                        .eraseToAnyPublisher()

                    loadPublishers.append(loadPublisher)
                }
                
                return Publishers
                    .MergeMany(loadPublishers)
                    .collect()
                    .eraseToAnyPublisher()
            }
            .tryMap { signalAttachments -> [SignalAttachment] in
                guard signalAttachments.count > 0 else {
                    throw ShareViewControllerError.assertionError(description: "no valid attachments")
                }
                
                return signalAttachments
            }
            .shareReplay(1)
            .eraseToAnyPublisher()
    }

    // Some host apps (e.g. iOS Photos.app) sometimes auto-converts some video formats (e.g. com.apple.quicktime-movie)
    // into mp4s as part of the NSItemProvider `loadItem` API. (Some files the Photo's app doesn't auto-convert)
    //
    // However, when using this url to the converted item, AVFoundation operations such as generating a
    // preview image and playing the url in the AVMoviePlayer fails with an unhelpful error: "The operation could not be completed"
    //
    // We can work around this by first copying the media into our container.
    //
    // I don't understand why this is, and I haven't found any relevant documentation in the NSItemProvider
    // or AVFoundation docs.
    //
    // Notes:
    //
    // These operations succeed when sending a video which initially existed on disk as an mp4.
    // (e.g. Alice sends a video to Bob through the main app, which ensures it's an mp4. Bob saves it, then re-shares it)
    //
    // I *did* verify that the size and SHA256 sum of the original url matches that of the copied url. So there
    // is no difference between the contents of the file, yet one works one doesn't.
    // Perhaps the AVFoundation APIs require some extra file system permssion we don't have in the
    // passed through URL.
    private func isVideoNeedingRelocation(itemProvider: NSItemProvider, itemUrl: URL) -> Bool {
        let pathExtension = itemUrl.pathExtension
        guard pathExtension.count > 0 else {
            Logger.verbose("item URL has no file extension: \(itemUrl).")
            return false
        }
        guard let utiTypeForURL = MimeTypeUtil.utiType(forFileExtension: pathExtension) else {
            Logger.verbose("item has unknown UTI type: \(itemUrl).")
            return false
        }
        Logger.verbose("utiTypeForURL: \(utiTypeForURL)")
        guard utiTypeForURL == kUTTypeMPEG4 as String else {
            // Either it's not a video or it was a video which was not auto-converted to mp4.
            // Not affected by the issue.
            return false
        }

        // If video file already existed on disk as an mp4, then the host app didn't need to
        // apply any conversion, so no need to relocate the app.
        return !itemProvider.registeredTypeIdentifiers.contains(kUTTypeMPEG4 as String)
    }
}
