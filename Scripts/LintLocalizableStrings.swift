#!/usr/bin/xcrun --sdk macosx swift

// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable
//
/// This script is based on https://github.com/ginowu7/CleanSwiftLocalizableExample
/// The main differences are:
/// 1. Changes to the localized usage regex
/// 2. Addition to excluded unlocalized cases
/// 3. Functionality to update and copy localized permission requirement strings to infoPlist.xcstrings

import Foundation

typealias JSON = [String:AnyHashable]

extension ProjectState {
    /// Adding `// stringlint:disable` to the top of a source file (before imports) or after a string will mean that file/line gets
    /// ignored by this script (good for some things like the auto-generated emoji strings or debug strings)
    static let lintSuppression: String = "stringlint:disable"
    static let primaryLocalisation: String = "en"
    static let permissionStrings: Set<String> = [
        "permissionsStorageSend",
        "permissionsFaceId",
        "cameraGrantAccessDescription",
        "permissionsAppleMusic",
        "permissionsStorageSave",
        "permissionsMicrophoneAccessRequiredIos"
    ]
    static let permissionStringsMap: [String: String] = [
        "permissionsStorageSend": "NSPhotoLibraryUsageDescription",
        "permissionsFaceId": "NSFaceIDUsageDescription",
        "cameraGrantAccessDescription": "NSCameraUsageDescription",
        "permissionsAppleMusic": "NSAppleMusicUsageDescription",
        "permissionsStorageSave": "NSPhotoLibraryAddUsageDescription",
        "permissionsMicrophoneAccessRequiredIos": "NSMicrophoneUsageDescription"
    ]
    static let validSourceSuffixes: Set<String> = [".swift", ".m"]
    static let excludedPaths: Set<String> = [
        "build/",                   // Files under the build folder (CI)
        "Pods/",                    // The pods folder
        "Protos/",                  // The protobuf files
        ".xcassets/",               // Asset bundles
        ".app/",                    // App build directories
        ".appex/",                  // Extension build directories
        "tests/",                   // Exclude test directories
        "_SharedTestUtilities/",    // Exclude shared test directory
        "external/"                 // External dependencies
    ]
    static let excludedPhrases: Set<String> = [ "", " ", "  ", ",", ", ", "null", "\"", "\"\\($0)\"", "@[0-9a-fA-F]{66}", "^[0-9A-Fa-f]+$", "/" ]
    static let excludedUnlocalizedStringLineMatching: Set<MatchType> = [
        .contains(ProjectState.lintSuppression, caseSensitive: false),
        .prefix("#import", caseSensitive: false),
        .prefix("@available(", caseSensitive: false),
        .contains("fatalError(", caseSensitive: false),
        .contains("precondition(", caseSensitive: false),
        .contains("preconditionFailure(", caseSensitive: false),
        .contains("print(", caseSensitive: false),
        .contains("SNLog(", caseSensitive: false),
        .contains("Log.setup(", caseSensitive: false),
        .containsAnd(
            "primaryPrefix:",
            caseSensitive: false,
            .previousLine(numEarlier: 1, .contains("Log.setup(with: Logger(", caseSensitive: false))
        ),
        .containsAnd(
            "customDirectory:",
            caseSensitive: false,
            .previousLine(numEarlier: 2, .contains("Log.setup(with: Logger(", caseSensitive: false))
        ),
        .contains("Log.verbose(", caseSensitive: false),
        .contains("Log.debug(", caseSensitive: false),
        .contains("Log.info(", caseSensitive: false),
        .contains("Log.warn(", caseSensitive: false),
        .contains("Log.error(", caseSensitive: false),
        .contains("Log.critical(", caseSensitive: false),
        .contains("Log.Category =", caseSensitive: false),
        .contains("logMessage:", caseSensitive: false),
        .contains(".logging(", caseSensitive: false),
        .contains("owsFailDebug(", caseSensitive: false),
        .contains("error: .other(", caseSensitive: false),
        .contains("#imageLiteral(resourceName:", caseSensitive: false),
        .contains("UIImage(named:", caseSensitive: false),
        .contains("UIImage(systemName:", caseSensitive: false),
        .contains("[UIImage imageNamed:", caseSensitive: false),
        .contains("Image(", caseSensitive: false),
        .contains("logo:", caseSensitive: false),
        .contains("UIFont(name:", caseSensitive: false),
        .contains(".dateFormat =", caseSensitive: false),
        .contains("accessibilityLabel =", caseSensitive: false),
        .contains("accessibilityValue =", caseSensitive: false),
        .contains("accessibilityIdentifier =", caseSensitive: false),
        .contains("accessibilityIdentifier:", caseSensitive: false),
        .contains("accessibilityLabel:", caseSensitive: false),
        .contains("Accessibility(identifier:", caseSensitive: false),
        .contains("Accessibility(label:", caseSensitive: false),
        .contains(".withAccessibility(identifier:", caseSensitive: false),
        .contains(".withAccessibility(label:", caseSensitive: false),
        .contains("NSAttributedString.Key(", caseSensitive: false),
        .contains("Notification.Name(", caseSensitive: false),
        .contains("Notification.Key(", caseSensitive: false),
        .contains("DispatchQueue(", caseSensitive: false),
        .containsAnd(
            "identifier:",
            caseSensitive: false,
            .previousLine(numEarlier: 1, .contains("Accessibility(", caseSensitive: false))
        ),
        .containsAnd(
            "label:",
            caseSensitive: false,
            .previousLine(numEarlier: 1, .contains("Accessibility(", caseSensitive: false))
        ),
        .containsAnd(
            "label:",
            caseSensitive: false,
            .previousLine(numEarlier: 2, .contains("Accessibility(", caseSensitive: false))
        ),
        .containsAnd(
            "identifier:",
            caseSensitive: false,
            .previousLine(numEarlier: 1, .contains(".withAccessibility(", caseSensitive: false))
        ),
        .containsAnd(
            "label:",
            caseSensitive: false,
            .previousLine(numEarlier: 1, .contains(".withAccessibility(", caseSensitive: false))
        ),
        .containsAnd(
            "label:",
            caseSensitive: false,
            .previousLine(numEarlier: 2, .contains(".withAccessibility(", caseSensitive: false))
        ),
        .contains("SQL(", caseSensitive: false),
        .contains(" == ", caseSensitive: false),
        .contains("forResource:", caseSensitive: false),
        .contains("imageName:", caseSensitive: false),
        .contains(".userInfo[", caseSensitive: false),
        .contains("payload[", caseSensitive: false),
        .contains(".infoDictionary?[", caseSensitive: false),
        .contains("accessibilityId:", caseSensitive: false),
        .contains("key:", caseSensitive: false),
        .contains("separator:", caseSensitive: false),
        .contains("separatedBy:", caseSensitive: false),
        .nextLine(.contains(".put(key:", caseSensitive: false)),
        .nextLine(
            .containsAnd(
                ".put(",
                caseSensitive: false,
                .nextLine(.contains("key:", caseSensitive: false))
            )
        ),
        .nextLine(.contains(".putNumber(", caseSensitive: false)),
        .nextLine(.contains(".localized()", caseSensitive: false)),
        .contains(".localizedString(for:", caseSensitive: false),
        .regex(".*static var databaseTableName: String"),
        .regex("case .* = "),
        .regex("Error.*\\("),
        .belowLineContaining("PreviewProvider"),
        .belowLineContaining("#Preview"),
        .regex("Crypto.*\\(id:"),
        .containsAnd("id:", caseSensitive: false, .previousLine(numEarlier: 1, .regex("Crypto.*\\("))),
        .regex(".*\\.like\\(\".*%\""),
        .containsAnd(
            "identifier:",
            caseSensitive: false,
            .previousLine(numEarlier: 1, .contains("Dependencies.create", caseSensitive: false))
        )
    ]
}

