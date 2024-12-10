// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine

public class Dependencies {
    static let userInfoKey: CodingUserInfoKey = CodingUserInfoKey(rawValue: "session.dependencies.codingOptions")!
    
    /// The `isRTLRetriever` is handled differently from normal dependencies because it's not really treated as such (it's more of
    /// a convenience thing than anything) as such it's held outside of the `DependencyStorage`
    private static var _isRTLRetriever: Atomic<(Bool, () -> Bool)> = Atomic((false, { false }))
    private static var _lastCreatedInstance: Atomic<Dependencies?> = Atomic(nil)
    private let featureChangeSubject: PassthroughSubject<(String, String?, Any?), Never> = PassthroughSubject()
    private var storage: Atomic<DependencyStorage> = Atomic(DependencyStorage())
    
    // MARK: - Subscript Access
    
    public subscript<S>(singleton singleton: SingletonConfig<S>) -> S { getOrCreate(singleton) }
    public subscript<M, I>(cache cache: CacheConfig<M, I>) -> I { getOrCreate(cache).immutable(cache: cache, using: self) }
    public subscript(defaults defaults: UserDefaultsConfig) -> UserDefaultsType { getOrCreate(defaults) }
    public subscript<T: FeatureOption>(feature feature: FeatureConfig<T>) -> T { getOrCreate(feature).currentValue(using: self) }
    
    // MARK: - Global Values, Timing and Async Handling
    
    /// We should avoid using this value wherever possible because it's not properly injected (which means unit tests won't work correctly
    /// for anything accessed via this value)
    public static var unsafeNonInjected: Dependencies { _lastCreatedInstance.wrappedValue ?? Dependencies() }
    
    public static var isRTL: Bool {
        let (requiresMainThread, retriever): (Bool, () -> Bool) = _isRTLRetriever.wrappedValue
        
        /// Determining `isRTL` might require running on the main thread (it may need to accesses UIKit), if it requires the main thread but
        /// we are on a different thread then just default to `false` to prevent the background thread from potentially lagging and/or crashing
        guard !requiresMainThread || Thread.isMainThread else { return false }
        
        return retriever()
    }
    
    public var dateNow: Date { Date() }
    public var fixedTime: Int { 0 }
    public var forceSynchronous: Bool { false }
    
    // MARK: - Initialization
    
    private init() {
        Dependencies._lastCreatedInstance.mutate { $0 = self }
    }
    internal init(forTesting: Bool) {}
    public static func createEmpty() -> Dependencies { return Dependencies() }
    
    // MARK: - Functions
    
    public func async(at fixedTime: Int, closure: @escaping () -> Void) {
        async(at: TimeInterval(fixedTime), closure: closure)
    }
    
    public func async(at timestamp: TimeInterval, closure: @escaping () -> Void) {}
    
    @discardableResult public func mutate<M, I, R>(
        cache: CacheConfig<M, I>,
        _ mutation: (inout M) -> R
    ) -> R {
        return getOrCreate(cache).mutate { erasedValue in
            guard var value: M = (erasedValue as? M) else {
                /// This code path should never happen (and is essentially invalid if it does) but in order to avoid neeing to return
                /// a nullable type or force-casting this is how we need to do things)
                Log.critical("Failed to convert erased cache value for '\(cache.identifier)' to expected type: \(M.self)")
                var fallbackValue: M = cache.createInstance(self)
                return mutation(&fallbackValue)
            }
            
            return mutation(&value)
        }
    }
    
    @discardableResult public func mutate<M, I, R>(
        cache: CacheConfig<M, I>,
        _ mutation: (inout M) throws -> R
    ) throws -> R {
        return try getOrCreate(cache).mutate { erasedValue in
            guard var value: M = (erasedValue as? M) else {
                /// This code path should never happen (and is essentially invalid if it does) but in order to avoid neeing to return
                /// a nullable type or force-casting this is how we need to do things)
                Log.critical("Failed to convert erased cache value for '\(cache.identifier)' to expected type: \(M.self)")
                var fallbackValue: M = cache.createInstance(self)
                return try mutation(&fallbackValue)
            }
            
            return try mutation(&value)
        }
    }
    
    // MARK: - Random Access Functions
    
    public func randomElement<T: Collection>(_ collection: T) -> T.Element? {
        return collection.randomElement()
    }
    
    public func randomElement<T>(_ elements: Set<T>) -> T? {
        return elements.randomElement()
    }
    
    public func popRandomElement<T>(_ elements: inout Set<T>) -> T? {
        return elements.popRandomElement()
    }
    
    // MARK: - Instance replacing
    
