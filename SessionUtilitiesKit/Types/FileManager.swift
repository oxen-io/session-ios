// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

// MARK: - Singleton

public extension Singleton {
    static let fileManager: SingletonConfig<FileManagerType> = Dependencies.create(
        identifier: "fileManager",
        createInstance: { dependencies in SessionFileManager(using: dependencies) }
    )
}

// MARK: - FileManagerType

public protocol FileManagerType {
    var temporaryDirectory: String { get }
    var appSharedDataDirectoryPath: String { get }
    var temporaryDirectoryAccessibleAfterFirstAuth: String { get }
    
    /// **Note:** We need to call this method on launch _and_ every time the app becomes active,
    /// since file protection may prevent it from succeeding in the background.
    func clearOldTemporaryDirectories()
    
    func ensureDirectoryExists(at path: String, fileProtectionType: FileProtectionType) throws
    func protectFileOrFolder(at path: String, fileProtectionType: FileProtectionType) throws
    func fileSize(of path: String) -> UInt64?
    func temporaryFilePath(fileExtension: String?) -> String
    func write(data: Data, toTemporaryFileWithExtension fileExtension: String?) throws -> String?
    
    // MARK: - Forwarded NSFileManager
    
    var currentDirectoryPath: String { get }
    
    func urls(for directory: FileManager.SearchPathDirectory, in domains: FileManager.SearchPathDomainMask) -> [URL]
    func enumerator(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions,
        errorHandler: ((URL, Error) -> Bool)?
    ) -> FileManager.DirectoryEnumerator?
    
    func fileExists(atPath: String) -> Bool
    func fileExists(atPath: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool
    func contents(atPath: String) -> Data?
    func contentsOfDirectory(atPath path: String) throws -> [String]
    
    func createFile(atPath: String, contents: Data?, attributes: [FileAttributeKey: Any]?) -> Bool
    func createDirectory(at url: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws
    func createDirectory(atPath: String, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws
    func copyItem(atPath: String, toPath: String) throws
    func copyItem(at fromUrl: URL, to toUrl: URL) throws
    func removeItem(atPath: String) throws
    
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any]
    func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws
}

public extension FileManagerType {
    func ensureDirectoryExists(at path: String) throws {
        try ensureDirectoryExists(at: path, fileProtectionType: .completeUntilFirstUserAuthentication)
    }
    
    func protectFileOrFolder(at path: String) throws {
        try protectFileOrFolder(at: path, fileProtectionType: .completeUntilFirstUserAuthentication)
    }
    
    func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?) -> FileManager.DirectoryEnumerator? {
        return enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: nil)
    }
    
    func enumerator(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions
    ) -> FileManager.DirectoryEnumerator? {
        return enumerator(at: url, includingPropertiesForKeys: keys, options: options, errorHandler: nil)
    }
    
    func enumerator(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        errorHandler: ((URL, Error) -> Bool)?
    ) -> FileManager.DirectoryEnumerator? {
        return enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: errorHandler)
    }
    
    func createFile(atPath: String, contents: Data?) -> Bool {
        return createFile(atPath: atPath, contents: contents, attributes: nil)
    }
    
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories, attributes: nil)
    }
    
    func createDirectory(atPath: String, withIntermediateDirectories: Bool) throws {
        try createDirectory(atPath: atPath, withIntermediateDirectories: withIntermediateDirectories, attributes: nil)
    }
}

// MARK: - Convenience

public extension SessionFileManager {
    static var cachesDirectoryPath: String {
        return NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0]
    }
    
    static var nonInjectedAppSharedDataDirectoryPath: String {
        return (FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: UserDefaults.applicationGroup)?
            .path)
            .defaulting(to: "")
    }
}

// MARK: - SessionFileManager

public class SessionFileManager: FileManagerType {
    private let dependencies: Dependencies
    private let fileManager: FileManager = .default
    public var temporaryDirectory: String
    
    public var appSharedDataDirectoryPath: String {
        return (fileManager.containerURL(forSecurityApplicationGroupIdentifier: UserDefaults.applicationGroup)?.path)
            .defaulting(to: "")
    }
    
