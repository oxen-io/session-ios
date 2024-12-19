// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import CryptoKit
import Compression

public enum ArchiveError: Error, CustomStringConvertible {
    case invalidSourcePath
    case archiveFailed
    case unarchiveFailed
    case decryptionFailed
    case incompatibleVersion
    case unableToFindDatabaseKey
    case importedFileCountMismatch
    case importedFileCountMetadataMismatch
    
    public var description: String {
        switch self {
            case .invalidSourcePath: "Invalid source path provided."
            case .archiveFailed: "Failed to archive."
            case .unarchiveFailed: "Failed to unarchive."
            case .decryptionFailed: "Decryption failed."
            case .incompatibleVersion: "This exported bundle is not compatible with this version of Session."
            case .unableToFindDatabaseKey: "Unable to find database key."
            case .importedFileCountMismatch: "The number of files imported doesn't match the number of files written to disk."
            case .importedFileCountMetadataMismatch: "The number of files imported doesn't match the number of files reported."
        }
    }
}

public class DirectoryArchiver {
    /// This value is here in case we need to change the structure of the exported data in the future, this would allow us to have
    /// some form of backwards compatibility if desired
    private static let version: UInt32 = 1
    
    /// Archive an entire directory
    /// - Parameters:
    ///   - sourcePath: Full path to the directory to compress
    ///   - destinationPath: Full path where the compressed file will be saved
    ///   - password: Optional password for encryption
    /// - Throws: ArchiveError if archiving fails
    public static func archiveDirectory(
        sourcePath: String,
        destinationPath: String,
        filenamesToExclude: [String] = [],
        additionalPaths: [String] = [],
        password: String?,
        progressChanged: ((Int, Int, UInt64, UInt64) -> Void)?
    ) throws {
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            throw ArchiveError.invalidSourcePath
        }
        
        let sourceUrl: URL = URL(fileURLWithPath: sourcePath)
        let destinationUrl: URL = URL(fileURLWithPath: destinationPath)
        
        // Create output stream for backup and compression
        guard let outputStream: OutputStream = OutputStream(url: destinationUrl, append: false) else {
            throw ArchiveError.archiveFailed
        }
        
        outputStream.open()
        defer { outputStream.close() }
        
