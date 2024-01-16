#!/usr/bin/env xcrun --sdk macosx swift

// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// This script is used to generate/update the set of Emoji used for reactions
//
// stringlint:disable

import Foundation

// OWSAssertionError but for this script

enum EmojiError: Error {
    case assertion(String)
    init(_ string: String) {
        self = .assertion(string)
    }
}

// MARK: - Remote Model
// These definitions are kept fairly lightweight since we don't control their format
// All processing of remote data is done by converting RemoteModel items to EmojiModel items

enum RemoteModel {
    struct EmojiItem: Codable {
        let name: String
        let shortName: String
        let unified: String
        let sortOrder: UInt
        let category: EmojiCategory
        let skinVariations: [String: SkinVariation]?
        let shortNames: [String]?
    }

    struct SkinVariation: Codable {
        let unified: String
    }

    enum EmojiCategory: String, Codable, Equatable {
        case smileys = "Smileys & Emotion"
        case people = "People & Body"

        // This category is not provided in the data set, but is actually
        // a merger of the categories of `smileys` and `people`
        case smileysAndPeople = "Smileys & People"

        case animals = "Animals & Nature"
        case food = "Food & Drink"
        case activities = "Activities"
        case travel = "Travel & Places"
        case objects = "Objects"
        case symbols = "Symbols"
        case flags = "Flags"
        case components = "Component"
    }

    static func fetchEmojiData() throws -> Data {
        // let remoteSourceUrl = URL(string: "https://unicodey.com/emoji-data/emoji.json")!
        // This URL has been unavailable the past couple of weeks. If you're seeing failures here, try this other one:
        let remoteSourceUrl = URL(string: "https://raw.githubusercontent.com/iamcal/emoji-data/master/emoji.json")!
        return try Data(contentsOf: remoteSourceUrl)
    }
}

// MARK: - Local Model

struct EmojiModel {
    let definitions: [EmojiDefinition]

    struct EmojiDefinition {
        let category: RemoteModel.EmojiCategory
        let rawName: String
        let enumName: String
        var shortNames: Set<String>
        let variants: [Emoji]
        var baseEmoji: Character { variants[0].base }

        struct Emoji: Comparable {
            let emojiChar: Character

            let base: Character
            let skintoneSequence: SkinToneSequence

            static func <(lhs: Self, rhs: Self) -> Bool {
                for (leftElement, rightElement) in zip(lhs.skintoneSequence, rhs.skintoneSequence) {
                    if leftElement.sortId != rightElement.sortId {
                        return leftElement.sortId < rightElement.sortId
                    }
                }
                if lhs.skintoneSequence.count != rhs.skintoneSequence.count {
                    return lhs.skintoneSequence.count < rhs.skintoneSequence.count
                } else {
                    return false
                }
            }
        }

        init(parsingRemoteItem remoteItem: RemoteModel.EmojiItem) throws {
            category = remoteItem.category
            rawName = remoteItem.name
            enumName = Self.parseEnumNameFromRemoteItem(remoteItem)
            shortNames = Set((remoteItem.shortNames ?? []))
            shortNames.insert(rawName.lowercased())
            shortNames.insert(enumName.lowercased())
            
            let baseEmojiChar = try Self.codePointsToCharacter(Self.parseCodePointString(remoteItem.unified))
            let baseEmoji = Emoji(emojiChar: baseEmojiChar, base: baseEmojiChar, skintoneSequence: .none)

            let toneVariants: [Emoji]
            if let skinVariations = remoteItem.skinVariations {
                toneVariants = try skinVariations.map { key, value in
                    let modifier = SkinTone.sequence(from: Self.parseCodePointString(key))
                    let parsedEmoji = try Self.codePointsToCharacter(Self.parseCodePointString(value.unified))
                    return Emoji(emojiChar: parsedEmoji, base: baseEmojiChar, skintoneSequence: modifier)
                }.sorted()
            } else {
                toneVariants = []
            }

            variants = [baseEmoji] + toneVariants
            try postInitValidation()
        }