// Execute the desired actions
let targetActions: Set<ScriptAction> = {
    let args = CommandLine.arguments
    
    // The first argument is the file name
    guard args.count > 1 else { return [.lintStrings] }
    
    return Set(args.suffix(from: 1).map { (ScriptAction(rawValue: $0) ?? .lintStrings) })
}()

print("------------ Searching Through Files ------------")
let projectState: ProjectState = ProjectState(
    path: (
        ProcessInfo.processInfo.environment["PROJECT_DIR"] ??
        FileManager.default.currentDirectoryPath
    ),
    loadSourceFiles: targetActions.contains(.lintStrings)
)
print("------------ Processing \(projectState.localizationFile.path) ------------")
targetActions.forEach { $0.perform(projectState: projectState) }

// MARK: - ScriptAction

enum ScriptAction: String {
    case validateFilesCopied = "validate"
    case lintStrings = "lint"
    case updatePermissionStrings = "update"
    
    func perform(projectState: ProjectState) {
        // Perform the action
        switch self {
            case .validateFilesCopied:
                print("------------ Checking Copied Files ------------")
                guard
                    let builtProductsPath: String = ProcessInfo.processInfo.environment["BUILT_PRODUCTS_DIR"],
                    let productName: String = ProcessInfo.processInfo.environment["FULL_PRODUCT_NAME"],
                    let productPathInfo = try? URL(fileURLWithPath: "\(builtProductsPath)/\(productName)")
                        .resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey]),
                    let finalProductUrl: URL = try? { () -> URL in
                        let possibleAliasUrl: URL = URL(fileURLWithPath: "\(builtProductsPath)/\(productName)")
                        
                        guard productPathInfo.isSymbolicLink == true || productPathInfo.isAliasFile == true else {
                            return possibleAliasUrl
                        }
                        
                        return try URL(resolvingAliasFileAt: possibleAliasUrl, options: URL.BookmarkResolutionOptions())
                    }(),
                    let enumerator: FileManager.DirectoryEnumerator = FileManager.default.enumerator(
                        at: finalProductUrl,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    ),
                    let fileUrls: [URL] = enumerator.allObjects as? [URL]
                else { return Output.error("Could not retrieve list of files within built product") }
            
