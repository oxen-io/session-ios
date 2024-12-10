// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import UIKit
import SessionUtilitiesKit

extension Emoji {
    private static let availableCache: Atomic<[Emoji:Bool]> = Atomic([:])
    private static let iosVersionKey = "iosVersion"
    private static let cacheUrl = URL(fileURLWithPath: SessionFileManager.nonInjectedAppSharedDataDirectoryPath)
        .appendingPathComponent("Library")
        .appendingPathComponent("Caches")
        .appendingPathComponent("emoji.plist")

    static func warmAvailableCache(using dependencies: Dependencies) {
        Log.assertOnMainThread()

        guard dependencies[singleton: .appContext].isMainAppAndActive else { return }

        var availableCache = [Emoji: Bool]()
        var uncachedEmoji = [Emoji]()

        let iosVersion = UIDevice.current.systemVersion

        // Use an NSMutableDictionary for built-in plist serialization and heterogeneous values.
        var availableMap = NSMutableDictionary()
        do {
            availableMap = try NSMutableDictionary(contentsOf: Self.cacheUrl, error: ())
        } catch {
            Log.info("[Emoji] Re-building emoji availability cache. Cache could not be loaded. \(error)")
            uncachedEmoji = Emoji.allCases
        }

        let lastIosVersion = availableMap[iosVersionKey] as? String
        if lastIosVersion == iosVersion {
            Log.debug("[Emoji] Loading emoji availability cache (expect \(Emoji.allCases.count) items, found \(availableMap.count - 1)).")
            for emoji in Emoji.allCases {
                if let available = availableMap[emoji.rawValue] as? Bool {
                    availableCache[emoji] = available
                } else {
                    Log.warn("[Emoji] Emoji unexpectedly missing from cache: \(emoji).")
                    uncachedEmoji.append(emoji)
                }
            }
        } else if uncachedEmoji.isEmpty {
            Log.info("[Emoji] Re-building emoji availability cache. iOS version upgraded from \(lastIosVersion ?? "(none)") -> \(iosVersion)")
            uncachedEmoji = Emoji.allCases
        }

        if !uncachedEmoji.isEmpty {
            Log.info("[Emoji] Checking emoji availability for \(uncachedEmoji.count) uncached emoji")
            uncachedEmoji.forEach {
                let available = isEmojiAvailable($0)
                availableMap[$0.rawValue] = available
                availableCache[$0] = available
            }

            availableMap[iosVersionKey] = iosVersion
            do {
                // Use FileManager.createDirectory directly because FileSystem.ensureDirectoryExists
                // can modify the protection, and this is a system-managed directory.
                try dependencies[singleton: .fileManager].createDirectory(
                    at: Self.cacheUrl.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try availableMap.write(to: Self.cacheUrl)
            } catch {
                Log.warn("[Emoji] Failed to save emoji availability cache; it will be recomputed next time! \(error)")
            }
        }

        Log.info("[Emoji] Warmed emoji availability cache with \(availableCache.lazy.filter { $0.value }.count) available emoji for iOS \(iosVersion)")

        Self.availableCache.mutate{ $0 = availableCache }
    }

    private static func isEmojiAvailable(_ emoji: Emoji) -> Bool {
        return emoji.rawValue.isUnicodeStringAvailable
    }

    /// Indicates whether the given emoji is available on this iOS
    /// version. We cache the availability in memory.
    var available: Bool {
        guard let available = Self.availableCache.wrappedValue[self] else {
            let available = Self.isEmojiAvailable(self)
            Self.availableCache.mutate{ $0[self] = available }
            return available
        }
        return available
    }
}

private extension String {
    /// A known undefined unicode character for comparison
    private static let unknownUnicodeStringPng = "\u{1fff}".unicodeStringPngRepresentation

    // Based on https://stackoverflow.com/a/41393387
    // Check if an emoji is available on the current iOS version
    // by verifying its image is different than the "unknown"
    // reference image
    var isUnicodeStringAvailable: Bool {
        guard self.isSingleEmoji else { return false }
        return String.unknownUnicodeStringPng != unicodeStringPngRepresentation
    }

    var unicodeStringPngRepresentation: Data? {
        let attributes = [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 8)]
        let size = (self as NSString).size(withAttributes: attributes)

        UIGraphicsBeginImageContext(size)
        defer { UIGraphicsEndImageContext() }
        (self as NSString).draw(at: CGPoint(x: 0, y: 0), withAttributes: attributes)

        guard let unicodeImage = UIGraphicsGetImageFromCurrentImageContext() else { return nil }
        return unicodeImage.pngData()
    }
}
