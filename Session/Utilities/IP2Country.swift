// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

public enum IP2Country {
    public static var isInitialized: Atomic<Bool> = Atomic(false)
    public static var countryNamesCache: Atomic<[String: String]> = Atomic([:])
    private static var cacheLoadedCallbacks: Atomic<[UUID: () -> ()]> = Atomic([:])
    private static var pathsChangedCallbackId: Atomic<UUID?> = Atomic(nil)
    
    // MARK: - Tables
    /// This table has two columns: the "network" column and the "registered_country_geoname_id" column. The network column contains
    /// the **lower** bound of an IP range and the "registered_country_geoname_id" column contains the ID of the country corresponding
    /// to that range. We look up an IP by finding the first index in the network column where the value is greater than the IP we're looking
    /// up (converted to an integer). The IP we're looking up must then be in the range **before** that range.
    private static var ipv4Table: [String: [Int]] = {
        let url = Bundle.main.url(forResource: "GeoLite2-Country-Blocks-IPv4", withExtension: nil)!
        let data = try! Data(contentsOf: url)
        return try! NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as! [String: [Int]]
    }()
    
    private static var countryNamesTable: [String: [String]] = {
        let url = Bundle.main.url(forResource: "GeoLite2-Country-Locations-English", withExtension: nil)!
        let data = try! Data(contentsOf: url)
        return try! NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as! [String: [String]]
    }()
    
    // MARK: - Implementation
    
    static func onCacheLoaded(callback: @escaping () -> ()) -> UUID {
        let id: UUID = UUID()
        cacheLoadedCallbacks.mutate { $0[id] = callback }
        return id
    }
    
    static func removeCacheLoadedCallback(id: UUID?) {
        guard let id: UUID = id else { return }
        
        cacheLoadedCallbacks.mutate { $0.removeValue(forKey: id) }
    }

    static func populateCacheIfNeededAsync() {
        DispatchQueue.global(qos: .utility).async {
            pathsChangedCallbackId.mutate { pathsChangedCallbackId in
                guard pathsChangedCallbackId == nil else { return }
                
                pathsChangedCallbackId = LibSession.onPathsChanged(callback: { paths, _ in
                    self.populateCacheIfNeeded(paths: paths)
                })
            }
        }
    }

    private static func populateCacheIfNeeded(paths: [[LibSession.Snode]]) {
        guard !paths.isEmpty else { return }
        
        countryNamesCache.mutate { cache in
            paths.forEach { path in
                path.forEach { snode in
                    self.cacheCountry(for: snode.ip, inCache: &cache)
                }
            }
        }
        
        isInitialized.mutate { $0 = true }
        SNLog("Updated onion request path countries.")
    }
    
    private static func cacheCountry(for ip: String, inCache cache: inout [String: String]) {
        guard
            cache[ip] == nil,
            let ipAsInt: Int = IPv4.toInt(ip)
        else { return }
        
        guard
            let ipv4TableIndex = ipv4Table["network"]?.firstIndex(where: { $0 > ipAsInt }).map({ $0 - 1 }), // stringlint:disable
            let countryID: Int = ipv4Table["registered_country_geoname_id"]?[ipv4TableIndex], // stringlint:disable
            let countryNamesTableIndex = countryNamesTable["geoname_id"]?.firstIndex(of: String(countryID)), // stringlint:disable
            let result: String = countryNamesTable["country_name"]?[countryNamesTableIndex] // stringlint:disable
        else {
            cache[ip] = "onionRoutingPathUnknownCountry".localized() // Relies on the array being sorted
            return
        }
        
        cache[ip] = result
    }
}