                let localizationFiles: Set<String> = Set(fileUrls
                    .filter { $0.path.hasSuffix(".lproj") }
                    .map { $0.lastPathComponent.replacingOccurrences(of: ".lproj", with: "") })
                let missingFiles: Set<String> = projectState.localizationFile.locales
                    .subtracting(localizationFiles)

                guard missingFiles.isEmpty else {
                    return Output.error("Translations missing from \(productName): \(missingFiles.joined(separator: ", "))")
                }
                break
                
            case .lintStrings:
                guard !projectState.localizationFile.strings.isEmpty else {
                    return print("------------ Nothing to lint ------------")
                }
                
                var allKeys: [String] = []
                var duplicates: [String] = []
                projectState.localizationFile.strings.forEach { key, value in
                    if allKeys.contains(key) {
                        duplicates.append(key)
                    } else {
                        allKeys.append(key)
                    }
                    
                    // Add warning for probably faulty translation
                    if let localizations: JSON = (value as? JSON)?["localizations"] as? JSON {
                        if let original: String = ((localizations["en"] as? JSON)?["stringUnit"] as? JSON)?["value"] as? String {
                            localizations.forEach { locale, translation in
                                if let phrase: String = ((translation as? JSON)?["stringUnit"] as? JSON)?["value"] as? String {
                                    let numberOfVarablesOrignal = Regex.matches("\\{.*\\}", content: original).count
                                    let numberOfVarablesPhrase = Regex.matches("\\{.*\\}", content: phrase).count
                                    if numberOfVarablesPhrase != numberOfVarablesOrignal {
                                        Output.warning("\(key) in \(locale) may be faulty")
                                    }
                                }
                            }
                        }
                    }
                }
            
