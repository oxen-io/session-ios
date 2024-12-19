// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - Cache

public extension Cache {
    static let ip2Country: CacheConfig<IP2CountryCacheType, IP2CountryImmutableCacheType> = Dependencies.create(
        identifier: "ip2Country",
        createInstance: { dependencies in IP2Country(using: dependencies) },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - Log.Category

public extension Log.Category {
    static let ip2Country: Log.Category = .create("IP2Country", defaultLevel: .info)
}

// MARK: - IP2Country

fileprivate class IP2Country: IP2CountryCacheType {
    private var countryNamesCache: [String: String] = [:]
    private let _cacheLoaded: CurrentValueSubject<Bool, Never> = CurrentValueSubject(false)
    private var disposables: Set<AnyCancellable> = Set()
    private var currentLocale: String {
        let result: String? = Locale.current.identifier
            .components(separatedBy: "_")
            .first
            .map { identifier in
                switch identifier {
                    case "zh-Hans", "zh": return "zh-CN"  // Not ideal, but the best we can do
                    default: return identifier
                }
            }
        
        return (result ?? "en")  // Fallback to English
    }
    public var cacheLoaded: AnyPublisher<Bool, Never> {
        _cacheLoaded.filter { $0 }.eraseToAnyPublisher()
    }
    
    // MARK: - Tables
    
    /// This struct contains the data from two tables
    ///
    /// The `countryBlocks` has two columns: the "network" column and the "registered_country_geoname_id" column
    ///
    /// The network column contains the **lower** bound of an IP range and the "registered_country_geoname_id" column contains the
    /// ID of the country corresponding to that range. We look up an IP by finding the first index in the network column where the value is
    /// greater than the IP we're looking up (converted to an integer). The IP we're looking up must then be in the range **before** that range.
    ///
    /// The `countryLocations` has three columns: the "locale_code" column, the "geoname_id" column and the "country_name" column
    ///
    /// These are populated in such a way that you would retrieve in index range in `countryLocationsLocaleCode` for the current locale
    /// (or `en` as default), then find the `geonameId` index from `countryLocationsGeonameId` using the same range, and that index
    /// should be retrieved from `countryLocationsCountryName` in order to get the country name
    struct IP2CountryCache {
        var countryBlocksIPInt: [Int64] = []
        var countryBlocksGeonameId: [String] = []
        
        var countryLocationsLocaleCode: [String] = []
        var countryLocationsGeonameId: [String] = []
        var countryLocationsCountryName: [String] = []
    }
    
    private var cache: IP2CountryCache = {
        guard
            let url: URL = Bundle.main.url(forResource: "GeoLite2-Country-Blocks-IPv4", withExtension: nil),
            let data: Data = try? Data(contentsOf: url)
        else { return IP2CountryCache() }
        
        /// Extract the number of IPs
        var countryBlockIPCount: Int32 = 0
        _ = withUnsafeMutableBytes(of: &countryBlockIPCount) { countBuffer in
            data.copyBytes(to: countBuffer, from: ..<MemoryLayout<Int32>.size)
        }
        
        /// Move past the IP count
        var remainingData: Data = data.advanced(by: MemoryLayout<Int32>.size)
        
        /// Extract the IPs
        var countryBlockIpInts: [Int64] = [Int64](repeating: 0, count: Int(countryBlockIPCount))
        remainingData.withUnsafeBytes { buffer in
            _ = countryBlockIpInts.withUnsafeMutableBytes { ipBuffer in
                memcpy(ipBuffer.baseAddress, buffer.baseAddress, Int(countryBlockIPCount) * MemoryLayout<Int64>.size)
            }
        }
        
        var countryBlockIpInts2: [Int] = [Int](repeating: 0, count: Int(countryBlockIPCount))
        remainingData.withUnsafeBytes { buffer in
            _ = countryBlockIpInts.withUnsafeMutableBytes { ipBuffer in
                memcpy(ipBuffer.baseAddress, buffer.baseAddress, Int(countryBlockIPCount) * MemoryLayout<Int>.size)
            }
        }
        
        /// Extract arrays from the parts
        func consumeStringArray(_ name: String, from targetData: inout Data) -> [String] {
            /// The data should have a count, followed by actual data (so should have more data than an Int32 would take
            guard targetData.count > MemoryLayout<Int32>.size else {
                Log.error(.ip2Country, "\(name) doesn't have enough data after the count.")
                return []
            }
            
            var targetCount: Int32 = targetData
                .prefix(MemoryLayout<Int32>.size)
                .withUnsafeBytes { bytes -> Int32 in
                    guard
                        bytes.count >= MemoryLayout<Int32>.size,
                        let baseAddress: UnsafePointer<Int32> = bytes
                            .bindMemory(to: Int32.self)
                            .baseAddress
                    else { return 0 }
                    
                    return baseAddress.pointee
                }
            
            /// Move past the count and extract the content data
            targetData = targetData.dropFirst(MemoryLayout<Int32>.size)
            let contentData: Data = targetData.prefix(Int(targetCount))
            
            guard
                !contentData.isEmpty,
                let contentString: String = String(data: contentData, encoding: .utf8)
            else {
                Log.error(.ip2Country, "\(name) failed to convert the content to a string.")
                return []
            }
            
            /// There was a crash related to advancing the data in an invalid way in `2.7.0`, if this does occur then
            /// we want to know about it so add a log
            if targetCount > targetData.count {
                Log.error(.ip2Country, "\(name) suggested it had mare data then was actually available (\(targetCount) vs. \(targetData.count)).")
            }
            
            /// Move past the data and return the result
            targetData = targetData.dropFirst(Int(targetCount))
            return contentString.components(separatedBy: "\0\0")
        }
        
        /// Move past the IP data
        remainingData = remainingData.advanced(by: (Int(countryBlockIPCount) * MemoryLayout<Int64>.size))
        let countryBlocksGeonameIds: [String] = consumeStringArray("CountryBlocks", from: &remainingData)
        let countryLocaleCodes: [String] = consumeStringArray("LocaleCodes", from: &remainingData)
        let countryGeonameIds: [String] = consumeStringArray("Geonames", from: &remainingData)
        let countryNames: [String] = consumeStringArray("CountryNames", from: &remainingData)

        return IP2CountryCache(
            countryBlocksIPInt: countryBlockIpInts,
            countryBlocksGeonameId: countryBlocksGeonameIds,
            countryLocationsLocaleCode: countryLocaleCodes,
            countryLocationsGeonameId: countryGeonameIds,
            countryLocationsCountryName: countryNames
        )
    }()
    
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        /// Ensure the lookup tables get loaded in the background
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = self?.cache
            
            /// Then register for path change callbacks which will be used to update the country name cache
            self?.registerNetworkObservables(using: dependencies)
        }
    }
    
