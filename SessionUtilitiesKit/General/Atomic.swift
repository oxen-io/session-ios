// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

// MARK: - Atomic<Value>

/// The `Atomic<Value>` wrapper is a generic wrapper providing a thread-safe way to get and set a value
///
/// A write-up on the need for this class and it's approaches can be found at these links:
/// https://www.vadimbulavin.com/atomic-properties/
/// https://www.vadimbulavin.com/swift-atomic-properties-with-property-wrappers/
/// there is also another approach which can be taken but it requires separate types for collections and results in
/// a somewhat inconsistent interface between different `Atomic` wrappers
///
/// We use a Read-write lock approach because the `DispatchQueue` approach means mutating the property
/// occurs on a different thread, and GRDB requires it's changes to be executed on specific threads so using a lock
/// is more compatible (and Read-write locks allow for concurrent reads which shouldn't be a huge issue but could
/// help reduce cases of blocking)
@propertyWrapper
public class Atomic<Value> {
    private var value: Value
    private let lock: ReadWriteLock = ReadWriteLock()

    /// In order to change the value you **must** use the `mutate` function
    public var wrappedValue: Value {
        lock.readLock()
        let result: Value = value
        lock.unlock()

        return result
    }

    /// For more information see https://github.com/apple/swift-evolution/blob/master/proposals/0258-property-wrappers.md#projections
    public var projectedValue: Atomic<Value> {
        return self
    }
    
    // MARK: - Initialization

    public init(_ initialValue: Value) {
        self.value = initialValue
    }
    
    public init(wrappedValue: Value) {
        self.value = wrappedValue
    }
    
    // MARK: - Functions

    @discardableResult public func mutate<T>(_ mutation: (inout Value) -> T) -> T {
        lock.writeLock()
        let result: T = mutation(&value)
        lock.unlock()
        
        return result
    }
    
    @discardableResult public func mutate<T>(_ mutation: (inout Value) throws -> T) throws -> T {
        let result: T
        
        do {
            lock.writeLock()
            result = try mutation(&value)
            lock.unlock()
        }
        catch {
            lock.unlock()
            throw error
        }
        
        return result
    }
}

extension Atomic: CustomDebugStringConvertible where Value: CustomDebugStringConvertible {
    public var debugDescription: String {
        return value.debugDescription
    }
}

// MARK: - ReadWriteLock

private class ReadWriteLock {
    private var rwlock: pthread_rwlock_t
    
    // Need to do this in a proper init function instead of a lazy variable or it can indefinitely
    // hang on XCode 15 when trying to retrieve a lock (potentially due to optimisations?)
    init() {
        rwlock = pthread_rwlock_t()
        pthread_rwlock_init(&rwlock, nil)
    }
    
    func writeLock() {
        pthread_rwlock_wrlock(&rwlock)
    }
    
    func readLock() {
        pthread_rwlock_rdlock(&rwlock)
    }
    
    func unlock() {
        pthread_rwlock_unlock(&rwlock)
    }
}