    public func warmCache<M, I>(cache: CacheConfig<M, I>) {
        _ = getOrCreate(cache)
    }
    
    public func set<S>(singleton: SingletonConfig<S>, to instance: S) {
        threadSafeChange(for: singleton.identifier, of: .singleton) {
            setValue(instance, typedStorage: .singleton(instance), key: singleton.identifier)
        }
    }
    
    public func set<M, I>(cache: CacheConfig<M, I>, to instance: M) {
        threadSafeChange(for: cache.identifier, of: .cache) {
            let value: Atomic<MutableCacheType> = Atomic(cache.mutableInstance(instance))
            setValue(value, typedStorage: .cache(value), key: cache.identifier)
        }
    }
    
    public func remove<M, I>(cache: CacheConfig<M, I>) {
        threadSafeChange(for: cache.identifier, of: .cache) {
            removeValue(cache.identifier, of: .cache)
        }
    }
    
    public static func setIsRTLRetriever(requiresMainThread: Bool, isRTLRetriever: @escaping () -> Bool) {
        _isRTLRetriever.mutate { $0 = (requiresMainThread, isRTLRetriever) }
    }
}

// MARK: - Cache Management

private extension Atomic<MutableCacheType> {
    func immutable<M, I>(cache: CacheConfig<M, I>, using dependencies: Dependencies) -> I {
        return cache.immutableInstance(
            (self.wrappedValue as? M) ??
            cache.createInstance(dependencies)
        )
    }
}

// MARK: - Feature Management

public extension Dependencies {
    func publisher<T: FeatureOption>(feature: FeatureConfig<T>) -> AnyPublisher<T?, Never> {
        return featureChangeSubject
            .filter { identifier, _, _ in identifier == feature.identifier }
            .compactMap { _, _, value in value as? T }
            .prepend(self[feature: feature])    // Emit the current value first
            .eraseToAnyPublisher()
    }
    
    func publisher<T: FeatureOption>(featureGroupChanges feature: FeatureConfig<T>) -> AnyPublisher<Void, Never> {
        return featureChangeSubject
            .filter { _, groupIdentifier, _ in groupIdentifier == feature.groupIdentifier }
            .map { _, _, _ in () }
            .prepend(())            // Emit an initial value to behave similar to the above
            .eraseToAnyPublisher()
    }
    
    func featureUpdated<T: FeatureOption>(for feature: FeatureConfig<T>) -> AnyPublisher<T?, Never> {
        return featureChangeSubject
            .filter { identifier, _, _ in identifier == feature.identifier }
            .compactMap { _, _, value in value as? T }
            .eraseToAnyPublisher()
    }
    
    func featureGroupUpdated<T: FeatureOption>(for feature: FeatureConfig<T>) -> AnyPublisher<T?, Never> {
        return featureChangeSubject
            .filter { _, groupIdentifier, _ in groupIdentifier == feature.groupIdentifier }
            .compactMap { _, _, value in value as? T }
            .eraseToAnyPublisher()
    }
    
    func set<T: FeatureOption>(feature: FeatureConfig<T>, to updatedFeature: T?) {
        threadSafeChange(for: feature.identifier, of: .feature) {
            /// Update the cached & in-memory values
            let instance: Feature<T> = (
                getValue(feature.identifier, of: .feature) ??
                feature.createInstance(self)
            )
            instance.setValue(to: updatedFeature, using: self)
            setValue(instance, typedStorage: .feature(instance), key: feature.identifier)
        }
        
        /// Notify observers
        featureChangeSubject.send((feature.identifier, feature.groupIdentifier, updatedFeature))
    }
    
    func reset<T: FeatureOption>(feature: FeatureConfig<T>) {
        threadSafeChange(for: feature.identifier, of: .feature) {
            /// Reset the cached and in-memory values
            let instance: Feature<T>? = getValue(feature.identifier, of: .feature)
            instance?.setValue(to: nil, using: self)
            removeValue(feature.identifier, of: .feature)
        }
        
        /// Notify observers
        featureChangeSubject.send((feature.identifier, feature.groupIdentifier, nil))
    }
}

// MARK: - Storage Setting Convenience

public extension Dependencies {
    subscript(singleton singleton: SingletonConfig<Storage>, key key: Setting.BoolKey) -> Bool {
        return self[singleton: singleton]
            .read { db in db[key] }
            .defaulting(to: false)  // Default to false if it doesn't exist
    }
    
    subscript(singleton singleton: SingletonConfig<Storage>, key key: Setting.DoubleKey) -> Double? {
        return self[singleton: singleton].read { db in db[key] }
    }
    