                // Add warnings for any duplicate keys
                duplicates.forEach { Output.duplicate(key: $0) }

                // Process the source code
                print("------------ Processing \(projectState.sourceFiles.count) Source File(s) ------------")
  
                projectState.sourceFiles.forEach { file in
                    // Add logs for unlocalized strings
                    file.unlocalizedPhrases.forEach { phrase in
                        Output.warning(phrase, "Found unlocalized string '\(phrase.key)'")
                    }
                    
                    // Add errors for missing localized strings
                    let missingKeys: Set<String> = Set(file.keyPhrase.keys).subtracting(Set(allKeys))
                    missingKeys.forEach { key in
                        switch file.keyPhrase[key] {
                            case .some(let phrase): Output.error(phrase, "Localized phrase '\(key)' missing from strings files")
                            case .none: Output.error(file, "Localized phrase '\(key)' missing from strings files")
                        }
                    }
                }
                break
            case .updatePermissionStrings:
                print("------------ Updating permission strings ------------")
                var strings: JSON = projectState.infoPlistLocalizationFile.strings
                var updatedInfoPlistJSON: JSON = projectState.infoPlistLocalizationFile.json
                ProjectState.permissionStrings.forEach { key in
                    guard let nsKey: String = ProjectState.permissionStringsMap[key] else { return }
                    if
                        let stringsData: Data = try? JSONSerialization.data(withJSONObject: (projectState.localizationFile.strings[key] as! JSON), options: [ .fragmentsAllowed ]),
                        let stringsJSONString: String = String(data: stringsData, encoding: .utf8)
                    {
                        let updatedStringsJSONString = stringsJSONString.replacingOccurrences(of: "{app_name}", with: "Session")
                        
                        if 
                            let updatedStringsData: Data = updatedStringsJSONString.data(using: .utf8),
                            let updatedStrings: JSON = try? JSONSerialization.jsonObject(with: updatedStringsData, options: [ .fragmentsAllowed ]) as? JSON
                        {
                            strings[nsKey] = updatedStrings
                        }
                    }
                }
                updatedInfoPlistJSON["strings"] = strings
            
                guard updatedInfoPlistJSON != projectState.infoPlistLocalizationFile.json else {
                    return
                }
                
                if let data: Data = try? JSONSerialization.data(withJSONObject: updatedInfoPlistJSON, options: [ .fragmentsAllowed, .sortedKeys ]) {
                    do {
                        try data.write(to: URL(fileURLWithPath: projectState.infoPlistLocalizationFile.path), options: [.atomic])
                    } catch {
                        fatalError("Could not write to InfoPlist.xcstrings, error: \(error)")
                    }
                }
                break
        }
        
        print("------------ Complete ------------")
    }
}

// MARK: - Functionality

enum Regex {
    /// Returns a list of strings that match regex pattern from content
    ///
    /// - Parameters:
    ///   - pattern: regex pattern
    ///   - content: content to match
    /// - Returns: list of results
    static func matches(_ pattern: String, content: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            fatalError("Regex not formatted correctly: \(pattern)")
        }
        
        let matches = regex.matches(in: content, options: [], range: NSRange(location: 0, length: content.utf16.count))
        
        return matches.map {
            guard let range = Range($0.range(at: 0), in: content) else {
                fatalError("Incorrect range match")
            }
            
            return String(content[range])
        }
    }
}

// MARK: - Output

enum Output {
    static func error(_ error: String) {
        print("error: \(error)")
    }
    
    static func error(_ location: Locatable, _ error: String) {
        print("\(location.location): error: \(error)")
    }
    
    static func warning(_ warning: String) {
        print("warning: \(warning)")
    }
    
    static func warning(_ location: Locatable, _ warning: String) {
        print("\(location.location): warning: \(warning)")
    }
    