    // MARK: - Functions
    
    private func registerNetworkObservables(using dependencies: Dependencies) {
        /// Register for path change callbacks which will be used to update the country name cache
        dependencies[cache: .libSessionNetwork].paths
            .subscribe(on: DispatchQueue.global(qos: .utility), using: dependencies)
            .receive(on: DispatchQueue.global(qos: .utility), using: dependencies)
            .sink(
                receiveCompletion: { [weak self] _ in
                    /// If the stream completes it means the network cache was reset in which case we want to
                    /// re-register for updates in the next run loop (as the new cache should be created by then)
                    DispatchQueue.global(qos: .background).async {
                        self?.registerNetworkObservables(using: dependencies)
                    }
                },
                receiveValue: { [weak self] paths in
                    dependencies.mutate(cache: .ip2Country) { _ in
                        self?.populateCacheIfNeeded(paths: paths)
                    }
                }
            )
            .store(in: &disposables)
    }

    private func populateCacheIfNeeded(paths: [[LibSession.Snode]]) {
        guard !paths.isEmpty else { return }
        
        paths.forEach { path in
            path.forEach { snode in
                self.cacheCountry(for: snode.ip, inCache: &countryNamesCache)
            }
        }
        
        self._cacheLoaded.send(true)
        Log.info(.ip2Country, "Update onion request path countries.")
    }
    
    private func cacheCountry(for ip: String, inCache nameCache: inout [String: String]) {
        let currentLocale: String = self.currentLocale  // Store local copy for efficiency
        
        guard nameCache["\(ip)-\(currentLocale)"] == nil else { return }
        
        guard
            let ipAsInt: Int64 = IPv4.toInt(ip),
            let countryBlockGeonameIdIndex: Int = cache.countryBlocksIPInt.firstIndex(where: { $0 > ipAsInt }).map({ $0 - 1 }),
            let localeStartIndex: Int = cache.countryLocationsLocaleCode.firstIndex(where: { $0 == currentLocale }),
            let countryNameIndex: Int = Array(cache.countryLocationsGeonameId[localeStartIndex...]).firstIndex(where: { geonameId in
                geonameId == cache.countryBlocksGeonameId[countryBlockGeonameIdIndex]
            }),
            (localeStartIndex + countryNameIndex) < cache.countryLocationsCountryName.count
        else { return }
        
        let result: String = cache.countryLocationsCountryName[localeStartIndex + countryNameIndex]
        nameCache["\(ip)-\(currentLocale)"] = result
    }
    
    // MARK: - Functions
    
    public func country(for ip: String) -> String {
        guard _cacheLoaded.value else { return "resolving".localized() }
        
        return (countryNamesCache["\(ip)-\(currentLocale)"] ?? "onionRoutingPathUnknownCountry".localized())
    }
}

// MARK: - IP2CountryCacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
public protocol IP2CountryImmutableCacheType: ImmutableCacheType {
    var cacheLoaded: AnyPublisher<Bool, Never> { get }
    
    func country(for ip: String) -> String
}

public protocol IP2CountryCacheType: IP2CountryImmutableCacheType, MutableCacheType {
    var cacheLoaded: AnyPublisher<Bool, Never> { get }
    
    func country(for ip: String) -> String
}
