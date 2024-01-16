// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil

// MARK: - String

public extension String {
    var cArray: [CChar] { [UInt8](self.utf8).map { CChar(bitPattern: $0) } }
    
    /// Initialize with an optional pointer and a specific length
    init?(pointer: UnsafeRawPointer?, length: Int, encoding: String.Encoding = .utf8) {
        guard
            let pointer: UnsafeRawPointer = pointer,
            let result: String = String(data: Data(bytes: pointer, count: length), encoding: encoding)
        else { return nil }
        
        self = result
    }
    
    init<T>(
        libSessionVal: T,
        fixedLength: Int? = .none
    ) {
        guard let fixedLength: Int = fixedLength else {
            // Note: The `String(cString:)` function requires that the value is null-terminated
            // so add a null-termination character if needed
            self = String(
                cString: withUnsafeBytes(of: libSessionVal) { [UInt8]($0) }
                    .nullTerminated()
            )
            return
        }
        
        guard
            let fixedLengthData: Data = Data(
                libSessionVal: libSessionVal,
                count: fixedLength,
                nullIfEmpty: true
            ),
            let result: String = String(data: fixedLengthData, encoding: .utf8)
        else {
            self = ""
            return
        }
        
        self = result
    }
    
    init?<T>(
        libSessionVal: T,
        fixedLength: Int? = .none,
        nullIfEmpty: Bool
    ) {
        let result = String(libSessionVal: libSessionVal, fixedLength: fixedLength)
        
        guard !nullIfEmpty || !result.isEmpty else { return nil }
        
        self = result
    }
    
    func toLibSession<T>() -> T {
        let targetSize: Int = MemoryLayout<T>.stride
        var dataMatchingDestinationSize: [CChar] = [CChar](repeating: 0, count: targetSize)
        dataMatchingDestinationSize.replaceSubrange(
            0..<Swift.min(targetSize, self.utf8CString.count),
            with: self.utf8CString
        )
        
        return dataMatchingDestinationSize.withUnsafeBytes { ptr in
            ptr.baseAddress!.assumingMemoryBound(to: T.self).pointee
        }
    }
}

public extension Optional<String> {
    func toLibSession<T>() -> T {
        switch self {
            case .some(let value): return value.toLibSession()
            case .none: return "".toLibSession()
        }
    }
}

// MARK: - Data

public extension Data {
    var cArray: [UInt8] { [UInt8](self) }
    
    init<T>(libSessionVal: T, count: Int) {
        let result: Data = Swift.withUnsafePointer(to: libSessionVal) {
            Data(bytes: $0, count: count)
        }
        
        self = result
    }
    
    init?<T>(libSessionVal: T, count: Int, nullIfEmpty: Bool) {
        let result: Data = Data(libSessionVal: libSessionVal, count: count)
        
        // If all of the values are 0 then return the data as null
        guard !nullIfEmpty || result.contains(where: { $0 != 0 }) else { return nil }
        
        self = result
    }
    
    func toLibSession<T>() -> T {
        let targetSize: Int = MemoryLayout<T>.stride
        var dataMatchingDestinationSize: Data = Data(count: targetSize)
        dataMatchingDestinationSize.replaceSubrange(
            0..<Swift.min(targetSize, self.count),
            with: self
        )
        
        return dataMatchingDestinationSize.withUnsafeBytes { ptr in
            ptr.baseAddress!.assumingMemoryBound(to: T.self).pointee
        }
    }
}

public extension Optional<Data> {
    func toLibSession<T>() -> T {
        switch self {
            case .some(let value): return value.toLibSession()
            case .none: return Data().toLibSession()
        }
    }
}

// MARK: - Array

public extension Array where Element == String {
    init?(
        pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
        count: Int?
    ) {
        guard
            let pointee: UnsafeMutablePointer<CChar> = pointer?.pointee,
            let count: Int = count
        else { return nil }
        
        self = (0..<count)
            .reduce(into: []) { result, index in
                /// We need to calculate the start position of each of the hashes in memory which will
                /// be at the end of the previous hash plus one (due to the null termination character
                /// which isn't included in Swift strings so isn't included in `count`)
                let prevLength: Int = (result.isEmpty ? 0 :
                    result.map { ($0.count + 1) }.reduce(0, +)
                )
                
                result.append(String(cString: pointee.advanced(by: prevLength)))
            }
    }
    
    init(
        pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
        count: Int?,
        defaultValue: [String]
    ) {
        self = ([String](pointer: pointer, count: count) ?? defaultValue)
    }
}

public extension Array where Element == CChar {
    func nullTerminated() -> [Element] {
        guard self.last != CChar(0) else { return self }
        
        return self.appending(CChar(0))
    }
}

public extension Array where Element == UInt8 {
    func nullTerminated() -> [Element] {
        guard self.last != UInt8(0) else { return self }
        
        return self.appending(UInt8(0))
    }
}