    static func duplicate(
        _ duplicate: KeyedLocatable,
        original: KeyedLocatable
    ) {
        print("\(duplicate.location): error: duplicate key '\(original.key)'")
        
        // Looks like the `note:` doesn't work the same as when XCode does it unfortunately so we can't
        // currently include the reference to the original entry
        // print("\(original.location): note: previously found here")
    }
    
    static func duplicate(key: String) {
        print("Error: duplicate key '\(key)'")
    }
}

// MARK: - ProjectState

struct ProjectState {
    let sourceFiles: [SourceFile]
    let localizationFile: XCStringsFile
    let infoPlistLocalizationFile: XCStringsFile
    
    init(path: String, loadSourceFiles: Bool) {
        guard
            let enumerator: FileManager.DirectoryEnumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ),
            let fileUrls: [URL] = enumerator.allObjects as? [URL]
        else { fatalError("Could not locate files in path directory: \(path)") }
        
        // Get a list of valid URLs
        let lowerCaseExcludedPaths: Set<String> = Set(ProjectState.excludedPaths.map { $0.lowercased() })
        let validFileUrls: [URL] = fileUrls.filter { fileUrl in
            ((try? fileUrl.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == false) &&
            !lowerCaseExcludedPaths.contains { fileUrl.path.lowercased().contains($0) }
        }

        self.localizationFile = validFileUrls
            .filter { fileUrl in fileUrl.path.contains("Localizable.xcstrings") }
            .map { XCStringsFile(path: $0.path) }
            .last!
        
        self.infoPlistLocalizationFile = validFileUrls
            .filter { fileUrl in fileUrl.path.contains("InfoPlist.xcstrings") }
            .map { XCStringsFile(path: $0.path) }
            .last!
        
        guard loadSourceFiles else {
            self.sourceFiles = []
            return
        }
        
        // Source files
        let lowerCaseSourceSuffixes: Set<String> = Set(ProjectState.validSourceSuffixes.map { $0.lowercased() })
        self.sourceFiles = validFileUrls
            .filter { fileUrl in lowerCaseSourceSuffixes.contains(".\(fileUrl.pathExtension)") }
            .compactMap { SourceFile(path: $0.path) }
    }
}

protocol Locatable {
    var location: String { get }
}

protocol KeyedLocatable: Locatable {
    var key: String { get }
}

extension ProjectState {
    // MARK: - XCStringsFile
    
    struct XCStringsFile: Locatable {
        let name: String
        let path: String
        var json: JSON
        var strings: JSON
        var locales: Set<String> = Set()
        
        var location: String { path }
        
        init(path: String) {
            self.name = (path
                .replacingOccurrences(of: ".xcstrings", with: "")
                .components(separatedBy: "/")
                .last ?? "Unknown")
            self.path = path
            self.json = XCStringsFile.parse(path)
            self.strings = self.json["strings"] as! JSON
            self.strings.values.forEach { value in
                if let localizations: JSON = (value as? JSON)?["localizations"] as? JSON {
                    self.locales.formUnion(localizations.map{ $0.key })
                }
            }
        }
        
        static func parse(_ path: String) -> JSON {
            guard
                let data: Data = FileManager.default.contents(atPath: path),
                let json: JSON = try? JSONSerialization.jsonObject(with: data, options: [ .fragmentsAllowed ]) as? JSON
            else { fatalError("Could not read from path: \(path)") }
            
            return json
        }
    }
    
    // MARK: - SourceFile
    
    struct SourceFile: Locatable {
        struct Phrase: KeyedLocatable {
            let term: String
            let filePath: String
            let lineNumber: Int
            
            var key: String { term }
            var location: String { "\(filePath):\(lineNumber)" }
        }
        
        let path: String
        let keyPhrase: [String: Phrase]
        let unlocalizedKeyPhrase: [String: Phrase]
        let phrases: [Phrase]
        let unlocalizedPhrases: [Phrase]
        