        // Stream-based directory traversal and compression
        let enumerator: FileManager.DirectoryEnumerator? = FileManager.default.enumerator(
            at: sourceUrl,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]
        )
        let fileUrls: [URL] = (enumerator?.allObjects
            .compactMap { $0 as? URL }
            .filter { url -> Bool in
                guard !filenamesToExclude.contains(url.lastPathComponent) else { return false }
                guard
                    let resourceValues = try? url.resourceValues(
                        forKeys: [.isRegularFileKey, .isDirectoryKey]
                    )
                else { return true }
                
                return (resourceValues.isRegularFile == true)
            })
            .defaulting(to: [])
        var index: Int = 0
        progressChanged?(index, (fileUrls.count + additionalPaths.count), 0, 0)
        
        // Include the archiver version so we can validate compatibility when importing
        var version: UInt32 = DirectoryArchiver.version
        let versionData: [UInt8] = Array(Data(bytes: &version, count: MemoryLayout<UInt32>.size))
        try write(versionData, to: outputStream, blockSize: UInt8.self, password: password)
        
        // Store general metadata to help with validation and any other non-file related info
        var fileCount: UInt32 = UInt32(fileUrls.count)
        var additionalFileCount: UInt32 = UInt32(additionalPaths.count)
        
        let metadata: Data = (
            Data(bytes: &fileCount, count: MemoryLayout<UInt32>.size) +
            Data(bytes: &additionalFileCount, count: MemoryLayout<UInt32>.size)
        )
        try write(Array(metadata), to: outputStream, blockSize: UInt64.self, password: password)
        
        // Write the main file content
        try fileUrls.forEach { url in
            index += 1
            
            try exportFile(
                sourcePath: sourcePath,
                fileURL: url,
                customRelativePath: nil,
                outputStream: outputStream,
                password: password,
                index: index,
                totalFiles: (fileUrls.count + additionalPaths.count),
                isExtraFile: false,
                progressChanged: progressChanged
            )
        }
        
        // Add any extra files which we want to include
        try additionalPaths.forEach { path in
            index += 1
            
            let fileUrl: URL = URL(fileURLWithPath: path)
            try exportFile(
                sourcePath: sourcePath,
                fileURL: fileUrl,
                customRelativePath: "_extra/\(fileUrl.lastPathComponent)",
                outputStream: outputStream,
                password: password,
                index: index,
                totalFiles: (fileUrls.count + additionalPaths.count),
                isExtraFile: true,
                progressChanged: progressChanged
            )
        }
    }
    
    public static func unarchiveDirectory(
        archivePath: String,
        destinationPath: String,
        password: String?,
        progressChanged: ((Int, Int, UInt64, UInt64) -> Void)?
    ) throws -> (paths: [String], additional: [String]) {
        // Remove any old imported data as we don't want to muddy the new data
        if FileManager.default.fileExists(atPath: destinationPath) {
            try? FileManager.default.removeItem(atPath: destinationPath)
        }
        
        // Create the destination directory
        try FileManager.default.createDirectory(
            atPath: destinationPath,
            withIntermediateDirectories: true
        )
        
        guard
            let values: URLResourceValues = try? URL(fileURLWithPath: archivePath).resourceValues(
                forKeys: [.fileSizeKey]
            ),
            let encryptedFileSize: UInt64 = values.fileSize.map({ UInt64($0) }),
            let inputStream: InputStream = InputStream(fileAtPath: archivePath)
        else { throw ArchiveError.unarchiveFailed }
        
        inputStream.open()
        defer { inputStream.close() }
        
        // First we need to check the version included in the export is compatible with the current one
        let (versionData, _, _): ([UInt8], Int, UInt8) = try read(from: inputStream, password: password)
        
        guard !versionData.isEmpty else { throw ArchiveError.incompatibleVersion }
        
        var version: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &version) { versionBuffer in
            versionData.copyBytes(to: versionBuffer)
        }
        
        // Retrieve and process the general metadata
        var metadataOffset = 0
        let (metadataBytes, _, _): ([UInt8], Int, UInt64) = try read(from: inputStream, password: password)
        
        guard !metadataBytes.isEmpty else { throw ArchiveError.unarchiveFailed }
        
        // Extract path length and path
        let expectedFileCountRange: Range<Int> = metadataOffset..<(metadataOffset + MemoryLayout<UInt32>.size)
        var expectedFileCount: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &expectedFileCount) { expectedFileCountBuffer in
            metadataBytes.copyBytes(to: expectedFileCountBuffer, from: expectedFileCountRange)
        }
        metadataOffset += MemoryLayout<UInt32>.size
        
        let expectedAdditionalFileCountRange: Range<Int> = metadataOffset..<(metadataOffset + MemoryLayout<UInt32>.size)
        var expectedAdditionalFileCount: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &expectedAdditionalFileCount) { expectedAdditionalFileCountBuffer in
            metadataBytes.copyBytes(to: expectedAdditionalFileCountBuffer, from: expectedAdditionalFileCountRange)
        }
        
        var filePaths: [String] = []
        var additionalFilePaths: [String] = []
        var fileAmountProcessed: UInt64 = 0
        progressChanged?(0, Int(expectedFileCount + expectedAdditionalFileCount), 0, encryptedFileSize)
        while inputStream.hasBytesAvailable {
            let (metadata, blockSizeBytesRead, encryptedSize): ([UInt8], Int, UInt64) = try read(
                from: inputStream,
                password: password
            )
            fileAmountProcessed += UInt64(blockSizeBytesRead)
            progressChanged?(
                (filePaths.count + additionalFilePaths.count),
                Int(expectedFileCount + expectedAdditionalFileCount),
                fileAmountProcessed,
                encryptedFileSize
            )
            
            // Stop here if we have finished reading
            guard blockSizeBytesRead > 0 else { continue }
            
            // Process the metadata
            var offset = 0
            
            // Extract path length and path
            let pathLengthRange: Range<Int> = offset..<(offset + MemoryLayout<UInt32>.size)
            var pathLength: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &pathLength) { pathLengthBuffer in
                metadata.copyBytes(to: pathLengthBuffer, from: pathLengthRange)
            }
            offset += MemoryLayout<UInt32>.size
            
            let pathRange: Range<Int> = offset..<(offset + Int(pathLength))
            let relativePath: String = String(data: Data(metadata[pathRange]), encoding: .utf8)!
            offset += Int(pathLength)
            
            // Extract file size
            let fileSizeRange: Range<Int> = offset..<(offset + MemoryLayout<UInt64>.size)
            var fileSize: UInt64 = 0
            _ = withUnsafeMutableBytes(of: &fileSize) { fileSizeBuffer in
                metadata.copyBytes(to: fileSizeBuffer, from: fileSizeRange)
            }
            offset += Int(MemoryLayout<UInt64>.size)
            
            // Extract extra file flag
            let isExtraFileRange: Range<Int> = offset..<(offset + MemoryLayout<Bool>.size)
            var isExtraFile: Bool = false
            _ = withUnsafeMutableBytes(of: &isExtraFile) { isExtraFileBuffer in
                metadata.copyBytes(to: isExtraFileBuffer, from: isExtraFileRange)
            }
            
            // Construct full file path
            let fullPath: String = (destinationPath as NSString).appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                atPath: (fullPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            fileAmountProcessed += encryptedSize
            progressChanged?(
                (filePaths.count + additionalFilePaths.count),
                Int(expectedFileCount + expectedAdditionalFileCount),
                fileAmountProcessed,
                encryptedFileSize
            )
            
            // Read and decrypt file content
            guard let outputStream: OutputStream = OutputStream(toFileAtPath: fullPath, append: false) else {
                throw ArchiveError.unarchiveFailed
            }
            outputStream.open()
            defer { outputStream.close() }
            
            var remainingFileSize: Int = Int(fileSize)
            while remainingFileSize > 0 {
                let (chunk, chunkSizeBytesRead, encryptedSize): ([UInt8], Int, UInt32) = try read(
                    from: inputStream,
                    password: password
                )
                
                // Write to the output
                outputStream.write(chunk, maxLength: chunk.count)
                remainingFileSize -= chunk.count
                
                // Update the progress
                fileAmountProcessed += UInt64(chunkSizeBytesRead + chunk.count)
                progressChanged?(
                    (filePaths.count + additionalFilePaths.count),
                    Int(expectedFileCount + expectedAdditionalFileCount),
                    fileAmountProcessed,
                    encryptedFileSize
                )
            }
            
            // Store the file path info and update the progress
            switch isExtraFile {
                case false: filePaths.append(fullPath)
                case true: additionalFilePaths.append(fullPath)
            }
            progressChanged?(
                (filePaths.count + additionalFilePaths.count),
                Int(expectedFileCount + expectedAdditionalFileCount),
                fileAmountProcessed,
                encryptedFileSize
            )
        }
        
        // Validate that the number of files exported matches the number of paths we got back
        let testEnumerator: FileManager.DirectoryEnumerator? = FileManager.default.enumerator(
            at: URL(fileURLWithPath: destinationPath),
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]
        )
        let tempFileUrls: [URL] = (testEnumerator?.allObjects
            .compactMap { $0 as? URL }
            .filter { url -> Bool in
                guard
                    let resourceValues = try? url.resourceValues(
                        forKeys: [.isRegularFileKey, .isDirectoryKey]
                    )
                else { return true }
                
                return (resourceValues.isRegularFile == true)
            })
            .defaulting(to: [])
        
        guard tempFileUrls.count == (filePaths.count + additionalFilePaths.count) else {
            throw ArchiveError.importedFileCountMismatch
        }
        guard
            filePaths.count == expectedFileCount &&
            additionalFilePaths.count == expectedAdditionalFileCount
        else { throw ArchiveError.importedFileCountMetadataMismatch }
        
        return (filePaths, additionalFilePaths)
    }
    
    private static func encrypt(buffer: [UInt8], password: String) throws -> [UInt8] {
        guard let passwordData: Data = password.data(using: .utf8) else {
            return buffer
        }
        
        // Use HKDF for key derivation
        let salt: Data = Data(count: 16)
        let key: SymmetricKey = SymmetricKey(data: passwordData)
        let symmetricKey: SymmetricKey = SymmetricKey(
            data: HKDF<SHA256>.deriveKey(
                inputKeyMaterial: key,
                salt: salt,
                outputByteCount: 32
            )
        )
        let nonce: AES.GCM.Nonce = AES.GCM.Nonce()
        let sealedBox: AES.GCM.SealedBox = try AES.GCM.seal(
            Data(buffer),
            using: symmetricKey,
            nonce: nonce
        )
        
        // Combine nonce, ciphertext, and tag
        return [UInt8](nonce) + sealedBox.ciphertext + sealedBox.tag
    }
    
    private static func decrypt(buffer: [UInt8], password: String) throws -> [UInt8] {
        guard let passwordData: Data = password.data(using: .utf8) else {
            return buffer
        }
        
        let salt: Data = Data(count: 16)
        let key: SymmetricKey = SymmetricKey(data: passwordData)
        let symmetricKey: SymmetricKey = SymmetricKey(
            data: HKDF<SHA256>.deriveKey(
                inputKeyMaterial: key,
                salt: salt,
                outputByteCount: 32
            )
        )
        
        // Extract nonce, ciphertext, and tag
        let nonce: AES.GCM.Nonce = try AES.GCM.Nonce(data: Data(buffer.prefix(12)))
        let ciphertext: Data = Data(buffer[12..<(buffer.count-16)])
        let tag: Data = Data(buffer.suffix(16))
        
        // Decrypt with AES-GCM
        let sealedBox: AES.GCM.SealedBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag
        )
        
        let decryptedData: Data = try AES.GCM.open(sealedBox, using: symmetricKey)
        return [UInt8](decryptedData)
    }
    
    private static func write<T>(
        _ data: [UInt8],
        to outputStream: OutputStream,
        blockSize: T.Type,
        password: String?
    ) throws where T: FixedWidthInteger, T: UnsignedInteger {
        let processedBytes: [UInt8]
        
        switch password {
            case .none: processedBytes = data
            case .some(let password):
                processedBytes = try encrypt(
                    buffer: data,
                    password: password
                )
        }
        
        var blockSize: T = T(processedBytes.count)
        let blockSizeData: [UInt8] = Array(Data(bytes: &blockSize, count: MemoryLayout<T>.size))
        outputStream.write(blockSizeData, maxLength: blockSizeData.count)
        outputStream.write(processedBytes, maxLength: processedBytes.count)
    }
    
    private static func read<T>(
        from inputStream: InputStream,
        password: String?
    ) throws -> (value: [UInt8], blockSizeBytesRead: Int, encryptedSize: T) where T: FixedWidthInteger, T: UnsignedInteger {
        var blockSizeBytes: [UInt8] = [UInt8](repeating: 0, count: MemoryLayout<T>.size)
        let bytesRead: Int = inputStream.read(&blockSizeBytes, maxLength: blockSizeBytes.count)
        
        switch bytesRead {
            case 0: return ([], bytesRead, 0)           // We have finished reading
            case blockSizeBytes.count: break            // We have started the next block
            default: throw ArchiveError.unarchiveFailed // Invalid
        }
        
        var blockSize: T = 0
        _ = withUnsafeMutableBytes(of: &blockSize) { blockSizeBuffer in
            blockSizeBytes.copyBytes(to: blockSizeBuffer, from: ..<MemoryLayout<T>.size)
        }
        
        var encryptedResult: [UInt8] = [UInt8](repeating: 0, count: Int(blockSize))
        guard inputStream.read(&encryptedResult, maxLength: encryptedResult.count) == encryptedResult.count else {
            throw ArchiveError.unarchiveFailed
        }
        
        let result: [UInt8]
        switch password {
            case .none: result = encryptedResult
            case .some(let password): result = try decrypt(buffer: encryptedResult, password: password)
        }
        
        return (result, bytesRead, blockSize)
    }
    
    private static func exportFile(
        sourcePath: String,
        fileURL: URL,
        customRelativePath: String?,
        outputStream: OutputStream,
        password: String?,
        index: Int,
        totalFiles: Int,
        isExtraFile: Bool,
        progressChanged: ((Int, Int, UInt64, UInt64) -> Void)?
    ) throws {
        guard
            let values: URLResourceValues = try? fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            ),
            values.isRegularFile == true,
            var fileSize: UInt64 = values.fileSize.map({ UInt64($0) })
        else {
            progressChanged?(index, totalFiles, 1, 1)
            return
        }
        
        // Relative path preservation
        let relativePath: String = customRelativePath
            .defaulting(
                to: fileURL.path
                    .replacingOccurrences(of: sourcePath, with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            )
        
        // Write path length and path
        let pathData: Data = relativePath.data(using: .utf8)!
        var pathLength: UInt32 = UInt32(pathData.count)
        var isExtraFile: Bool = isExtraFile
        
        // Encrypt and write metadata (path length + path data)
        let metadata: Data = (
            Data(bytes: &pathLength, count: MemoryLayout<UInt32>.size) +
            pathData +
            Data(bytes: &fileSize, count: MemoryLayout<UInt64>.size) +
            Data(bytes: &isExtraFile, count: MemoryLayout<Bool>.size)
        )
        try write(Array(metadata), to: outputStream, blockSize: UInt64.self, password: password)
        
        // Stream file contents
        guard let inputStream: InputStream = InputStream(url: fileURL) else {
            progressChanged?(index, totalFiles, 1, 1)
            return
        }
        
        inputStream.open()
        defer { inputStream.close() }
        
        var buffer: [UInt8] = [UInt8](repeating: 0, count: 4096)
        var currentFileProcessAmount: UInt64 = 0
        while inputStream.hasBytesAvailable {
            let bytesRead: Int = inputStream.read(&buffer, maxLength: buffer.count)
            currentFileProcessAmount += UInt64(bytesRead)
            progressChanged?(index, totalFiles, currentFileProcessAmount, fileSize)
            
            if bytesRead > 0 {
                try write(
                    Array(buffer.prefix(bytesRead)),
                    to: outputStream,
                    blockSize: UInt32.self,
                    password: password
                )
            }
        }
    }
}

fileprivate extension InputStream {
    func readEncryptedChunk(password: String, maxLength: Int) -> Data? {
        var buffer: [UInt8] = [UInt8](repeating: 0, count: maxLength)
        let bytesRead: Int = self.read(&buffer, maxLength: maxLength)
        guard bytesRead > 0 else { return nil }
        
        return Data(buffer.prefix(bytesRead))
    }
}
