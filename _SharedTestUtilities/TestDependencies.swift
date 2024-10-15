// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Quick

@testable import SessionUtilitiesKit

public class TestDependencies: Dependencies {
    private var singletonInstances: [String: Any] = [:]
    private var cacheInstances: [String: MutableCacheType] = [:]
    private var defaultsInstances: [String: (any UserDefaultsType)] = [:]
    private var featureInstances: [String: (any FeatureType)] = [:]
    
    // MARK: - Subscript Access
    
    override public subscript<S>(singleton singleton: SingletonConfig<S>) -> S {
        guard let value: S = (singletonInstances[singleton.identifier] as? S) else {
            let value: S = singleton.createInstance(self)
            singletonInstances[singleton.identifier] = value
            return value
        }

        return value
    }
    
    public subscript<S>(singleton singleton: SingletonConfig<S>) -> S? {
        get { return (singletonInstances[singleton.identifier] as? S) }
        set { singletonInstances[singleton.identifier] = newValue }
    }
    
    override public subscript<M, I>(cache cache: CacheConfig<M, I>) -> I {
        guard let value: M = (cacheInstances[cache.identifier] as? M) else {
            let value: M = cache.createInstance(self)
            let mutableInstance: MutableCacheType = cache.mutableInstance(value)
            cacheInstances[cache.identifier] = mutableInstance
            return cache.immutableInstance(value)
        }
        
        return cache.immutableInstance(value)
    }
    
    public subscript<M, I>(cache cache: CacheConfig<M, I>) -> M? {
        get { return (cacheInstances[cache.identifier] as? M) }
        set { cacheInstances[cache.identifier] = newValue.map { cache.mutableInstance($0) } }
    }
    
    override public subscript(defaults defaults: UserDefaultsConfig) -> UserDefaultsType {
        guard let value: UserDefaultsType = defaultsInstances[defaults.identifier] else {
            let value: UserDefaultsType = defaults.createInstance(self)
            defaultsInstances[defaults.identifier] = value
            return value
        }

        return value
    }
    
    override public subscript<T: FeatureOption>(feature feature: FeatureConfig<T>) -> T {
        guard let value: Feature<T> = (featureInstances[feature.identifier] as? Feature<T>) else {
            let value: Feature<T> = feature.createInstance(self)
            featureInstances[feature.identifier] = value
            return value.currentValue(using: self)
        }
        
        return value.currentValue(using: self)
    }
    
    public subscript<T: FeatureOption>(feature feature: FeatureConfig<T>) -> T? {
        get { return (featureInstances[feature.identifier] as? T) }
        set {
            if featureInstances[feature.identifier] == nil {
                featureInstances[feature.identifier] = feature.createInstance(self)
            }
            
            set(feature: feature, to: newValue)
        }
    }
    
    public subscript(defaults defaults: UserDefaultsConfig) -> UserDefaultsType? {
        get { return defaultsInstances[defaults.identifier] }
        set { defaultsInstances[defaults.identifier] = newValue }
    }
    
    // MARK: - Timing and Async Handling

    private var _dateNow: Atomic<Date?> = Atomic(nil)
    override public var dateNow: Date {
        get { (_dateNow.wrappedValue ?? Date()) }
        set { _dateNow.mutate { $0 = newValue } }
    }

    private var _fixedTime: Atomic<Int?> = Atomic(nil)
    override public var fixedTime: Int {
        get { (_fixedTime.wrappedValue ?? 0) }
        set { _fixedTime.mutate { $0 = newValue } }
    }
    
    public var _forceSynchronous: Bool = false
    override public var forceSynchronous: Bool {
        get { _forceSynchronous }
        set { _forceSynchronous = newValue }
    }
    
    private var asyncExecutions: [Int: [() -> Void]] = [:]

    // MARK: - Initialization
    
    public init(initialState: ((TestDependencies) -> ())? = nil) {
        super.init(forTesting: true)
        
        initialState?(self)
    }
    
    // MARK: - Functions
    
    override public func async(at timestamp: TimeInterval, closure: @escaping () -> Void) {
        asyncExecutions.append(closure, toArrayOn: Int(ceil(timestamp)))
    }
    