        func postInitValidation() throws {
            guard variants.count > 0 else {
                throw EmojiError("Expecting at least one variant")
            }

            guard variants.allSatisfy({ $0.base == baseEmoji }) else {
                // All emoji variants must have a common base emoji
                throw EmojiError("Inconsistent base emoji: \(baseEmoji)")
            }

            let hasMultipleComponents = variants.first(where: { $0.skintoneSequence.count > 1 }) != nil
            if hasMultipleComponents, skinToneComponents == nil {
                // If you hit this, this means a new emoji was added where a skintone modifier sequence specifies multiple
                // skin tones for multiple emoji components: e.g. 👫 -> 🧍‍♀️+🧍‍♂️
                // These are defined in `skinToneComponents`. You'll need to add a new case.
                throw EmojiError("\(baseEmoji):\(enumName) definition has variants with multiple skintone modifiers but no component emojis defined")
            }
        }

        static func parseEnumNameFromRemoteItem(_ item: RemoteModel.EmojiItem) -> String {
            // some names don't play nice with swift, so we special case them
            switch item.shortName {
            case "+1": return "plusOne"
            case "-1": return "negativeOne"
            case "8ball": return "eightBall"
            case "repeat": return "`repeat`"
            case "100": return "oneHundred"
            case "1234": return "oneTwoThreeFour"
            case "couplekiss": return "personKissPerson"
            case "couple_with_heart": return "personHeartPerson"
            default:
                let uppperCamelCase = item.shortName
                    .replacingOccurrences(of: "-", with: " ")
                    .replacingOccurrences(of: "_", with: " ")
                    .titlecase
                    .replacingOccurrences(of: " ", with: "")

                return uppperCamelCase.first!.lowercased() + uppperCamelCase.dropFirst()
            }
        }

        var skinToneComponents: String? {
            // There's no great way to do this except manually. Some emoji have multiple skin tones.
            // In the picker, we need to use one emoji to represent each person. For now, we manually
            // specify this. Hopefully, in the future, the data set will contain this information.
            switch enumName {
            case "peopleHoldingHands": return "[.standingPerson, .standingPerson]"
            case "twoWomenHoldingHands": return "[.womanStanding, .womanStanding]"
            case "manAndWomanHoldingHands": return "[.womanStanding, .manStanding]"
            case "twoMenHoldingHands": return "[.manStanding, .manStanding]"
            case "personKissPerson": return "[.adult, .adult]"
            case "womanKissMan": return "[.woman, .man]"
            case "manKissMan": return "[.man, .man]"
            case "womanKissWoman": return "[.woman, .woman]"
            case "personHeartPerson": return "[.adult, .adult]"
            case "womanHeartMan": return "[.woman, .man]"
            case "manHeartMan": return "[.man, .man]"
            case "womanHeartWoman": return "[.woman, .woman]"
            case "handshake": return "[.rightwardsHand, .leftwardsHand]"
            default:
                return nil
            }
        }

        var isNormalized: Bool { enumName == normalizedEnumName }
        var normalizedEnumName: String {
            switch enumName {
            // flagUm (US Minor Outlying Islands) looks identical to the
            // US flag. We don't present it as a sendable reaction option
            // This matches the iOS keyboard behavior.
            case "flagUm": return "us"
            default: return enumName
            }
        }

        static func parseCodePointString(_ pointString: String) -> [UnicodeScalar] {
            return pointString
                .components(separatedBy: "-")
                .map { Int($0, radix: 16)! }
                .map { UnicodeScalar($0)! }
        }

        static func codePointsToCharacter(_ codepoints: [UnicodeScalar]) throws -> Character {
            let result = codepoints.map { String($0) }.joined()
            if result.count != 1 {
                throw EmojiError("Invalid number of chars for codepoint sequence: \(codepoints)")
            }
            return result.first!
        }
    }

    init(rawJSONData jsonData: Data) throws {
        let jsonDecoder = JSONDecoder()
        jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase

        definitions = try jsonDecoder
            .decode([RemoteModel.EmojiItem].self, from: jsonData)
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { try EmojiDefinition(parsingRemoteItem: $0) }

    }