        var location: String { path }
        
        init?(path: String) {
            guard let result = SourceFile.parse(path) else { return nil }
            
            self.path = path
            self.keyPhrase = result.keyPhrase
            self.unlocalizedKeyPhrase = result.unlocalizedKeyPhrase
            self.phrases = result.phrases
            self.unlocalizedPhrases = result.unlocalizedPhrases
        }
        
        static func parse(_ path: String) -> (keyPhrase: [String: Phrase], phrases: [Phrase], unlocalizedKeyPhrase: [String: Phrase], unlocalizedPhrases: [Phrase])? {
            guard
                let data: Data = FileManager.default.contents(atPath: path),
                let content: String = String(data: data, encoding: .utf8)
            else { fatalError("Could not read from path: \(path)") }
            
            // If the file has the lint supression before the first import then ignore the file
            let preImportContent: String = (content.components(separatedBy: "import").first ?? "")
            
            guard !preImportContent.contains(ProjectState.lintSuppression) else {
                print("Explicitly ignoring \(path)")
                return nil
            }
            
            // Otherwise continue and process the file
            let lines: [String] = content.components(separatedBy: .newlines)
            var keyPhrase: [String: Phrase] = [:]
            var unlocalizedKeyPhrase: [String: Phrase] = [:]
            var phrases: [Phrase] = []
            var unlocalizedPhrases: [Phrase] = []
            
            lines.enumerated().forEach { lineNumber, line in
                let trimmedLine: String = line.trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Ignore the line if it doesn't contain a quotation character (optimisation), it's
                // been suppressed or it's explicitly excluded due to the rules at the top of the file
                guard
                    trimmedLine.contains("\"") &&
                    !ProjectState.excludedUnlocalizedStringLineMatching
                        .contains(where: { $0.matches(trimmedLine, lineNumber, lines) })
                else { return }
                
                // Split line based on commented out content and exclude the comment from the linting
                let commentMatches: [String] = Regex.matches(
                    "//[^\\\"]*(?:\\\"[^\\\"]*\\\"[^\\\"]*)*",
                    content: line
                )
                let targetLine: String = (commentMatches.isEmpty ? line :
                    line.components(separatedBy: commentMatches[0])[0]
                )
                
                // Use regex to find `NSLocalizedString("", "")`, `"".localized()` and any other `""`
                // values in the source code
                //
                // Note: It's more complex because we need to exclude escaped quotation marks from
                // strings and also want to ignore any strings that have been commented out, Swift
                // also doesn't support "lookbehind" in regex so we can use that approach
                var isUnlocalized: Bool = false
                var allMatches: Set<String> = Set(
                    Regex
                        .matches(
                            "NSLocalizedString\\(@{0,1}\\\"[^\\\"\\\\]*(?:\\\\.[^\\\"\\\\]*)*(?:\\\")",
                            content: targetLine
                        )
                        .map { match in
                            match
                                .removingPrefixIfPresent("NSLocalizedString(@\"")
                                .removingPrefixIfPresent("NSLocalizedString(\"")
                                .removingSuffixIfPresent("\")")
                                .removingSuffixIfPresent("\"")
                        }
                )
                
                // If we didn't get any matches for the standard `NSLocalizedString` then try our
                // custom extension `"".localized()`
                if allMatches.isEmpty {
                    allMatches = allMatches.union(Set(
                        Regex
                            .matches(
                                "\\\"[^\\\"\\\\]*(?:\\\\.[^\\\"\\\\]*)*\\\"\\.localized",
                                content: targetLine
                            )
                            .map { match in
                                match
                                    .removingPrefixIfPresent("\"")
                                    .removingSuffixIfPresent("\".localized")
                            }
                    ))
                }
                
                /// If we still don't have any matches then try to match any strings as unlocalized strings (handling
                /// nested `"Test\"string\" value"`, empty strings and strings only composed of quotes `"""""""`)
                ///
                /// **Note:** While it'd be nice to have the regex automatically exclude the quotes doing so makes it _far_ less
                /// efficient (approx. by a factor of 8 times) so we remove those ourselves)
                if allMatches.isEmpty {
                    // Find strings which are just not localized
                    let potentialUnlocalizedStrings: [String] = Regex
                        .matches("\\\"[^\\\"\\\\]*(?:\\\\.[^\\\"\\\\]*)*(?:\\\")", content: targetLine)
                        // Remove the leading and trailing quotation marks
                        .map { $0.removingPrefixIfPresent("\"").removingSuffixIfPresent("\"") }
                        // Remove any empty strings
                        .filter { !$0.isEmpty }
                        // Remove any string conversations (ie. `.map { "\($0)" }`
                        .filter { value in !value.hasPrefix("\\(") || !value.hasSuffix(")") }
                    
                    allMatches = allMatches.union(Set(potentialUnlocalizedStrings))
                    isUnlocalized = true
                }
                
                // Remove any excluded phrases from the matches
                allMatches = allMatches.subtracting(ProjectState.excludedPhrases.map { "\($0)" })
                
                allMatches.forEach { match in
                    // Files are 1-indexed but arrays are 0-indexed so add 1 to the lineNumber
                    let result: Phrase = Phrase(
                        term: match,
                        filePath: path,
                        lineNumber: (lineNumber + 1)
                    )
                    
                    if !isUnlocalized {
                        keyPhrase[match] = result
                        phrases.append(result)
                    }
                    else {
                        unlocalizedKeyPhrase[match] = result
                        unlocalizedPhrases.append(result)
                    }
                }
            }
            
            return (keyPhrase, phrases, unlocalizedKeyPhrase, unlocalizedPhrases)
        }
    }
}