    @discardableResult override public func mutate<M, I, R>(
        cache: CacheConfig<M, I>,
        _ mutation: (inout M) -> R
    ) -> R {
        var value: M = ((cacheInstances[cache.identifier] as? M) ?? cache.createInstance(self))
        let mutableInstance: MutableCacheType = cache.mutableInstance(value)
        cacheInstances[cache.identifier] = mutableInstance
        return mutation(&value)
    }
    
    @discardableResult override public func mutate<M, I, R>(
        cache: CacheConfig<M, I>,
        _ mutation: (inout M) throws -> R
    ) throws -> R {
        var value: M = ((cacheInstances[cache.identifier] as? M) ?? cache.createInstance(self))
        let mutableInstance: MutableCacheType = cache.mutableInstance(value)
        cacheInstances[cache.identifier] = mutableInstance
        return try mutation(&value)
    }
    
    public func stepForwardInTime() {
        let targetTime: Int = ((_fixedTime.wrappedValue ?? 0) + 1)
        _fixedTime.mutate { $0 = targetTime }
        
        if let currentDate: Date = _dateNow.wrappedValue {
            _dateNow.mutate { $0 = Date(timeIntervalSince1970: currentDate.timeIntervalSince1970 + 1) }
        }
        
        // Run and clear any executions which should run at the target time
        let targetKeys: [Int] = asyncExecutions.keys
            .filter { $0 <= targetTime }
        targetKeys.forEach { key in
            asyncExecutions[key]?.forEach { $0() }
            asyncExecutions[key] = nil
        }
    }
    
    // MARK: - Random Access Functions
    
    public override func randomElement<T: Collection>(_ collection: T) -> T.Element? {
        return collection.first
    }
    
    /// `Set<T>` is unsorted so we need a deterministic method to retrieve the same value each time
    public override func randomElement<T>(_ elements: Set<T>) -> T? {
        return Array(elements)
            .sorted { lhs, rhs -> Bool in lhs.hashValue < rhs.hashValue }
            .first
    }
    
    /// `Set<T>` is unsorted so we need a deterministic method to retrieve the same value each time
    public override func popRandomElement<T>(_ elements: inout Set<T>) -> T? {
        let result: T? = Array(elements)
            .sorted { lhs, rhs -> Bool in lhs.hashValue < rhs.hashValue }
            .first
        
        return result.map { elements.remove($0) }
    }
    
    // MARK: - Instance replacing
    
    public override func set<S>(singleton: SingletonConfig<S>, to instance: S) {
        singletonInstances[singleton.identifier] = instance
    }
    
    public override func set<M, I>(cache: CacheConfig<M, I>, to instance: M) {
        cacheInstances[cache.identifier] = cache.mutableInstance(instance)
    }
    
    public override func remove<M, I>(cache: CacheConfig<M, I>) {
        cacheInstances[cache.identifier] = nil
    }
}

// MARK: - TestState Convenience

internal extension TestState {
    init<M, I>(
        wrappedValue: @escaping @autoclosure () -> T?,
        cache: CacheConfig<M, I>,
        in dependenciesRetriever: @escaping @autoclosure () -> TestDependencies?
    ) where T: MutableCacheType {
        self.init(wrappedValue: {
            let dependencies: TestDependencies? = dependenciesRetriever()
            let value: T? = wrappedValue()
            (value as? DependenciesSettable)?.setDependencies(dependencies)
            dependencies?[cache: cache] = (value as! M)
            
            return value
        }())
    }
    
    init<S>(
        wrappedValue: @escaping @autoclosure () -> T?,
        singleton: SingletonConfig<S>,
        in dependenciesRetriever: @escaping @autoclosure () -> TestDependencies?
    ) {
        self.init(wrappedValue: {
            let dependencies: TestDependencies? = dependenciesRetriever()
            let value: T? = wrappedValue()
            (value as? DependenciesSettable)?.setDependencies(dependencies)
            dependencies?[singleton: singleton] = (value as! S)
            
            return value
        }())
    }
    
    init(
        wrappedValue: @escaping @autoclosure () -> T?,
        defaults: UserDefaultsConfig,
        in dependenciesRetriever: @escaping @autoclosure () -> TestDependencies?
    ) where T: UserDefaultsType {
        self.init(wrappedValue: {
            let dependencies: TestDependencies? = dependenciesRetriever()
            let value: T? = wrappedValue()
            (value as? DependenciesSettable)?.setDependencies(dependencies)
            dependencies?[defaults: defaults] = value
            
            return value
        }())
    }
}