    typealias SkinToneSequence = [EmojiModel.SkinTone]
    enum SkinTone: UnicodeScalar, CaseIterable, Equatable {
        case light = "🏻"
        case mediumLight = "🏼"
        case medium = "🏽"
        case mediumDark = "🏾"
        case dark = "🏿"

        var sortId: Int { return SkinTone.allCases.firstIndex(of: self)! }

        static func sequence(from codepoints: [UnicodeScalar]) -> SkinToneSequence {
            codepoints
                .map { SkinTone(rawValue: $0)! }
                .reduce(into: [SkinTone]()) { result, skinTone in
                    guard !result.contains(skinTone) else { return }
                    result.append(skinTone)
                }
        }
    }
}

extension EmojiModel.SkinToneSequence {
    static var none: EmojiModel.SkinToneSequence = []
}

// MARK: - File Writers

extension EmojiGenerator {
    static func writePrimaryFile(from emojiModel: EmojiModel) {
        // Main enum: Create a string enum defining our enumNames equal to the baseEmoji string
        // e.g. case grinning = "😀"
        writeBlock(fileName: "Emoji.swift") { fileHandle in
            fileHandle.writeLine("")
            fileHandle.writeLine("/// A sorted representation of all available emoji")
            fileHandle.writeLine("enum Emoji: String, CaseIterable, Equatable {")
            fileHandle.indent {
                emojiModel.definitions.forEach {
                    fileHandle.writeLine("case \($0.enumName) = \"\($0.baseEmoji)\"")
                }
            }
            fileHandle.writeLine("}")
        }
    }

    indirect enum Structure {
        enum ChunkType {
            case firstScalar
            case scalarSum
            
            func chunk(_ character: Character, into size: UInt32) -> UInt32 {
                guard size > 0 else { return 0 }
                
                let scalarValues: [UInt32] = character.unicodeScalars.map { $0.value }
                
                switch self {
                    case .firstScalar: return (scalarValues.first.map { $0 / size } ?? 0)
                    case .scalarSum: return (scalarValues.reduce(0, +) / size)
                }
            }
            
            func switchString(with variableName: String = "rawValue", size: UInt32) -> String {
                switch self {
                    case .firstScalar: return "rawValue.unicodeScalars.map({ $0.value }).first.map({ $0 / \(size) })"
                    case .scalarSum: return "(rawValue.unicodeScalars.map({ $0.value }).reduce(0, +) / \(size))"
                }
            }
        }
        
        case ifElse                                 // XCode 15 taking over 10 min with M1 Pro (gave up)
        case switchStatement                        // XCode 15 taking over 10 min with M1 Pro (gave up)
        case directLookup                           // XCode 15 taking 93 sec with M1 Pro
        case chunked(UInt32, Structure, ChunkType)  // XCode 15 taking <10 sec with M1 Pro (chunk by 100)
    }
    typealias ChunkedEmojiInfo = (
        variant: EmojiModel.EmojiDefinition.Emoji,
        baseName: String
    )
    
