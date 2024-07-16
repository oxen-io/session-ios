// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

// MARK: - Singleton

public extension Singleton {
    static let fileManager: SingletonConfig<FileManagerType> = Dependencies.create(
        identifier: "fileManager",
        createInstance: { _ in FileManager.default }
    )
}

// MARK: - FileManagerType

public protocol FileManagerType: AnyObject {
    var currentDirectoryPath: String { get }
    
    func urls(for directory: FileManager.SearchPathDirectory, in domains: FileManager.SearchPathDomainMask) -> [URL]
    func containerURL(forSecurityApplicationGroupIdentifier: String) -> URL?
    func enumerator(
        at url: URL,
        includingPropertiesForKeys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions,
        errorHandler: ((URL, Error) -> Bool)?
    ) -> FileManager.DirectoryEnumerator?

    
    func fileExists(atPath: String) -> Bool
    func fileExists(atPath: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool
    func contents(atPath: String) -> Data?

    func createFile(atPath: String, contents: Data?, attributes: [FileAttributeKey: Any]?) -> Bool
    func createDirectory(atPath: String, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws
    func copyItem(at fromUrl: URL, to toUrl: URL) throws
    func removeItem(atPath: String) throws
    
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any]
    func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws
}

public extension FileManagerType {
    func createFile(atPath: String, contents: Data?) -> Bool {
        return createFile(atPath: atPath, contents: contents, attributes: nil)
    }
    
    func createDirectory(atPath: String, withIntermediateDirectories: Bool) throws {
        try createDirectory(atPath: atPath, withIntermediateDirectories: withIntermediateDirectories, attributes: nil)
    }
}

extension FileManager: FileManagerType {}

// MARK: - Convenience

public extension FileManagerType {
    var appSharedDataDirectoryPath: String {
        return (containerURL(forSecurityApplicationGroupIdentifier: UserDefaults.applicationGroup)?
            .path)
            .defaulting(to: "")
    }
}
