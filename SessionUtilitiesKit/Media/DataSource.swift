// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation

// MARK: - DataSource

public protocol DataSource: Equatable, Hashable {
    var data: Data { get }
    var dataUrl: URL? { get }

    /// The file path for the data, if it already exists on disk.
    ///
    /// This method is safe to call as it will not do any expensive reads or writes.
    ///
    /// May return nil if the data does not (yet) reside on disk.
    ///
    /// Use `dataUrl` instead if you need to access the data; it will ensure the data is on disk and return a URL, barring an error.
    var dataPathIfOnDisk: String? { get }
    
    var dataLength: Int { get }
    var sourceFilename: String? { get set }
    var mimeType: String? { get }
    var shouldDeleteOnDeinit: Bool { get }
    
    // MARK: - Functions
    
    func write(to path: String) throws
}

public extension DataSource {
    var isValidImage: Bool {
        guard let dataPath: String = self.dataPathIfOnDisk else {
            return self.data.isValidImage
        }
        
        // if ows_isValidImage is given a file path, it will
        // avoid loading most of the data into memory, which
        // is considerably more performant, so try to do that.
        return Data.isValidImage(at: dataPath, mimeType: mimeType)
    }
    
    var isValidVideo: Bool {
        guard let dataUrl: URL = self.dataUrl else { return false }
        
        return MediaUtils.isValidVideo(path: dataUrl.path)
    }
}

// MARK: - DataSourceValue

public class DataSourceValue: DataSource {
    public static let empty: DataSourceValue = DataSourceValue(
        data: Data(),
        fileExtension: MimeTypeUtil.FileExtension.syncMessage
    )
    
    public var data: Data
    public var sourceFilename: String?
    var fileExtension: String
    var cachedFilePath: String?
    public var shouldDeleteOnDeinit: Bool
    
    public var dataUrl: URL? { dataPath.map { URL(fileURLWithPath: $0) } }
    public var dataPathIfOnDisk: String? { cachedFilePath }
    public var dataLength: Int { data.count }
    public var mimeType: String? { MimeTypeUtil.mimeType(for: fileExtension) }
    
    var dataPath: String? {
        let fileExtension: String = self.fileExtension
        
        return DataSourceValue.synced(self) { [weak self] in
            guard let cachedFilePath: String = self?.cachedFilePath else {
                let filePath: String = FileSystem.temporaryFilePath(fileExtension: fileExtension)
                
                do { try self?.write(to: filePath) }
                catch { return nil }
                
                self?.cachedFilePath = filePath
                return filePath
            }
            
            return cachedFilePath
        }
    }
    
    // MARK: - Initialization
    
    public init(data: Data, fileExtension: String) {
        self.data = data
        self.fileExtension = fileExtension
        self.shouldDeleteOnDeinit = true
    }
    
    convenience init?(data: Data?, fileExtension: String) {
        guard let data: Data = data else { return nil }
        
        self.init(data: data, fileExtension: fileExtension)
    }
    
    public convenience init?(data: Data?, utiType: String) {
        guard let fileExtension: String = MimeTypeUtil.fileExtension(forUtiType: utiType) else { return nil }
        
        self.init(data: data, fileExtension: fileExtension)
    }
    
    public convenience init?(text: String?) {
        guard
            let text: String = text,
            let data: Data = text.filterForDisplay?.data(using: .utf8)
        else { return nil }
        
        self.init(data: data, fileExtension: MimeTypeUtil.FileExtension.text)
    }
    
    convenience init(syncMessageData: Data) {
        self.init(data: syncMessageData, fileExtension: MimeTypeUtil.FileExtension.syncMessage)
    }
    
    deinit {
        guard
            shouldDeleteOnDeinit,
            let filePath: String = cachedFilePath
        else { return }
        
        DispatchQueue.global(qos: .default).async {
            try? FileManager.default.removeItem(atPath: filePath)
        }
    }
    
    // MARK: - Functions
    