    static func writeStringConversionsFile(from emojiModel: EmojiModel) {
        // This combination seems to have the smallest compile time (~2.2 sec out of all of the combinations)
        let desiredStructure: Structure = .chunked(100, .directLookup, .scalarSum)

        // Conversion from String: Creates an initializer mapping a single character emoji string to an EmojiWithSkinTones
        // e.g.
        // if rawValue == "😀" { self.init(baseEmoji: .grinning, skinTones: nil) }
        // else if rawValue == "🦻🏻" { self.init(baseEmoji: .earWithHearingAid, skinTones: [.light])
        writeBlock(fileName: "EmojiWithSkinTones+String.swift") { fileHandle in
            fileHandle.writeLine("")
            fileHandle.writeLine("extension EmojiWithSkinTones {")
            fileHandle.indent {
                switch desiredStructure {
                    case .chunked(let chunkSize, let childStructure, let chunkType):
                        let chunkedEmojiInfo = emojiModel.definitions
                            .reduce(into: [UInt32: [ChunkedEmojiInfo]]()) { result, next in
                                next.variants.forEach { emoji in
                                    let chunk: UInt32 = chunkType.chunk(emoji.emojiChar, into: chunkSize)
                                    result[chunk] = ((result[chunk] ?? []) + [(emoji, next.enumName)])
                                        .sorted { lhs, rhs in lhs.variant < rhs.variant }
                                }
                            }
                            .sorted { lhs, rhs in lhs.key < rhs.key } 
                        
                        fileHandle.writeLine("init?(rawValue: String) {")
                        fileHandle.indent {
                            fileHandle.writeLine("guard rawValue.isSingleEmoji else { return nil }")
                            fileHandle.writeLine("switch \(chunkType.switchString(size: chunkSize)) {")
                            fileHandle.indent {
                                chunkedEmojiInfo.forEach { chunk, _ in
                                    fileHandle.writeLine("case \(chunk): self = EmojiWithSkinTones.emojiFrom\(chunk)(rawValue)")
                                }
                                fileHandle.writeLine("default: self = EmojiWithSkinTones(unsupportedValue: rawValue)")
                            }
                            fileHandle.writeLine("}")
                        }
                        fileHandle.writeLine("}")
                        
                        chunkedEmojiInfo.forEach { chunk, emojiInfo in
                            fileHandle.writeLine("")
                            fileHandle.writeLine("private static func emojiFrom\(chunk)(_ rawValue: String) -> EmojiWithSkinTones {")
                            fileHandle.indent {
                                switch emojiInfo.count {
                                    case 0:
                                        fileHandle.writeLine("return EmojiWithSkinTones(unsupportedValue: rawValue)")
                                        
                                    default:
                                        writeStructure(
                                            childStructure,
                                            for: emojiInfo,
                                            using: fileHandle,
                                            assignmentPrefix: "return "
                                        )
                                }
                            }
                            
                            fileHandle.writeLine("}")
                        }
                        
                    default:
                        fileHandle.writeLine("init?(rawValue: String) {")
                        fileHandle.indent {
                            fileHandle.writeLine("guard rawValue.isSingleEmoji else { return nil }")
                            writeStructure(
                                desiredStructure,
                                for: emojiModel.definitions
                                    .flatMap { definition in
                                        definition.variants.map { ($0, definition.enumName) }
                                    },
                                using: fileHandle
                            )
                        }
                        fileHandle.writeLine("}")
                }
            }
            fileHandle.writeLine("}")
        }
    }
    
    private static func writeStructure(
        _ structure: Structure,
        for emojiInfo: [ChunkedEmojiInfo],
        using fileHandle: WriteHandle,
        assignmentPrefix: String = "self = "
    ) {
        func initItem(_ info: ChunkedEmojiInfo) -> String {
            let skinToneString: String = {
                guard !info.variant.skintoneSequence.isEmpty else { return "nil" }
                return "[\(info.variant.skintoneSequence.map { ".\($0)" }.joined(separator: ", "))]"
            }()
            
            return "EmojiWithSkinTones(baseEmoji: .\(info.baseName), skinTones: \(skinToneString))"
        }

        switch structure {
            case .ifElse:
                emojiInfo.enumerated().forEach { index, info in
                    switch index {
                        case 0: fileHandle.writeLine("if rawValue == \"\(info.variant.emojiChar)\" {")
                        default: fileHandle.writeLine("} else if rawValue == \"\(info.variant.emojiChar)\" {")
                    }
                    
                    fileHandle.indent {
                        fileHandle.writeLine("\(assignmentPrefix)\(initItem(info))")
                    }
                }
                
                fileHandle.writeLine("} else {")
                fileHandle.indent {
                    fileHandle.writeLine("\(assignmentPrefix)EmojiWithSkinTones(unsupportedValue: rawValue)")
                }
                fileHandle.writeLine("}")
                
            case .switchStatement:
                fileHandle.writeLine("switch rawValue {")
                fileHandle.indent {
                    emojiInfo.forEach { info in
                        fileHandle.writeLine("case \"\(info.variant.emojiChar)\": \(assignmentPrefix)\(initItem(info))")
                    }
                    fileHandle.writeLine("default: \(assignmentPrefix)EmojiWithSkinTones(unsupportedValue: rawValue)")
                }
                fileHandle.writeLine("}")
                
            case .directLookup:
                fileHandle.writeLine("let lookup: [String: EmojiWithSkinTones] = [")
                fileHandle.indent {
                    emojiInfo.enumerated().forEach { index, info in
                        let isLast: Bool = (index == (emojiInfo.count - 1))
                        fileHandle.writeLine("\"\(info.variant.emojiChar)\": \(initItem(info))\(isLast ? "" : ",")")
                    }
                }
                fileHandle.writeLine("]")
                fileHandle.writeLine("\(assignmentPrefix)(lookup[rawValue] ?? EmojiWithSkinTones(unsupportedValue: rawValue))")
                
            case .chunked: break // Provide one of the other types
        }
    }

