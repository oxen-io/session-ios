// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension Collection {
    public subscript(ifValid index: Index) -> Iterator.Element? {
        return self.indices.contains(index) ? self[index] : nil
    }
}

public extension Collection {
    /// This creates an UnsafeMutableBufferPointer to access data in memory directly. This result pointer provides no automated
    /// memory management so after use you are responsible for handling the life cycle and need to call `deallocate()`.
    func unsafeCopy() -> UnsafeMutableBufferPointer<Element> {
        let copy = UnsafeMutableBufferPointer<Element>.allocate(capacity: self.underestimatedCount)
        _ = copy.initialize(from: self)
        return copy
    }
    
    /// This creates an UnsafePointer to access data in memory directly. This result pointer provides no automated
    /// memory management so after use you are responsible for handling the life cycle and need to call `deallocate()`.
    func unsafeCopy() -> UnsafePointer<Element>? {
        let copy = UnsafeMutableBufferPointer<Element>.allocate(capacity: self.underestimatedCount)
        _ = copy.initialize(from: self)
        return UnsafePointer(copy.baseAddress)
    }
    
    /// This creates an UnsafePointer to access data in memory directly. This result pointer provides no automated
    /// memory management so after use you are responsible for handling the life cycle and need to call `deallocate()`.
    func unsafeCopy() -> UnsafeMutablePointer<Element>? {
        let copy = UnsafeMutableBufferPointer<Element>.allocate(capacity: self.underestimatedCount)
        _ = copy.initialize(from: self)
        return UnsafeMutablePointer(copy.baseAddress)
    }
}

public extension Collection where Element == [CChar]? {
    /// This creates an array of UnsafePointer types to access data of the C strings in memory. This array provides no automated
    /// memory management of it's children so after use you are responsible for handling the life cycle of the child elements and
    /// need to call `deallocate()` on each child.
    func unsafeCopyCStringArray() throws -> [UnsafePointer<CChar>?] {
        return try self.map { value in
            guard let value: [CChar] = value else { return nil }
            
            let copy = UnsafeMutableBufferPointer<CChar>.allocate(capacity: value.underestimatedCount)
            var remaining: (unwritten: Array<CChar>.Iterator, index: Int) = copy.initialize(from: value)
            guard remaining.unwritten.next() == nil else { throw LibSessionError.invalidCConversion }
            
            return UnsafePointer(copy.baseAddress)
        }
    }
}

public extension Collection where Element == [CChar] {
    /// This creates an array of UnsafePointer types to access data of the C strings in memory. This array provides no automated
    /// memory management of it's children so after use you are responsible for handling the life cycle of the child elements and
    /// need to call `deallocate()` on each child.
    func unsafeCopyCStringArray() throws -> [UnsafePointer<CChar>?] {
        return try self.map { value in
            let copy = UnsafeMutableBufferPointer<CChar>.allocate(capacity: value.underestimatedCount)
            var remaining: (unwritten: Array<CChar>.Iterator, index: Int) = copy.initialize(from: value)
            guard remaining.unwritten.next() == nil else { throw LibSessionError.invalidCConversion }
            
            return UnsafePointer(copy.baseAddress)
        }
    }
}

public extension Collection where Element == [UInt8] {
    /// This creates an array of UnsafePointer types to access data of the C strings in memory. This array provides no automated
    /// memory management of it's children so after use you are responsible for handling the life cycle of the child elements and
    /// need to call `deallocate()` on each child.
    func unsafeCopyUInt8Array() throws -> [UnsafePointer<UInt8>?] {
        return try self.map { value in
            let copy = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: value.underestimatedCount)
            var remaining: (unwritten: Array<UInt8>.Iterator, index: Int) = copy.initialize(from: value)
            guard remaining.unwritten.next() == nil else { throw LibSessionError.invalidCConversion }
            
            return UnsafePointer(copy.baseAddress)
        }
    }
}
