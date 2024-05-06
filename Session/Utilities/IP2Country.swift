import Foundation
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

final class IP2Country: Hashable {
    static var isInitialized: Bool = false
    static let shared: IP2Country = IP2Country()
    
    private let instanceIdentifier: UUID = UUID()
    private let dependencies: Dependencies
    public var countryNamesCache: Atomic<[String: String]> = Atomic([:])
    
    // MARK: - Tables
    /// This table has two columns: the "network" column and the "registered_country_geoname_id" column. The network column contains
    /// the **lower** bound of an IP range and the "registered_country_geoname_id" column contains the ID of the country corresponding
    /// to that range. We look up an IP by finding the first index in the network column where the value is greater than the IP we're looking
    /// up (converted to an integer). The IP we're looking up must then be in the range **before** that range.
    private lazy var ipv4Table: [String: [Int]] = {
        let url = Bundle.main.url(
            forResource: "GeoLite2-Country-Blocks-IPv4",        // stringlint:disable
            withExtension: nil
        )!
        let data = try! Data(contentsOf: url)
        return try! NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as! [String: [Int]]
    }()
    
    private lazy var countryNamesTable: [String: [String]] = {
        let url = Bundle.main.url(
            forResource: "GeoLite2-Country-Locations-English",  // stringlint:disable
            withExtension: nil
        )!
        let data = try! Data(contentsOf: url)
        return try! NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as! [String: [String]]
    }()

    // MARK: - Initialization

    private init(using dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
        
        dependencies.addFeatureObserver(self, for: .networkLayers, events: [.pathsBuilt]) { [weak self] _, _ in
            self?.populateCacheIfNeededAsync()
        }
    }

    deinit {
        dependencies.removeFeatureObserver(self)
    }
    
    // MARK: - Implementation
    
    @discardableResult private func cacheCountry(for ip: String, inCache cache: inout [String: String]) -> String {
        if let result: String = cache[ip] { return result }
        
        let ipAsInt: Int = IPv4.toInt(ip)
        
        guard
            let ipv4TableIndex: Int = ipv4Table["network"]?                                     // stringlint:disable
                .firstIndex(where: { $0 > ipAsInt })
                .map({ $0 - 1 }),
            let countryID: Int = ipv4Table["registered_country_geoname_id"]?[ipv4TableIndex],   // stringlint:disable
            let countryNamesTableIndex = countryNamesTable["geoname_id"]?                       // stringlint:disable
                .firstIndex(of: String(countryID)),
            let result: String = countryNamesTable["country_name"]?[countryNamesTableIndex]     // stringlint:disable
        else {
            return "Unknown Country" // Relies on the array being sorted
        }
        
        cache[ip] = result
        return result
    }

    @objc func populateCacheIfNeededAsync() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.populateCacheIfNeeded()
        }
    }

    @discardableResult func populateCacheIfNeeded(using dependencies: Dependencies = Dependencies()) -> Bool {
        guard let pathToDisplay: [Snode] = dependencies[cache: .onionRequestAPI].paths.first else { return false }
        
        countryNamesCache.mutate { [weak self] cache in
            pathToDisplay.forEach { snode in
                self?.cacheCountry(for: snode.ip, inCache: &cache) // Preload if needed
            }
        }
        
        DispatchQueue.main.async {
            IP2Country.isInitialized = true
            dependencies.notifyObservers(for: .networkLayers, with: .onionRequestPathCountriesLoaded)
        }
        SNLog("Finished preloading onion request path countries.")
        return true
    }
    
    // MARK: - Conformance
    
    static func == (lhs: IP2Country, rhs: IP2Country) -> Bool {
        return (lhs.instanceIdentifier == rhs.instanceIdentifier)
    }
    
    func hash(into hasher: inout Hasher) {
        instanceIdentifier.hash(into: &hasher)
    }
}
