// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public class Dependencies {
    private var _storage: Atomic<Storage?>
    public var storage: Storage {
        get { Dependencies.getValueSettingIfNull(&_storage) { Storage.shared } }
        set { _storage.mutate { $0 = newValue } }
    }
    
    private var _network: Atomic<NetworkType?>
    public var network: NetworkType {
        get { Dependencies.getValueSettingIfNull(&_network) { Network() } }
        set { _network.mutate { $0 = newValue } }
    }
    
    private var _crypto: Atomic<CryptoType?>
    public var crypto: CryptoType {
        get { Dependencies.getValueSettingIfNull(&_crypto) { Crypto() } }
        set { _crypto.mutate { $0 = newValue } }
    }
    
    private var _standardUserDefaults: Atomic<UserDefaultsType?>
    public var standardUserDefaults: UserDefaultsType {
        get { Dependencies.getValueSettingIfNull(&_standardUserDefaults) { UserDefaults.standard } }
        set { _standardUserDefaults.mutate { $0 = newValue } }
    }
    
    private var _caches: CachesType
    public var caches: CachesType {
        get { _caches }
        set { _caches = newValue }
    }
    
    private var _jobRunner: Atomic<JobRunnerType?>
    public var jobRunner: JobRunnerType {
        get { Dependencies.getValueSettingIfNull(&_jobRunner) { JobRunner.instance } }
        set { _jobRunner.mutate { $0 = newValue } }
    }
    
    private var _scheduler: Atomic<ValueObservationScheduler?>
    public var scheduler: ValueObservationScheduler {
        get { Dependencies.getValueSettingIfNull(&_scheduler) { Storage.defaultPublisherScheduler } }
        set { _scheduler.mutate { $0 = newValue } }
    }
    
    private var _dateNow: Atomic<Date?>
    public var dateNow: Date {
        get { (_dateNow.wrappedValue ?? Date()) }
        set { _dateNow.mutate { $0 = newValue } }
    }
    
    private var _fixedTime: Atomic<Int?>
    public var fixedTime: Int {
        get { Dependencies.getValueSettingIfNull(&_fixedTime) { 0 } }
        set { _fixedTime.mutate { $0 = newValue } }
    }
    
    private var _forceSynchronous: Bool
    public var forceSynchronous: Bool {
        get { _forceSynchronous }
        set { _forceSynchronous = newValue }
    }
    
    public var asyncExecutions: [Int: [() -> Void]] = [:]
    
    // MARK: - Initialization
    
    public init(
        storage: Storage? = nil,
        network: NetworkType? = nil,
        crypto: CryptoType? = nil,
        standardUserDefaults: UserDefaultsType? = nil,
        caches: CachesType = Caches(),
        jobRunner: JobRunnerType? = nil,
        scheduler: ValueObservationScheduler? = nil,
        dateNow: Date? = nil,
        fixedTime: Int? = nil,
        forceSynchronous: Bool = false
    ) {
        _storage = Atomic(storage)
        _network = Atomic(network)
        _crypto = Atomic(crypto)
        _standardUserDefaults = Atomic(standardUserDefaults)
        _caches = caches
        _jobRunner = Atomic(jobRunner)
        _scheduler = Atomic(scheduler)
        _dateNow = Atomic(dateNow)
        _fixedTime = Atomic(fixedTime)
        _forceSynchronous = forceSynchronous
    }
    
    // MARK: - Convenience
    
    private static func getValueSettingIfNull<T>(_ maybeValue: inout Atomic<T?>, _ valueGenerator: () -> T) -> T {
        guard let value: T = maybeValue.wrappedValue else {
            let value: T = valueGenerator()
            maybeValue.mutate { $0 = value }
            return value
        }
        
        return value
    }
    
    private static func getMutableValueSettingIfNull<T>(_ maybeValue: inout Atomic<T?>, _ valueGenerator: () -> T) -> Atomic<T> {
        guard let value: T = maybeValue.wrappedValue else {
            let value: T = valueGenerator()
            maybeValue.mutate { $0 = value }
            return Atomic(value)
        }
        
        return Atomic(value)
    }
    
#if DEBUG
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
#endif
    
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
}