    @discardableResult private static func synced<T>(_ lock: Any, closure: () -> T) -> T {
        objc_sync_enter(lock)
        let result: T = closure()
        objc_sync_exit(lock)
        return result
    }
    
    public func write(to path: String) throws {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    
    public func hash(into hasher: inout Hasher) {
        data.hash(into: &hasher)
        sourceFilename.hash(into: &hasher)
        fileExtension.hash(into: &hasher)
        shouldDeleteOnDeinit.hash(into: &hasher)
    }
    
    public static func == (lhs: DataSourceValue, rhs: DataSourceValue) -> Bool {
        return (
            lhs.data == rhs.data &&
            lhs.sourceFilename == rhs.sourceFilename &&
            lhs.fileExtension == rhs.fileExtension &&
            lhs.shouldDeleteOnDeinit == rhs.shouldDeleteOnDeinit
        )
    }
}

// MARK: - DataSourcePath

public class DataSourcePath: DataSource {
    public var filePath: String
    public var sourceFilename: String?
    var cachedData: Data?
    var cachedDataLength: Int?
    public var shouldDeleteOnDeinit: Bool
    
    public var data: Data {
        let filePath: String = self.filePath
        
        return DataSourcePath.synced(self) { [weak self] in
            if let cachedData: Data = self?.cachedData {
                return cachedData
            }
            
            let data: Data = ((try? Data(contentsOf: URL(fileURLWithPath: filePath))) ?? Data())
            self?.cachedData = data
            return data
        }
    }
    
    public var dataUrl: URL? { URL(fileURLWithPath: filePath) }
    public var dataPathIfOnDisk: String? { filePath }

    public var dataLength: Int {
        let filePath: String = self.filePath
        
        return DataSourcePath.synced(self) { [weak self] in
            if let cachedDataLength: Int = self?.cachedDataLength {
                return cachedDataLength
            }
            
            let attrs: [FileAttributeKey: Any]? = try? FileManager.default.attributesOfItem(atPath: filePath)
            let length: Int = ((attrs?[FileAttributeKey.size] as? Int) ?? 0)
            self?.cachedDataLength = length
            return length
        }
    }
    
    public var mimeType: String? { MimeTypeUtil.mimeType(for: URL(fileURLWithPath: filePath).pathExtension) }

    // MARK: - Initialization
    
    public init(filePath: String, shouldDeleteOnDeinit: Bool) {
        self.filePath = filePath
        self.shouldDeleteOnDeinit = shouldDeleteOnDeinit
    }
    
    public convenience init?(fileUrl: URL?, shouldDeleteOnDeinit: Bool) {
        guard let fileUrl: URL = fileUrl, fileUrl.isFileURL else { return nil }
        
        self.init(filePath: fileUrl.path, shouldDeleteOnDeinit: shouldDeleteOnDeinit)
    }
    
    deinit {
        guard shouldDeleteOnDeinit else { return }
        
        DispatchQueue.global(qos: .default).async { [filePath] in
            try? FileManager.default.removeItem(atPath: filePath)
        }
    }
    
    // MARK: - Functions
    
    @discardableResult private static func synced<T>(_ lock: Any, closure: () -> T) -> T {
        objc_sync_enter(lock)
        let result: T = closure()
        objc_sync_exit(lock)
        return result
    }
    
    public func write(to path: String) throws {
        try FileManager.default.copyItem(atPath: filePath, toPath: path)
    }
    
    public func hash(into hasher: inout Hasher) {
        filePath.hash(into: &hasher)
        sourceFilename.hash(into: &hasher)
        shouldDeleteOnDeinit.hash(into: &hasher)
    }
    
    public static func == (lhs: DataSourcePath, rhs: DataSourcePath) -> Bool {
        return (
            lhs.filePath == rhs.filePath &&
            lhs.sourceFilename == rhs.sourceFilename &&
            lhs.shouldDeleteOnDeinit == rhs.shouldDeleteOnDeinit
        )
    }
}