    subscript(singleton singleton: SingletonConfig<Storage>, key key: Setting.IntKey) -> Int? {
        return self[singleton: singleton].read { db in db[key] }
    }
    
    subscript(singleton singleton: SingletonConfig<Storage>, key key: Setting.StringKey) -> String? {
        return self[singleton: singleton].read { db in db[key] }
    }
    
    subscript(singleton singleton: SingletonConfig<Storage>, key key: Setting.DateKey) -> Date? {
        return self[singleton: singleton].read { db in db[key] }
    }
    
    subscript<T: EnumIntSetting>(singleton singleton: SingletonConfig<Storage>, key key: Setting.EnumKey) -> T? {
        return self[singleton: singleton].read { db in db[key] }
    }
    
    subscript<T: EnumStringSetting>(singleton singleton: SingletonConfig<Storage>, key key: Setting.EnumKey) -> T? {
        return self[singleton: singleton].read { db in db[key] }
    }
}

// MARK: - UserDefaults Convenience

public extension Dependencies {
    subscript(defaults defaults: UserDefaultsConfig, key key: UserDefaults.BoolKey) -> Bool {
        get { return self[defaults: defaults].bool(forKey: key.rawValue) }
        set { self[defaults: defaults].set(newValue, forKey: key.rawValue) }
    }

    subscript(defaults defaults: UserDefaultsConfig, key key: UserDefaults.DateKey) -> Date? {
        get { return self[defaults: defaults].object(forKey: key.rawValue) as? Date }
        set { self[defaults: defaults].set(newValue, forKey: key.rawValue) }
    }
    
    subscript(defaults defaults: UserDefaultsConfig, key key: UserDefaults.DoubleKey) -> Double {
        get { return self[defaults: defaults].double(forKey: key.rawValue) }
        set { self[defaults: defaults].set(newValue, forKey: key.rawValue) }
    }

    subscript(defaults defaults: UserDefaultsConfig, key key: UserDefaults.IntKey) -> Int {
        get { return self[defaults: defaults].integer(forKey: key.rawValue) }
        set { self[defaults: defaults].set(newValue, forKey: key.rawValue) }
    }
    
    subscript(defaults defaults: UserDefaultsConfig, key key: UserDefaults.StringKey) -> String? {
        get { return self[defaults: defaults].string(forKey: key.rawValue) }
        set { self[defaults: defaults].set(newValue, forKey: key.rawValue) }
    }
}

// MARK: - DependenciesError

public enum DependenciesError: Error {
    case missingDependencies
}

// MARK: - Storage Management

private extension Dependencies {
    struct DependencyStorage {
        var initializationLocks: [Key: NSLock] = [:]
        var instances: [Key: Value] = [:]
        
        struct Key: Hashable, CustomStringConvertible {
            enum Variant: String {
                case singleton
                case cache
                case userDefaults
                case feature
                
                func key(_ identifier: String) -> Key {
                    return Key(identifier, of: self)
                }
            }
            
            let identifier: String
            let variant: Variant
            var description: String { "\(variant): \(identifier)" }
            
            init(_ identifier: String, of variant: Variant) {
                self.identifier = identifier
                self.variant = variant
            }
        }
        
        enum Value {
            case singleton(Any)
            case cache(Atomic<MutableCacheType>)
            case userDefaults(UserDefaultsType)
            case feature(any FeatureType)
            
            func distinctKey(for identifier: String) -> Key {
                switch self {
                    case .singleton: return Key(identifier, of: .singleton)
                    case .cache: return Key(identifier, of: .cache)
                    case .userDefaults: return Key(identifier, of: .userDefaults)
                    case .feature: return Key(identifier, of: .feature)
                }
            }
            
            func value<T>(as type: T.Type) -> T? {
                switch self {
                    case .singleton(let value): return value as? T
                    case .cache(let value): return value as? T
                    case .userDefaults(let value): return value as? T
                    case .feature(let value): return value as? T
                }
            }
        }
    }
    
    private func getOrCreate<S>(_ singleton: SingletonConfig<S>) -> S {
        return getOrCreateInstance(
            identifier: singleton.identifier,
            constructor: .singleton { singleton.createInstance(self) }
        )
    }
    
    private func getOrCreate<M, I>(_ cache: CacheConfig<M, I>) -> Atomic<MutableCacheType> {
        return getOrCreateInstance(
            identifier: cache.identifier,
            constructor: .cache { Atomic(cache.mutableInstance(cache.createInstance(self))) }
        )
    }
    