    static func writeSkinToneLookupFile(from emojiModel: EmojiModel) {
        writeBlock(fileName: "Emoji+SkinTones.swift") { fileHandle in
            fileHandle.writeLine("")
            fileHandle.writeLine("extension Emoji {")
            fileHandle.indent {
                // SkinTone enum
                fileHandle.writeLine("enum SkinTone: String, CaseIterable, Equatable {")
                fileHandle.indent {
                    for skinTone in EmojiModel.SkinTone.allCases {
                        fileHandle.writeLine("case \(skinTone) = \"\(skinTone.rawValue)\"")
                    }
                }
                fileHandle.writeLine("}")
                fileHandle.writeLine("")

                // skin tone helpers
                fileHandle.writeLine("var hasSkinTones: Bool { return emojiPerSkinTonePermutation != nil }")
                fileHandle.writeLine("var allowsMultipleSkinTones: Bool { return hasSkinTones && skinToneComponentEmoji != nil }")
                fileHandle.writeLine("")

                // Start skinToneComponentEmoji
                fileHandle.writeLine("var skinToneComponentEmoji: [Emoji]? {")
                fileHandle.indent {
                    fileHandle.writeLine("switch self {")
                    emojiModel.definitions.forEach { emojiDef in
                        if let components = emojiDef.skinToneComponents {
                            fileHandle.writeLine("case .\(emojiDef.enumName): return \(components)")
                        }
                    }

                    fileHandle.writeLine("default: return nil")
                    fileHandle.writeLine("}")
                }
                fileHandle.writeLine("}")
                fileHandle.writeLine("")

                // Start emojiPerSkinTonePermutation
                fileHandle.writeLine("var emojiPerSkinTonePermutation: [[SkinTone]: String]? {")
                fileHandle.indent {
                    fileHandle.writeLine("switch self {")
                    emojiModel.definitions.forEach { emojiDef in
                        let skintoneVariants = emojiDef.variants.filter({ $0.skintoneSequence != .none})
                        if skintoneVariants.isEmpty {
                            // None of our variants have a skintone, nothing to do
                            return
                        }

                        fileHandle.writeLine("case .\(emojiDef.enumName):")
                        fileHandle.indent {
                            fileHandle.writeLine("return [")
                            fileHandle.indent {
                                skintoneVariants.forEach {
                                    let skintoneSequenceKey = $0.skintoneSequence.map({ ".\($0)" }).joined(separator: ", ")
                                    fileHandle.writeLine("[\(skintoneSequenceKey)]: \"\($0.emojiChar)\",")
                                }
                            }
                            fileHandle.writeLine("]")
                        }
                    }
                    fileHandle.writeLine("default: return nil")
                    fileHandle.writeLine("}")
                }
                fileHandle.writeLine("}")
            }
            fileHandle.writeLine("}")
        }
    }

