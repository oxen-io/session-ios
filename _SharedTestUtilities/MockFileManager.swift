// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

class MockFileManager: Mock<FileManagerType>, FileManagerType {
    var currentDirectoryPath: String { mock() }
    
    func urls(for directory: FileManager.SearchPathDirectory, in domains: FileManager.SearchPathDomainMask) -> [URL] {
        return mock(args: [directory, domains])
    }
    
    func containerURL(forSecurityApplicationGroupIdentifier: String) -> URL? {
        return mock(args: [forSecurityApplicationGroupIdentifier])
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
    
    func createFile(atPath: String, contents: Data?, attributes: [FileAttributeKey : Any]?) -> Bool {
        return mock(args: [atPath, contents, attributes])
    }
    
    func createDirectory(atPath: String, withIntermediateDirectories: Bool, attributes: [FileAttributeKey : Any]?) throws {
        return try mockThrowing(args: [atPath, withIntermediateDirectories, attributes])
    }
    
    func copyItem(at fromUrl: URL, to toUrl: URL) throws { return try mockThrowing(args: [fromUrl, toUrl]) }
    func removeItem(atPath: String) throws { return try mockThrowing(args: [atPath]) }
    
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        return try mockThrowing(args: [path])
    }
    
    func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        try mockThrowingNoReturn(args: [attributes, path])
    }
}
