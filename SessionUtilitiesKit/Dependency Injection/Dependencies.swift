// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine

public class Dependencies {
    static let userInfoKey: CodingUserInfoKey = CodingUserInfoKey(rawValue: "io.oxen.dependencies.codingOptions")!
    
    private static var _isRTLRetriever: Atomic<(Bool, () -> Bool)> = Atomic((false, { false }))
    private static var singletonInstances: Atomic<[String: Any]> = Atomic([:])
    private static var cacheInstances: Atomic<[String: Atomic<MutableCacheType>]> = Atomic([:])
    private static var userDefaultsInstances: Atomic<[String: (any UserDefaultsType)]> = Atomic([:])
    private static var featureInstances: Atomic<[String: (any FeatureType)]> = Atomic([:])
    private var featureChangeSubject: PassthroughSubject<(String, String?, Any?), Never> = PassthroughSubject()
    
    // MARK: - Subscript Access
    
    public subscript<S>(singleton singleton: SingletonConfig<S>) -> S {
        guard let value: S = (Dependencies.singletonInstances.wrappedValue[singleton.identifier] as? S) else {
            let value: S = singleton.createInstance(self)
            Dependencies.singletonInstances.mutate { $0[singleton.identifier] = value }
            return value
        }

        return value
    }
    
    public subscript<M, I>(cache cache: CacheConfig<M, I>) -> I {
        getValueSettingIfNull(cache: cache)
    }
    
    public subscript(defaults defaults: UserDefaultsConfig) -> UserDefaultsType {
        guard let value: UserDefaultsType = Dependencies.userDefaultsInstances.wrappedValue[defaults.identifier] else {
            let value: UserDefaultsType = defaults.createInstance(self)
            Dependencies.userDefaultsInstances.mutate { $0[defaults.identifier] = value }
            return value
        }
        
        return value
    }
    
    public subscript<T: FeatureOption>(feature feature: FeatureConfig<T>) -> T {
        guard let value: Feature<T> = (Dependencies.featureInstances.wrappedValue[feature.identifier] as? Feature<T>) else {
            let value: Feature<T> = feature.createInstance(self)
            Dependencies.featureInstances.mutate { $0[feature.identifier] = value }
            return value.currentValue(using: self)
        }
        
        return value.currentValue(using: self)
    }
    
    // MARK: - Global Values, Timing and Async Handling
    
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
    
    private init() {}
    public static func createEmpty() -> Dependencies { return Dependencies() }
    
    // MARK: - Functions
    
    public func mockableValue<T>(key: String? = nil, _ defaultValue: T) -> T { defaultValue }
    
    public func async(at fixedTime: Int, closure: @escaping () -> Void) {
        async(at: TimeInterval(fixedTime), closure: closure)
    }
    
    public func async(at timestamp: TimeInterval, closure: @escaping () -> Void) {}
    
    @discardableResult public func mutate<M, I, R>(
        cache: CacheConfig<M, I>,
        _ mutation: (inout M) -> R
    ) -> R {
        /// The cast from `Atomic<MutableCacheType>` to `Atomic<M>` always fails so we need to do some
        /// stuffing around to ensure we have the right types - since we call `createInstance` multiple times in
        /// the below code we first call `getValueSettingIfNull` to ensure we have a proper instance stored
        /// in `Dependencies.cacheInstances` so that we can be reliably certail we aren't accessing some
        /// random instance that will go out of memory as soon as the mutation is completed
        getValueSettingIfNull(cache: cache)
        
        let cacheWrapper: Atomic<MutableCacheType> = (
            Dependencies.cacheInstances.wrappedValue[cache.identifier] ??
            Atomic(cache.mutableInstance(cache.createInstance(self)))  // Should never be called
        )
        
        return cacheWrapper.mutate { erasedValue in
            var value: M = ((erasedValue as? M) ?? cache.createInstance(self))
            return mutation(&value)
        }
    }
    
    @discardableResult public func mutate<M, I, R>(
        cache: CacheConfig<M, I>,
        _ mutation: (inout M) throws -> R
    ) throws -> R {
        /// The cast from `Atomic<MutableCacheType>` to `Atomic<M>` always fails so we need to do some
        /// stuffing around to ensure we have the right types - since we call `createInstance` multiple times in
        /// the below code we first call `getValueSettingIfNull` to ensure we have a proper instance stored
        /// in `Dependencies.cacheInstances` so that we can be reliably certail we aren't accessing some
        /// random instance that will go out of memory as soon as the mutation is completed
        getValueSettingIfNull(cache: cache)
        
        let cacheWrapper: Atomic<MutableCacheType> = (
            Dependencies.cacheInstances.wrappedValue[cache.identifier] ??
            Atomic(cache.mutableInstance(cache.createInstance(self)))  // Should never be called
        )
        
        return try cacheWrapper.mutate { erasedValue in
            var value: M = ((erasedValue as? M) ?? cache.createInstance(self))
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

    // MARK: - Instance upserting
    
    @discardableResult private func getValueSettingIfNull<M, I>(cache: CacheConfig<M, I>) -> I {
        guard let value: M = (Dependencies.cacheInstances.wrappedValue[cache.identifier]?.wrappedValue as? M) else {
            let value: M = cache.createInstance(self)
            let mutableInstance: MutableCacheType = cache.mutableInstance(value)
            Dependencies.cacheInstances.mutate { $0[cache.identifier] = Atomic(mutableInstance) }
            return cache.immutableInstance(value)
        }
        
        return cache.immutableInstance(value)
    }
    
    // MARK: - Instance replacing
    
    public func hasInitialised<S>(singleton: SingletonConfig<S>) -> Bool {
        return (Dependencies.singletonInstances.wrappedValue[singleton.identifier] != nil)
    }
    
    public func warmCache<M, I>(cache: CacheConfig<M, I>) {
        _ = getValueSettingIfNull(cache: cache)
    }
    
    public func set<S>(singleton: SingletonConfig<S>, to instance: S) {
        Dependencies.singletonInstances.mutate {
            $0[singleton.identifier] = instance
        }
    }
    
    public func set<M, I>(cache: CacheConfig<M, I>, to instance: M) {
        Dependencies.cacheInstances.mutate {
            $0[cache.identifier] = Atomic(cache.mutableInstance(instance))
        }
    }
    
    public func remove<M, I>(cache: CacheConfig<M, I>) {
        Dependencies.cacheInstances.mutate {
            $0[cache.identifier] = nil
        }
    }
    
    public static func setIsRTLRetriever(requiresMainThread: Bool, isRTLRetriever: @escaping () -> Bool) {
        _isRTLRetriever.mutate { $0 = (requiresMainThread, isRTLRetriever) }
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
        let value: Feature<T> = {
            guard let value: Feature<T> = (Dependencies.featureInstances.wrappedValue[feature.identifier] as? Feature<T>) else {
                let value: Feature<T> = feature.createInstance(self)
                Dependencies.featureInstances.mutate { $0[feature.identifier] = value }
                return value
            }
            
            return value
        }()
        
        value.setValue(to: updatedFeature, using: self)
        featureChangeSubject.send((feature.identifier, feature.groupIdentifier, updatedFeature))
    }
    
    func reset<T: FeatureOption>(feature: FeatureConfig<T>) {
        /// Reset the cached value
        switch Dependencies.featureInstances.wrappedValue[feature.identifier] as? Feature<T> {
            case .none: break
            case .some(let value): value.setValue(to: nil, using: self)
        }
        
        /// Reset the in-memory value
        Dependencies.featureInstances.mutate {
            $0[feature.identifier] = nil
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
