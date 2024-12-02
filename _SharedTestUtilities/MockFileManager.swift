// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

class MockFileManager: Mock<FileManagerType>, FileManagerType {
    var temporaryDirectory: String { mock() }
    var appSharedDataDirectoryPath: String { mock() }
    var temporaryDirectoryAccessibleAfterFirstAuth: String { mock() }
    
    func clearOldTemporaryDirectories() { mockNoReturn() }
    
    func ensureDirectoryExists(at path: String, fileProtectionType: FileProtectionType) throws {
        try mockThrowingNoReturn(args: [path, fileProtectionType])
    }
    
    
    func protectFileOrFolder(at path: String, fileProtectionType: FileProtectionType) throws {
        try mockThrowingNoReturn(args: [path, fileProtectionType])
    }
    
    func fileSize(of path: String) -> UInt64? {
        return mock(args: [path])
    }
    
    func temporaryFilePath(fileExtension: String?) -> String {
        return mock(args: [fileExtension])
    }
    
    func write(data: Data, toTemporaryFileWithExtension fileExtension: String?) throws -> String? {
        return try mockThrowing(args: [data, fileExtension])
    }
    
    // MARK: - Forwarded NSFileManager
    
    var currentDirectoryPath: String { mock() }
    
    func urls(for directory: FileManager.SearchPathDirectory, in domains: FileManager.SearchPathDomainMask) -> [URL] {
        return mock(args: [directory, domains])
    }
    
    func enumerator(
        at url: URL,
        includingPropertiesForKeys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions,
        errorHandler: ((URL, Error) -> Bool)?
    ) -> FileManager.DirectoryEnumerator? {
        return mock(args: [url, includingPropertiesForKeys, options, errorHandler])
    }
    
    func fileExists(atPath: String) -> Bool { return mock(args: [atPath]) }
    func fileExists(atPath: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        return mock(args: [atPath, isDirectory])
    }
    
    func contents(atPath: String) -> Data? { return mock(args: [atPath]) }
    func contentsOfDirectory(atPath path: String) throws -> [String] { return mock(args: [path]) }
    
    func createFile(atPath: String, contents: Data?, attributes: [FileAttributeKey : Any]?) -> Bool {
        return mock(args: [atPath, contents, attributes])
    }
    
    func createDirectory(atPath: String, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws {
        try mockThrowingNoReturn(args: [atPath, withIntermediateDirectories, attributes])
    }
    
    func createDirectory(at url: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws {
        try mockThrowingNoReturn(args: [url, withIntermediateDirectories, attributes])
    }
    
    func copyItem(atPath: String, toPath: String) throws { return try mockThrowing(args: [atPath, toPath]) }
    func copyItem(at fromUrl: URL, to toUrl: URL) throws { return try mockThrowing(args: [fromUrl, toUrl]) }
    func removeItem(atPath: String) throws { return try mockThrowing(args: [atPath]) }
    
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        return try mockThrowing(args: [path])
    }
    
    func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        try mockThrowingNoReturn(args: [attributes, path])
    }
}