    static func writeCategoryLookupFile(from emojiModel: EmojiModel) {
        let outputCategories: [RemoteModel.EmojiCategory] = [
            .smileysAndPeople,
            .animals,
            .food,
            .activities,
            .travel,
            .objects,
            .symbols,
            .flags
        ]

        writeBlock(fileName: "Emoji+Category.swift") { fileHandle in
            fileHandle.writeLine("")
            fileHandle.writeLine("extension Emoji {")
            fileHandle.indent {

                // Category enum
                fileHandle.writeLine("enum Category: String, CaseIterable, Equatable {")
                fileHandle.indent {
                    // Declare cases
                    for category in outputCategories {
                        fileHandle.writeLine("case \(category) = \"\(category.rawValue)\"")
                    }
                    fileHandle.writeLine("")

                    // Localized name for category
                    fileHandle.writeLine("var localizedName: String {")
                    fileHandle.indent {
                        fileHandle.writeLine("switch self {")
                        for category in outputCategories {
                            fileHandle.writeLine("case .\(category):")
                            fileHandle.indent {
                                let stringKey = "EMOJI_CATEGORY_\("\(category)".uppercased())_NAME"
                                let stringComment = "The name for the emoji category '\(category.rawValue)'"

                                fileHandle.writeLine("return NSLocalizedString(\"\(stringKey)\", comment: \"\(stringComment)\")")
                            }
                        }
                        fileHandle.writeLine("}")
                    }
                    fileHandle.writeLine("}")
                    fileHandle.writeLine("")

                    // Emoji lookup per category
                    fileHandle.writeLine("var normalizedEmoji: [Emoji] {")
                    fileHandle.indent {
                        fileHandle.writeLine("switch self {")

                        let normalizedEmojiPerCategory: [RemoteModel.EmojiCategory: [EmojiModel.EmojiDefinition]]
                        normalizedEmojiPerCategory = emojiModel.definitions.reduce(into: [:]) { result, emojiDef in
                            if emojiDef.isNormalized {
                                var categoryList = result[emojiDef.category] ?? []
                                categoryList.append(emojiDef)
                                result[emojiDef.category] = categoryList
                            }
                        }

                        for category in outputCategories {
                            let emoji: [EmojiModel.EmojiDefinition] = {
                                switch category {
                                case .smileysAndPeople:
                                    // Merge smileys & people. It's important we initially bucket these separately,
                                    // because we want the emojis to be sorted smileys followed by people
                                    return normalizedEmojiPerCategory[.smileys]! + normalizedEmojiPerCategory[.people]!
                                default:
                                    return normalizedEmojiPerCategory[category]!
                                }
                            }()

                            fileHandle.writeLine("case .\(category):")
                            fileHandle.indent {
                                fileHandle.writeLine("return [")
                                fileHandle.indent {
                                    emoji.compactMap { $0.enumName }.forEach { name in
                                        fileHandle.writeLine(".\(name),")
                                    }
                                }
                                fileHandle.writeLine("]")
                            }
                        }
                        fileHandle.writeLine("}")
                    }
                    fileHandle.writeLine("}")
                }
                fileHandle.writeLine("}")
                fileHandle.writeLine("")

                // Category lookup per emoji
                fileHandle.writeLine("var category: Category {")
                fileHandle.indent {
                    fileHandle.writeLine("switch self {")
                    for emojiDef in emojiModel.definitions {
                        let category = [.smileys, .people].contains(emojiDef.category) ? .smileysAndPeople : emojiDef.category
                        if category != .components {
                            fileHandle.writeLine("case .\(emojiDef.enumName): return .\(category)")
                        }
                    }
                    // Write a default case, because this enum is too long for the compiler to validate it's exhaustive
                    fileHandle.writeLine("default: fatalError(\"Unexpected case \\(self)\")")
                    fileHandle.writeLine("}")
                }
                fileHandle.writeLine("}")
                fileHandle.writeLine("")

                // Normalized variant mapping
                fileHandle.writeLine("var isNormalized: Bool { normalized == self }")
                fileHandle.writeLine("var normalized: Emoji {")
                fileHandle.indent {
                    fileHandle.writeLine("switch self {")
                    emojiModel.definitions.filter { !$0.isNormalized }.forEach {
                        fileHandle.writeLine("case .\($0.enumName): return .\($0.normalizedEnumName)")
                    }
                    fileHandle.writeLine("default: return self")
                    fileHandle.writeLine("}")
                }
                fileHandle.writeLine("}")
            }
            fileHandle.writeLine("}")
        }
    }

