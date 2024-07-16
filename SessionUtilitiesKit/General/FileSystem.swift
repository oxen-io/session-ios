// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum FileSystem {
    /// The Objective-C `OWSFileSystem` needs to be able to generate a temporary directory but we don't want to spend the time
    /// to add Objective-C support to `Dependencies` since the goal is to refactor everything to Swift so this value should only be
    /// assigned by the `AppContext` class when it gets initialised
    internal static var temporaryDirectory: Atomic<String?> = Atomic(nil)
    
    public static var cachesDirectoryPath: String {
        return NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0]
    }
    
    public static func ensureDirectoryExists(
        at path: String,
        fileProtectionType: FileProtectionType = .completeUntilFirstUserAuthentication,
        using dependencies: Dependencies
    ) throws {
        var isDirectory: ObjCBool = false
        
        if !dependencies[singleton: .fileManager].fileExists(atPath: path, isDirectory: &isDirectory) {
            try dependencies[singleton: .fileManager].createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
        
        try protectFileOrFolder(at: path, fileProtectionType: fileProtectionType, using: dependencies)
    }
    
    public static func protectFileOrFolder(
        at path: String,
        fileProtectionType: FileProtectionType = .completeUntilFirstUserAuthentication,
        using dependencies: Dependencies
    ) throws {
        guard dependencies[singleton: .fileManager].fileExists(atPath: path) else { return }
        
        try dependencies[singleton: .fileManager].setAttributes(
            [.protectionKey: fileProtectionType],
            ofItemAtPath: path
        )
        
        var resourcesUrl: URL = URL(fileURLWithPath: path)
        var resourceAttrs: URLResourceValues = URLResourceValues()
        resourceAttrs.isExcludedFromBackup = true
        try resourcesUrl.setResourceValues(resourceAttrs)
    }
    
    public static func fileSize(of path: String, using dependencies: Dependencies) -> UInt64? {
        guard let attributes: [FileAttributeKey: Any] = try? dependencies[singleton: .fileManager].attributesOfItem(atPath: path) else {
            return nil
        }
        
        return (attributes[.size] as? UInt64)
    }
    
    public static func temporaryFilePath(fileExtension: String?, using dependencies: Dependencies) -> String {
        let temporaryDirectory: String = {
            if let temporaryDirectory: String = self.temporaryDirectory.wrappedValue {
                return temporaryDirectory
            }
            
            // Not ideal but fallback to creating a new temp directory
            let dirName: String = "ows_temp_\(UUID().uuidString)"   // stringlint:disable
            let tempDir: String = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(dirName)
                .path
            try? FileSystem.ensureDirectoryExists(at: tempDir, fileProtectionType: .complete, using: dependencies)
            
            return tempDir
        }()
        
        var tempFileName: String = UUID().uuidString
        
        if let fileExtension: String = fileExtension, !fileExtension.isEmpty {
            tempFileName = "\(tempFileName).\(fileExtension)"
        }
        
        return URL(fileURLWithPath: temporaryDirectory)
            .appendingPathComponent(tempFileName)
            .path
    }
    
    public static func write(
        data: Data,
        toTemporaryFileWithExtension fileExtension: String?,
        using dependencies: Dependencies
    ) throws -> String? {
        let tempFilePath: String = temporaryFilePath(fileExtension: fileExtension, using: dependencies)
        
        try data.write(to: URL(fileURLWithPath: tempFilePath), options: .atomic)
        try protectFileOrFolder(at: tempFilePath, using: dependencies)
        
        return tempFilePath
    }
    
    public static func deleteFile(at path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }
}