    private func getOrCreate(_ defaults: UserDefaultsConfig) -> UserDefaultsType {
        return getOrCreateInstance(
            identifier: defaults.identifier,
            constructor: .userDefaults { defaults.createInstance(self) }
        )
    }
    
    private func getOrCreate<T: FeatureOption>(_ feature: FeatureConfig<T>) -> Feature<T> {
        return getOrCreateInstance(
            identifier: feature.identifier,
            constructor: .feature { feature.createInstance(self) }
        )
    }
    
    // MARK: - Instance upserting
    
    /// Retrieves the current instance or, if one doesn't exist, uses the `StorageHelper.Info<Value>` to create a new instance
    /// and store it
    private func getOrCreateInstance<Value>(
        identifier: String,
        constructor: DependencyStorage.Constructor<Value>
    ) -> Value {
        /// If we already have an instance then just return that
        if let existingValue: Value = getValue(identifier, of: constructor.variant) {
            return existingValue
        }
        
        return threadSafeChange(for: identifier, of: constructor.variant) {
            /// Now that we are within a synchronized group, check to make sure an instance wasn't created while we were waiting to
            /// enter the group
            if let existingValue: Value = getValue(identifier, of: constructor.variant) {
                return existingValue
            }
            
            let result: (typedStorage: DependencyStorage.Value, value: Value) = constructor.create()
            setValue(result.value, typedStorage: result.typedStorage, key: identifier)
            return result.value
        }
    }
    
    /// Convenience method to retrieve the existing dependency instance from memory in a thread-safe way
    private func getValue<T>(_ key: String, of variant: DependencyStorage.Key.Variant) -> T? {
        guard let typedValue: DependencyStorage.Value = storage.wrappedValue.instances[variant.key(key)] else { return nil }
        guard let result: T = typedValue.value(as: T.self) else {
            /// If there is a value stored for the key, but it's not the right type then something has gone wrong, and we should log
            Log.critical("Failed to convert stored dependency '\(variant.key(key))' to expected type: \(T.self)")
            return nil
        }
        
        return result
    }
    
    /// Convenience method to store a dependency instance in memory in a thread-safe way
    @discardableResult private func setValue<T>(_ value: T, typedStorage: DependencyStorage.Value, key: String) -> T {
        storage.mutate { $0.instances[typedStorage.distinctKey(for: key)] = typedStorage }
        return value
    }
    
    /// Convenience method to remove a dependency instance from memory in a thread-safe way
    private func removeValue(_ key: String, of variant: DependencyStorage.Key.Variant) {
        storage.mutate { $0.instances.removeValue(forKey: variant.key(key)) }
    }
    
    /// This function creates an `NSLock` for the given identifier which allows us to block instance creation on a per-identifier basis
    /// and avoid situations where multithreading could result in multiple instances of the same dependency being created concurrently
    ///
    /// **Note:** This `NSLock` is an additional mechanism on top of the `Atomic<T>` because the interface is a little simpler
    /// and we don't need to wrap every instance within `Atomic<T>` this way
    @discardableResult private func threadSafeChange<T>(for identifier: String, of variant: DependencyStorage.Key.Variant, change: () -> T) -> T {
        let lock: NSLock = storage.mutate { storage in
            if let existing = storage.initializationLocks[variant.key(identifier)] {
                return existing
            }
            
            let lock: NSLock = NSLock()
            storage.initializationLocks[variant.key(identifier)] = lock
            return lock
        }
        lock.lock()
        defer { lock.unlock() }
        
        return change()
    }
}
 
// MARK: - DSL

private extension Dependencies.DependencyStorage {
    struct Constructor<T> {
        let variant: Key.Variant
        let create: () -> (typedStorage: Dependencies.DependencyStorage.Value, value: T)
        
        static func singleton(_ constructor: @escaping () -> T) -> Constructor<T> {
            return Constructor(variant: .singleton) {
                let instance: T = constructor()
                
                return (.singleton(instance), instance)
            }
        }
        
        static func cache(_ constructor: @escaping () -> T) -> Constructor<T> where T: Atomic<MutableCacheType> {
            return Constructor(variant: .cache) {
                let instance: T = constructor()
                
                return (.cache(instance), instance)
            }
        }
        
        static func userDefaults(_ constructor: @escaping () -> T) -> Constructor<T> where T == UserDefaultsType {
            return Constructor(variant: .userDefaults) {
                let instance: T = constructor()
                
                return (.userDefaults(instance), instance)
            }
        }
        
        static func feature(_ constructor: @escaping () -> T) -> Constructor<T> where T: FeatureType {
            return Constructor(variant: .feature) {
                let instance: T = constructor()
                
                return (.feature(instance), instance)
            }
        }
    }
}