    static func writeNameLookupFile(from emojiModel: EmojiModel) {
        // Name lookup: Create a computed property mapping an Emoji enum element to the raw Emoji name string
        // e.g. case .grinning: return "GRINNING FACE"
        writeBlock(fileName: "Emoji+Name.swift") { fileHandle in
            fileHandle.writeLine("")
            fileHandle.writeLine("extension Emoji {")
            fileHandle.indent {
                fileHandle.writeLine("var name: String {")
                fileHandle.indent {
                    fileHandle.writeLine("switch self {")
                    emojiModel.definitions.forEach {
                        fileHandle.writeLine("case .\($0.enumName): return \"\($0.shortNames.sorted().joined(separator:", "))\"")
                    }
                    fileHandle.writeLine("}")
                }
                fileHandle.writeLine("}")
            }
            fileHandle.writeLine("}")
            fileHandle.writeLine("// swiftlint:disable all")
        }
    }
}

// MARK: - File I/O Helpers

class WriteHandle {
    static let emojiDirectory = URL(
        fileURLWithPath: "../Session/Emoji",
        isDirectory: true,
        relativeTo: EmojiGenerator.pathToFolderContainingThisScript!)

    let handle: FileHandle

    var indentDepth: Int = 0
    var hasBeenClosed = false

    func indent(_ block: () -> Void) {
        indentDepth += 1
        block()
        indentDepth -= 1
    }

    func writeLine(_ body: String) {
        let spaces = indentDepth * 4
        let prefix = String(repeating: " ", count: spaces)
        let suffix = "\n"

        let line = prefix + body + suffix
        handle.write(line.data(using: .utf8)!)
    }

    init(fileName: String) {
        // Create directory if necessary
        if !FileManager.default.fileExists(atPath: Self.emojiDirectory.path) {
            try! FileManager.default.createDirectory(at: Self.emojiDirectory, withIntermediateDirectories: true, attributes: nil)
        }

        // Delete old file and create anew
        let url = URL(fileURLWithPath: fileName, relativeTo: Self.emojiDirectory)
        if FileManager.default.fileExists(atPath: url.path) {
            try! FileManager.default.removeItem(at: url)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        handle = try! FileHandle(forWritingTo: url)
    }

    deinit {
        precondition(hasBeenClosed, "File handle still open at de-init")
    }

    func close() {
        handle.closeFile()
        hasBeenClosed = true
    }
}

extension EmojiGenerator {
    static func writeBlock(fileName: String, block: (WriteHandle) -> Void) {
        let fileHandle = WriteHandle(fileName: fileName)
        defer { fileHandle.close() }

        fileHandle.writeLine("")
        fileHandle.writeLine("// This file is generated by EmojiGenerator.swift, do not manually edit it.")
        fileHandle.writeLine("// swiftlint:disable all")
        fileHandle.writeLine("// stringlint:disable")
        fileHandle.writeLine("")
        fileHandle.writeLine("import Foundation")
        fileHandle.writeLine("")

        block(fileHandle)
    }

    // from http://stackoverflow.com/a/31480534/255489
    static var pathToFolderContainingThisScript: URL? = {
        let cwd = FileManager.default.currentDirectoryPath

        let script = CommandLine.arguments[0]

        if script.hasPrefix("/") { // absolute
            let path = (script as NSString).deletingLastPathComponent
            return URL(fileURLWithPath: path)
        } else { // relative
            let urlCwd = URL(fileURLWithPath: cwd)

            if let urlPath = URL(string: script, relativeTo: urlCwd) {
                let path = (urlPath.path as NSString).deletingLastPathComponent
                return URL(fileURLWithPath: path)
            }
        }

        return nil
    }()
}

// MARK: - Misc

extension String {
    var titlecase: String {
        components(separatedBy: " ")
            .map { $0.first!.uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
}

// MARK: - Lifecycle

class EmojiGenerator {
    static func run() throws {
        let remoteData = try RemoteModel.fetchEmojiData()
        let model = try EmojiModel(rawJSONData: remoteData)

        writePrimaryFile(from: model)
        writeStringConversionsFile(from: model)
        writeSkinToneLookupFile(from: model)
        writeCategoryLookupFile(from: model)
        writeNameLookupFile(from: model)
    }
}

do {
    try EmojiGenerator.run()
} catch {
    print("Failed to generate emoji data: \(error)")
    let errorCode = (error as? CustomNSError)?.errorCode ?? -1
    exit(Int32(errorCode))
}