indirect enum MatchType: Hashable {
    case prefix(String, caseSensitive: Bool)
    case contains(String, caseSensitive: Bool)
    case containsAnd(String, caseSensitive: Bool, MatchType)
    case regex(String)
    case previousLine(numEarlier: Int, MatchType)
    case nextLine(MatchType)
    case belowLineContaining(String)
    
    func matches(_ value: String, _ index: Int, _ lines: [String]) -> Bool {
        switch self {
            case .prefix(let prefix, false):
                return value
                    .lowercased()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .hasPrefix(prefix.lowercased())
                
            case .prefix(let prefix, true):
                return value
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .hasPrefix(prefix)
                
            case .contains(let other, false): return value.lowercased().contains(other.lowercased())
            case .contains(let other, true): return value.contains(other)
            case .containsAnd(let other, false, let otherMatch):
                guard value.lowercased().contains(other.lowercased()) else { return false }
                
                return otherMatch.matches(value, index, lines)
                
            case .containsAnd(let other, true, let otherMatch):
                guard value.contains(other) else { return false }
                
                return otherMatch.matches(value, index, lines)
                
            case .regex(let regex): return !Regex.matches(regex, content: value).isEmpty
                
            case .previousLine(let numEarlier, let type):
                guard index >= numEarlier else { return false }
                
                let targetIndex: Int = (index - numEarlier)
                return type.matches(lines[targetIndex], targetIndex, lines)
            
            case .nextLine(let type):
                guard index + 1 < lines.count else { return false }
                return type.matches(lines[index + 1], index + 1, lines)
            
            case .belowLineContaining(let other):
                return lines[0..<index].contains(where: { $0.lowercased().contains(other.lowercased()) })
        }
    }
}

extension String {
    func removingPrefixIfPresent(_ value: String) -> String {
        guard hasPrefix(value) else { return self }
        
        return String(self.suffix(from: self.index(self.startIndex, offsetBy: value.count)))
    }
    
    func removingSuffixIfPresent(_ value: String) -> String {
        guard hasSuffix(value) else { return self }
        
        return String(self.prefix(upTo: self.index(self.endIndex, offsetBy: -value.count)))
    }
}
