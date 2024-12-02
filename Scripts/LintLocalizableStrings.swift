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
import Dispatch

typealias JSON = [String:AnyHashable]

extension ProjectState {
    /// Linting control commands
    enum LintControl: String, CaseIterable {
        /// Add `// stringlint:disable` to the top of a source file (before imports) to make this script ignore a file
        case disable = "stringlint:disable"
        
        /// Add `// stringlint:ignore` after a line to ignore it
        case ignoreLine = "stringlint:ignore"
        
        /// Add `// stringlint:ignore_start` and `// stringlint:ignore_stop` before and after a
        /// lines of code to make this script ignore the contents for string linting purposes
        case ignoreStart = "stringlint:ignore_start"
        case ignoreStop = "stringlint:ignore_stop"
        
        /// Add `// stringlint:ignore_contents` before anything with curly braces (eg. function, class, closure, etc.)
        /// to everything within the curly braces
        case ignoreContents = "stringlint:ignore_contents"
    }
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
    static let excludedPhrases: Set<String> = [ "", " ", "  ", ",", ", ", "null", "\"", "@[0-9a-fA-F]{66}", "^[0-9A-Fa-f]+$", "/" ]
    static let excludedUnlocalizedStringLineMatching: [MatchType] = [
        .prefix("#import", caseSensitive: false),
        .prefix("@available(", caseSensitive: false),
        .prefix("print(", caseSensitive: false),
        .prefix("Log.Category =", caseSensitive: false),
        .contains("fatalError(", caseSensitive: false),
        .contains("precondition(", caseSensitive: false),
        .contains("preconditionFailure(", caseSensitive: false),
        .contains("logMessage:", caseSensitive: false),
        .contains(".logging(", caseSensitive: false),
        .contains("owsFailDebug(", caseSensitive: false),
        .contains("error: .other(", caseSensitive: false),
        .contains("#imageLiteral(resourceName:", caseSensitive: false),
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
        .and(
            .prefix("static let identifier: String = ", caseSensitive: false),
            .previousLine(numEarlier: 2, .suffix(": Migration {", caseSensitive: false))
        ),
        .and(
            .contains("identifier:", caseSensitive: false),
            .previousLine(.contains("Accessibility(", caseSensitive: false))
        ),
        .and(
            .contains("label:", caseSensitive: false),
            .previousLine(.contains("Accessibility(", caseSensitive: false))
        ),
        .and(
            .contains("label:", caseSensitive: false),
            .previousLine(numEarlier: 2, .contains("Accessibility(", caseSensitive: false))
        ),
        .contains("SQL(", caseSensitive: false),
        .contains("forResource:", caseSensitive: false),
        .contains("imageName:", caseSensitive: false),
        .contains("systemName:", caseSensitive: false),
        .contains(".userInfo[", caseSensitive: false),
        .contains("payload[", caseSensitive: false),
        .contains(".infoDictionary?[", caseSensitive: false),
        .contains("accessibilityId:", caseSensitive: false),
        .contains("SNUIKit.localizedString(for:", caseSensitive: false),
        .and(
            .contains("id:", caseSensitive: false),
            .previousLine(numEarlier: 1, .regex(Regex.crypto))
        ),
        .and(
            .contains("identifier:", caseSensitive: false),
            .previousLine(numEarlier: 1, .contains("Dependencies.create", caseSensitive: false))
        ),
        .belowLineContaining("PreviewProvider"),
        .belowLineContaining("#Preview"),
        .regex(Regex.logging),
        .regex(Regex.errorCreation),
        .regex(Regex.databaseTableName),
        .regex(Regex.enumCaseDefinition),
        .regex(Regex.imageInitialization),
        .regex(Regex.variableToStringConversion)
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
let projectState: ProjectState = ProjectState(path:
    ProcessInfo.processInfo.environment["PROJECT_DIR"] ??
    FileManager.default.currentDirectoryPath
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
                                    // Zero-width characters can mess with regex matching so we need to clean them
                                    // out before matching
                                    let numberOfVarablesOrignal: Int = original
                                        .removingUnwantedScalars()
                                        .matches(of: Regex.dynamicStringVariable)
                                        .count
                                    let numberOfVarablesPhrase: Int = phrase
                                        .removingUnwantedScalars()
                                        .matches(of: Regex.dynamicStringVariable)
                                        .count
                                    
                                    if numberOfVarablesPhrase != numberOfVarablesOrignal {
                                        Output.warning("\(key) in \(locale) may be faulty ('\(original)' contains \(numberOfVarablesOrignal) vs. '\(phrase)' contains \(numberOfVarablesPhrase))")
                                    }
                                }
                            }
                        }
                    }
                }
            
                // Add warnings for any duplicate keys
                duplicates.forEach { Output.duplicate(key: $0) }

                // Process the source code
                print("------------ Processing Source Files ------------")
                let results = projectState.lintSourceFiles()
                print("------------ Processed \(results.sourceFiles.count) File(s), Ignored \(results.ignoredPaths.count) File(s) ------------")
                var totalUnlocalisedStrings: Int = 0
  
                results.sourceFiles.forEach { file in
                    // Add logs for unlocalized strings
                    file.unlocalizedPhrases.forEach { phrase in
                        totalUnlocalisedStrings += 1
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
                
                print("------------ Found \(totalUnlocalisedStrings) unlocalized string(s) ------------")
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
    // Initializing these as static variables means we don't init them every time they are used
    // which can speed up processing
    static let comment = #/\/\/[^"]*(?:"[^"]*"[^"]*)*/#
    static let allStrings = #/"[^"\\]*(?:\\.[^"\\]*)*"/#
    static let localizedString = #/^(?:\.put(?:Number)?\([^)]+\))*\.localized/#
    static let localizedFunctionCall = #/\.localized(?:Formatted)?\(.*\)/#
    
    static let logging = #/(?:SN)?Log.*\(/#
    static let errorCreation = #/Error.*\(/#
    static let databaseTableName = #/.*static var databaseTableName: String/#
    static let enumCaseDefinition = #/case .* = /#
    static let imageInitialization = #/(?:UI)?Image\((?:named:)?(?:imageName:)?(?:systemName:)?.*\)/#
    static let variableToStringConversion = #/"\\(.*)"/#
    
    static let crypto = #/Crypto.*\(/#
    
    static let dynamicStringVariable = #/\{\w+\}/#
    
    /// Returns a list of strings that match regex pattern from content
    ///
    /// - Parameters:
    ///   - pattern: regex pattern
    ///   - content: content to match
    /// - Returns: list of results
    static func matches(_ regex: some RegexComponent, content: String) -> [String] {
        return content.matches(of: regex).map { match in
            String(content[match.range])
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
    let queue = DispatchQueue(label: "session.stringlint", attributes: .concurrent)
    let group = DispatchGroup()
    let validFileUrls: [URL]
    let localizationFile: XCStringsFile
    let infoPlistLocalizationFile: XCStringsFile
    
    init(path: String) {
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
        validFileUrls = fileUrls.filter { fileUrl in
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
    }
    
    func lintSourceFiles() -> (sourceFiles: [SourceFile], ignoredPaths: [String]) {
        let resultLock: NSLock = NSLock()
        let lowerCaseSourceSuffixes: Set<String> = Set(ProjectState.validSourceSuffixes.map { $0.lowercased() })
        var results: [(path: String, file: SourceFile?)] = []
        validFileUrls
            .filter { fileUrl in lowerCaseSourceSuffixes.contains(".\(fileUrl.pathExtension)") }
            .forEach { fileUrl in
                queue.async(group: group) {
                    let file: SourceFile? = SourceFile(path: fileUrl.path)
                    resultLock.lock()
                    results.append((fileUrl.path, file))
                    resultLock.unlock()
                }
            }
        
        group.wait()
        
        let sourceFiles: [SourceFile] = results.compactMap { _, file in file }
        let ignoredPaths: [String] = results.filter { _, file in file == nil }.map { path, _ in path }
        
        return (sourceFiles, ignoredPaths)
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
        struct LintState {
            var isDisabled: Bool = false
            var isInIgnoredSection: Bool = false
            var isInIgnoredContents: Bool = false
            var ignoredContentsDepth: Int = 0
        }
        
        struct TemplateStringState {
            var key: String
            var lineNumber: Int
            var chainedCalls: [String]
        }
        
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
            
            guard !preImportContent.contains(ProjectState.LintControl.disable.rawValue) else {
                return nil
            }
            
            // Otherwise continue and process the file
            let lines: [String] = content.components(separatedBy: .newlines)
            var keyPhrase: [String: Phrase] = [:]
            var unlocalizedKeyPhrase: [String: Phrase] = [:]
            var phrases: [Phrase] = []
            var unlocalizedPhrases: [Phrase] = []
            var lintState = LintState()
            var templateState: TemplateStringState?
            
            lines.enumerated().forEach { lineNumber, line in
                let trimmedLine: String = line.trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Check for lint control commands
                if let controlCommand: ProjectState.LintControl = checkLintControl(line: trimmedLine) {
                    updateLintState(&lintState, command: controlCommand, line: trimmedLine)
                    return
                }
                
                // Track function depth for ignored functions
                if lintState.isInIgnoredContents {
                    updateContentsDepth(&lintState, line: trimmedLine)
                }
                
                // Skip linting if disabled
                guard !shouldSkipLinting(state: lintState) else { return }
                
                // Skip lines without quotes (optimization)
                guard trimmedLine.contains("\"") else { return }
                
                // Skip explicitly excluded lines
                guard
                    !ProjectState.excludedUnlocalizedStringLineMatching
                        .contains(where: { $0.matches(trimmedLine, lineNumber, lines) })
                else { return }
                
                // Process the line for strings
                processLine(
                    line: line,
                    lineNumber: lineNumber,
                    path: path,
                    keyPhrase: &keyPhrase,
                    unlocalizedKeyPhrase: &unlocalizedKeyPhrase,
                    phrases: &phrases,
                    unlocalizedPhrases: &unlocalizedPhrases,
                    templateState: &templateState,
                    lines: lines
                )
            }
            
            return (keyPhrase, phrases, unlocalizedKeyPhrase, unlocalizedPhrases)
        }
        
        private static func checkLintControl(line: String) -> ProjectState.LintControl? {
            /// Need to sort by length to ensure we don't unintentionally detect one control mechanism over another
            /// due to it containing the full other command - eg. `disable_start` vs `disable`
            ProjectState.LintControl.allCases
                .sorted { lhs, rhs in lhs.rawValue.count > rhs.rawValue.count }
                .first { line.contains($0.rawValue) }
        }
        
        private static func updateLintState(_ state: inout LintState, command: ProjectState.LintControl, line: String) {
            switch command {
                case .disable: state.isDisabled = true
                case .ignoreStart: state.isInIgnoredSection = true
                case .ignoreStop: state.isInIgnoredSection = false
                case .ignoreContents:
                    guard !state.isInIgnoredContents else { return }
                    
                    state.isInIgnoredContents = true
                    state.ignoredContentsDepth = 0
                    
                case .ignoreLine: break // Handle single-line ignore in the caller
            }
        }
        
        private static func updateContentsDepth(_ state: inout LintState, line: String) {
            if line.contains("{") {
                state.ignoredContentsDepth += 1
            }
            if line.contains("}") {
                state.ignoredContentsDepth -= 1
                if state.ignoredContentsDepth == 0 {
                    state.isInIgnoredContents = false
                }
            }
        }
        
        private static func shouldSkipLinting(state: LintState) -> Bool {
            state.isDisabled || state.isInIgnoredSection || state.isInIgnoredContents
        }
        
        private static func processLine(
            line: String,
            lineNumber: Int,
            path: String,
            keyPhrase: inout [String: Phrase],
            unlocalizedKeyPhrase: inout [String: Phrase],
            phrases: inout [Phrase],
            unlocalizedPhrases: inout [Phrase],
            templateState: inout TemplateStringState?,
            lines: [String]
        ) {
            // Handle commented sections
            let commentMatches = line.matches(of: Regex.comment)
            let targetLine: String = (commentMatches.isEmpty ?
                line :
                String(line[..<commentMatches[0].range.lowerBound])
            )
            
            switch templateState {
                case .none:
                    // Extract the strings and remove any excluded phrases
                    let keyMatches: [String] = extractMatches(from: targetLine, with: Regex.allStrings)
                        .filter { !ProjectState.excludedPhrases.contains($0) }
                    
                    if !keyMatches.isEmpty {
                        // Iterate through each match to determine localization
                        for match in keyMatches {
                            // Find the range of the matched string
                            if let range = targetLine.range(of: "\"\(match)\"") {
                                // Check if .localized or a template func is called immediately following
                                // this specific string
                                let afterString = targetLine[range.upperBound...]
                                let isLocalized: Bool = (afterString.firstMatch(of: Regex.localizedString) != nil)
                                
                                if isLocalized {
                                    // Add as a localized phrase
                                    let phrase = Phrase(
                                        term: match,
                                        filePath: path,
                                        lineNumber: lineNumber + 1 // Files are 1-indexed so add 1 to lineNumber
                                    )
                                    keyPhrase[match] = phrase
                                    phrases.append(phrase)
                                    return
                                }
                                else if (match != keyMatches.last) {
                                    // There is another string after this one so this couldn't be localized
                                    // or a multi-line template
                                    let unlocalizedPhrase = Phrase(
                                        term: match,
                                        filePath: path,
                                        lineNumber: lineNumber + 1 // Files are 1-indexed so add 1 to lineNumber
                                    )
                                    unlocalizedKeyPhrase[match] = unlocalizedPhrase
                                    unlocalizedPhrases.append(unlocalizedPhrase)
                                }
                                else {
                                    // Look ahead to verify if put/putNumber/localized are called in the next lines
                                    let lookAheadLimit: Int = 2
                                    var isTemplateChain: Bool = false
                                    
                                    for offset in 1...lookAheadLimit {
                                        let lookAheadIndex: Int = lineNumber + offset
                                        
                                        if lookAheadIndex < lines.count {
                                            let lookAheadLine = lines[lookAheadIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                                            
                                            if
                                                lookAheadLine.hasPrefix(".put(") ||
                                                lookAheadLine.hasPrefix(".putNumber(") ||
                                                lookAheadLine.hasPrefix(".localized")
                                            {
                                                isTemplateChain = true
                                                break
                                            }
                                        }
                                    }
                                    
                                    if isTemplateChain {
                                        templateState = TemplateStringState(
                                            key: keyMatches[0],
                                            lineNumber: lineNumber,
                                            chainedCalls: []
                                        )
                                        return
                                    }
                                    else {
                                        // We didn't find any of the expected functions when looking ahead
                                        // so we can assume it's an unlocalised string
                                        let unlocalizedPhrase = Phrase(
                                            term: match,
                                            filePath: path,
                                            lineNumber: lineNumber + 1 // Files are 1-indexed so add 1 to lineNumber
                                        )
                                        unlocalizedKeyPhrase[match] = unlocalizedPhrase
                                        unlocalizedPhrases.append(unlocalizedPhrase)
                                    }
                                }
                            }
                        }
                    }
                        
                case .some(let state):
                    switch targetLine.firstMatch(of: Regex.localizedFunctionCall) {
                        case .some:
                            // We finished the change so add as a localized phrase
                            let phrase = Phrase(
                                term: state.key,
                                filePath: path,
                                lineNumber: state.lineNumber + 1 // Files are 1-indexed so add 1 to lineNumber
                            )
                            keyPhrase[state.key] = phrase
                            phrases.append(phrase)
                            templateState = nil
                            
                        case .none:
                            // The chain is still going to append the line
                            templateState?.chainedCalls.append(targetLine)
                    }
            }
        }
        
        private static func extractMatches(from line: String, with regex: some RegexComponent) -> [String] {
            return line.matches(of: regex).map { match in
                // Clean up the matches
                return String(line[match.range])
                    .removingPrefixIfPresent("NSLocalizedString(@\"")
                    .removingPrefixIfPresent("NSLocalizedString(\"")
                    .removingPrefixIfPresent("\"")
                    .removingSuffixIfPresent("\".localized")
                    .removingSuffixIfPresent("\")")
                    .removingSuffixIfPresent("\"")
            }
        }
        
        private static func createPhrases(
            from matches: Set<String>,
            isUnlocalized: Bool,
            lineNumber: Int,
            path: String,
            keyPhrase: inout [String: Phrase],
            unlocalizedKeyPhrase: inout [String: Phrase],
            phrases: inout [Phrase],
            unlocalizedPhrases: inout [Phrase]
        ) {
            matches.forEach { match in
                let result = Phrase(
                    term: match,
                    filePath: path,
                    lineNumber: lineNumber + 1
                )
                
                if !isUnlocalized {
                    keyPhrase[match] = result
                    phrases.append(result)
                } else {
                    unlocalizedKeyPhrase[match] = result
                    unlocalizedPhrases.append(result)
                }
            }
        }
    }
}

indirect enum MatchType {
    case and(MatchType, MatchType)
    case prefix(String, caseSensitive: Bool)
    case suffix(String, caseSensitive: Bool)
    case contains(String, caseSensitive: Bool)
    case regex(any RegexComponent)
    case previousLine(numEarlier: Int, MatchType)
    case nextLine(numLater: Int, MatchType)
    case belowLineContaining(String)
    
    static func previousLine(_ type: MatchType) -> MatchType { return .previousLine(numEarlier: 1, type) }
    static func nextLine(_ type: MatchType) -> MatchType { return .nextLine(numLater: 1, type) }
    
    func matches(_ value: String, _ index: Int, _ lines: [String]) -> Bool {
        switch self {
            case .and(let firstMatch, let secondMatch):
                guard firstMatch.matches(value, index, lines) else { return false }
                
                return secondMatch.matches(value, index, lines)
                
            case .prefix(let prefix, false):
                return value
                    .lowercased()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .hasPrefix(prefix.lowercased())
                
            case .prefix(let prefix, true):
                return value
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .hasPrefix(prefix)
                
            case .suffix(let suffix, false):
                return value
                    .lowercased()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .hasSuffix(suffix.lowercased())
                
            case .suffix(let suffix, true):
                return value
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .hasSuffix(suffix)
                
            case .contains(let other, false): return value.lowercased().contains(other.lowercased())
            case .contains(let other, true): return value.contains(other)
            case .regex(let regex): return !Regex.matches(regex, content: value).isEmpty
                
            case .previousLine(let numEarlier, let type):
                guard index >= numEarlier else { return false }
                
                let targetIndex: Int = (index - numEarlier)
                return type.matches(lines[targetIndex], targetIndex, lines)
            
            case .nextLine(let numLater, let type):
                guard index + numLater < lines.count else { return false }
                
                let targetIndex: Int = (index + numLater)
                return type.matches(lines[targetIndex], targetIndex, lines)
            
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
    
    func removingUnwantedScalars() -> String {
        let unwantedScalars: Set<Unicode.Scalar> = [
            "\u{200B}", // ZERO WIDTH SPACE
            "\u{200C}", // ZERO WIDTH NON-JOINER
            "\u{200D}", // ZERO WIDTH JOINER
            "\u{FEFF}"  // ZERO WIDTH NO-BREAK SPACE
        ]
        return String(self.unicodeScalars.filter { !unwantedScalars.contains($0) }.map { Character($0) })
    }
}