    public var temporaryDirectoryAccessibleAfterFirstAuth: String {
        let dirPath: String = NSTemporaryDirectory()
        try? ensureDirectoryExists(at: dirPath, fileProtectionType: .completeUntilFirstUserAuthentication)
        
        return dirPath
    }
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        // Create a new temp directory for this instance
        let dirName: String = "ows_temp_\(UUID().uuidString)"
        self.temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(dirName)
            .path
        try? ensureDirectoryExists(at: self.temporaryDirectory, fileProtectionType: .complete)
    }
    
    // MARK: - Functions
    
    public func clearOldTemporaryDirectories() {
        // We use the lowest priority queue for this, and wait N seconds
        // to avoid interfering with app startup.
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + .seconds(3), using: dependencies) { [temporaryDirectory, fileManager, dependencies] in
            // Abort if app not active
            guard dependencies[singleton: .appContext].isAppForegroundAndActive else { return }
            
            // Ignore the "current" temp directory.
            let thresholdDate: Date = dependencies[singleton: .appContext].appLaunchTime
            let currentTempDirName: String = URL(fileURLWithPath: temporaryDirectory).lastPathComponent
            let dirPath: String = NSTemporaryDirectory()
            
            guard let fileNames: [String] = try? fileManager.contentsOfDirectory(atPath: dirPath) else { return }
            
            fileNames.forEach { fileName in
                guard fileName != currentTempDirName else { return }
                
                // Delete files with either:
                //
                // a) "ows_temp" name prefix.
                // b) modified time before app launch time.
                let filePath: String = URL(fileURLWithPath: dirPath).appendingPathComponent(fileName).path
                
                if !fileName.hasPrefix("ows_temp") {
                    // It's fine if we can't get the attributes (the file may have been deleted since we found it),
                    // also don't delete files which were created in the last N minutes
                    guard
                        let attributes: [FileAttributeKey: Any] = try? fileManager.attributesOfItem(atPath: filePath),
                        let modificationDate: Date = attributes[.modificationDate] as? Date,
                        modificationDate.timeIntervalSince1970 <= thresholdDate.timeIntervalSince1970
                    else { return }
                }
                
                // This can happen if the app launches before the phone is unlocked.
                // Clean up will occur when app becomes active.
                try? fileManager.removeItem(atPath: filePath)
            }
        }
    }
    
    public func ensureDirectoryExists(at path: String, fileProtectionType: FileProtectionType) throws {
        var isDirectory: ObjCBool = false
        
        if !fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
            try fileManager.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
        
        try protectFileOrFolder(at: path, fileProtectionType: fileProtectionType)
    }
    
    public func protectFileOrFolder(at path: String, fileProtectionType: FileProtectionType) throws {
        guard fileManager.fileExists(atPath: path) else { return }
        
        try fileManager.setAttributes(
            [.protectionKey: fileProtectionType],
            ofItemAtPath: path
        )
        
        var resourcesUrl: URL = URL(fileURLWithPath: path)
        var resourceAttrs: URLResourceValues = URLResourceValues()
        resourceAttrs.isExcludedFromBackup = true
        try resourcesUrl.setResourceValues(resourceAttrs)
    }
    
    public func fileSize(of path: String) -> UInt64? {
        guard let attributes: [FileAttributeKey: Any] = try? fileManager.attributesOfItem(atPath: path) else {
            return nil
        }
        
        return (attributes[.size] as? UInt64)
    }
    
    public func temporaryFilePath(fileExtension: String?) -> String {
        var tempFileName: String = UUID().uuidString
        
        if let fileExtension: String = fileExtension, !fileExtension.isEmpty {
            tempFileName = "\(tempFileName).\(fileExtension)"
        }
        
        return URL(fileURLWithPath: temporaryDirectory)
            .appendingPathComponent(tempFileName)
            .path
    }
    
    public func write(data: Data, toTemporaryFileWithExtension fileExtension: String?) throws -> String? {
        let tempFilePath: String = temporaryFilePath(fileExtension: fileExtension)
        
        try data.write(to: URL(fileURLWithPath: tempFilePath), options: .atomic)
        try protectFileOrFolder(at: tempFilePath)
        
        return tempFilePath
    }
    
    // MARK: - Forwarded NSFileManager
    
    public var currentDirectoryPath: String { fileManager.currentDirectoryPath }
    
    public func urls(for directory: FileManager.SearchPathDirectory, in domains: FileManager.SearchPathDomainMask) -> [URL] {
        
        return fileManager.urls(for: directory, in: domains)
    }
    
    public func enumerator(
        at url: URL,
        includingPropertiesForKeys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions,
        errorHandler: ((URL, Error) -> Bool)?
    ) -> FileManager.DirectoryEnumerator? {
        return fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: includingPropertiesForKeys,
            options: options,
            errorHandler: errorHandler
        )
    }
    
    public func fileExists(atPath: String) -> Bool {
        return fileManager.fileExists(atPath: atPath)
    }
    
    public func fileExists(atPath: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        return fileManager.fileExists(atPath: atPath, isDirectory: isDirectory)
    }
    
    public func contents(atPath: String) -> Data? {
        return fileManager.contents(atPath: atPath)
    }
    
    public func contentsOfDirectory(atPath path: String) throws -> [String] {
        return try fileManager.contentsOfDirectory(atPath: path)
    }

    public func createFile(atPath: String, contents: Data?, attributes: [FileAttributeKey: Any]?) -> Bool {
        return fileManager.createFile(atPath: atPath, contents: contents, attributes: attributes)
    }
    
    public func createDirectory(at url: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws {
        return try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: withIntermediateDirectories,
            attributes: attributes
        )
    }
    
    public func createDirectory(atPath: String, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws {
        return try fileManager.createDirectory(
            atPath: atPath,
            withIntermediateDirectories: withIntermediateDirectories,
            attributes: attributes
        )
    }
    
    public func copyItem(atPath: String, toPath: String) throws {
        return try fileManager.copyItem(atPath: atPath, toPath: toPath)
    }
    
    public func copyItem(at fromUrl: URL, to toUrl: URL) throws {
        return try fileManager.copyItem(at: fromUrl, to: toUrl)
    }
    
    public func removeItem(atPath: String) throws {
        return try fileManager.removeItem(atPath: atPath)
    }
    
    public func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        return try fileManager.attributesOfItem(atPath: path)
    }
    
    public func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        return try fileManager.setAttributes(attributes, ofItemAtPath: path)
    }
}
