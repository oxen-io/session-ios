// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit
import Combine

// MARK: - MockError

public enum MockError: Error {
    case mockedData
}

// MARK: - Mock<T>

public class Mock<T>: DependenciesSettable {
    private var _dependencies: Dependencies!
    private let functionHandler: MockFunctionHandler
    internal let functionConsumer: FunctionConsumer
    
    public var dependencies: Dependencies { _dependencies }
    
    // MARK: - Initialization
    
    internal required init(
        functionHandler: MockFunctionHandler? = nil,
        initialSetup: ((Mock<T>) -> ())? = nil
    ) {
        self.functionConsumer = FunctionConsumer()
        self.functionHandler = (functionHandler ?? self.functionConsumer)
        initialSetup?(self)
    }
    
    // MARK: - DependenciesSettable
    
    public func setDependencies(_ dependencies: Dependencies?) {
        self._dependencies = dependencies
    }
    
    // MARK: - MockFunctionHandler
    
    @discardableResult internal func mock<Output>(funcName: String = #function, args: [Any?] = [], untrackedArgs: [Any?] = []) -> Output {
        return functionHandler.mock(
            funcName,
            parameterCount: args.count,
            parameterSummary: summary(for: args),
            allParameterSummaryCombinations: summaries(for: args),
            args: args,
            untrackedArgs: untrackedArgs
        )
    }
    
    internal func mockNoReturn(funcName: String = #function, args: [Any?] = [], untrackedArgs: [Any?] = []) {
        functionHandler.mockNoReturn(
            funcName,
            parameterCount: args.count,
            parameterSummary: summary(for: args),
            allParameterSummaryCombinations: summaries(for: args),
            args: args,
            untrackedArgs: untrackedArgs
        )
    }
    
    @discardableResult internal func mockThrowing<Output>(funcName: String = #function, args: [Any?] = [], untrackedArgs: [Any?] = []) throws -> Output {
        return try functionHandler.mockThrowing(
            funcName,
            parameterCount: args.count,
            parameterSummary: summary(for: args),
            allParameterSummaryCombinations: summaries(for: args),
            args: args,
            untrackedArgs: untrackedArgs
        )
    }
    
    internal func mockThrowingNoReturn(funcName: String = #function, args: [Any?] = [], untrackedArgs: [Any?] = []) throws {
        try functionHandler.mockThrowingNoReturn(
            funcName,
            parameterCount: args.count,
            parameterSummary: summary(for: args),
            allParameterSummaryCombinations: summaries(for: args),
            args: args,
            untrackedArgs: untrackedArgs
        )
    }
    
    // MARK: - Functions
    
    internal func reset() {
        functionConsumer.trackCalls = true
        functionConsumer.functionBuilders = []
        functionConsumer.functionHandlers = [:]
        functionConsumer.calls.mutate { $0 = [:] }
    }
    
    internal func when<R>(_ callBlock: @escaping (inout T) throws -> R) -> MockFunctionBuilder<T, R> {
        let builder: MockFunctionBuilder<T, R> = MockFunctionBuilder(callBlock, mockInit: type(of: self).init)
        functionConsumer.functionBuilders.append(builder.build)
        
        return builder
    }
    
    // MARK: - Convenience
    
    private func summaries(for argument: Any) -> [ParameterCombination] {
        switch argument {
            case let array as [Any]:
                return array.allCombinations()
                    .map { ParameterCombination(count: $0.count, summary: summary(for: $0)) }
                
            default: return [ParameterCombination(count: 1, summary: summary(for: argument))]
        }
    }
    
    private func summary(for argument: Any) -> String {
        if
            let customDescribable: CustomArgSummaryDescribable = argument as? CustomArgSummaryDescribable,
            let customArgSummaryDescribable: String = customDescribable.customArgSummaryDescribable
        { return customArgSummaryDescribable }
        
        switch argument {
            case let string as String: return string
            case let array as [Any]: return "[\(array.map { summary(for: $0) }.joined(separator: ", "))]"
                
            case let dict as [String: Any]:
                if dict.isEmpty { return "[:]" }
                
                let sortedValues: [String] = dict
                    .map { key, value in "\(summary(for: key)):\(summary(for: value))" }
                    .sorted()
                return "[\(sortedValues.joined(separator: ", "))]"
                
            case let data as Data: return "Data(base64Encoded: \(data.base64EncodedString()))"
                
            default:
                // Default to the `debugDescription` if available but sort any dictionary content by keys
                return sortDictionariesInReflectedString(String(reflecting: argument))
        }
    }
    
    private func sortDictionariesInReflectedString(_ input: String) -> String {
        // Regular expression to match the headers dictionary
        let pattern = "\\[(.+?)\\]"
        let regex = try! NSRegularExpression(pattern: pattern, options: [])
        
        var result = ""
        var lastRange = input.startIndex..<input.startIndex
        
        regex.enumerateMatches(in: input, options: [], range: NSRange(input.startIndex..<input.endIndex, in: input)) { match, _, _ in
            guard let match = match, let range = Range(match.range, in: input) else { return }
            
            // Append the text before this match
            result += input[lastRange.upperBound..<range.lowerBound]
            
            // Extract the dictionary string
            if let innerRange = Range(match.range(at: 1), in: input) {
                let dictionaryString = String(input[innerRange])
                let sortedDictionaryString = sortDictionaryString(dictionaryString)
                result += (sortedDictionaryString.isEmpty ? "[:]" : "[\(sortedDictionaryString)]")
            } else {
                // If we can't extract the inner part, just use the original matched text
                result += input[range]
            }
            
            lastRange = range
        }

        // Append any remaining text after the last match
        result += input[lastRange.upperBound..<input.endIndex]
        
        return result
    }
    
    private func sortDictionaryString(_ dictionaryString: String) -> String {
        var pairs: [(String, String)] = []
        var currentKey = ""
        var currentValue = ""
        var inQuotes = false
        var parsingKey = true
        var nestedLevel = 0
        
        for char in dictionaryString {
            switch char {
                case "\"":
                    inQuotes.toggle()
                    if nestedLevel > 0 {
                        currentKey.append(char)
                        continue
                    }
                
                case ":":
                    if !inQuotes && nestedLevel == 0 {
                        parsingKey = false
                        continue
                    }
                
                case ",":
                    if !inQuotes && nestedLevel == 0 {
                        pairs.append((currentKey.trimmingCharacters(in: .whitespaces), currentValue.trimmingCharacters(in: .whitespaces)))
                        currentKey = ""
                        currentValue = ""
                        parsingKey = true
                        continue
                    }
                
                case "[", "{": nestedLevel += (parsingKey ? 0 : 1)
                case "]", "}": nestedLevel -= (parsingKey ? 0 : 1)
                default: break
            }
            
            switch parsingKey {
                case true: currentKey.append(char)
                case false: currentValue.append(char)
            }
        }
        
        // Add the last pair if exists
        if !currentKey.isEmpty || !currentValue.isEmpty {
            pairs.append((currentKey.trimmingCharacters(in: .whitespaces), currentValue.trimmingCharacters(in: .whitespaces)))
        }
        
        // Sort pairs by key
        let sortedPairs = pairs.sorted { $0.0 < $1.0 }
        
        // Join sorted pairs back into a string
        return sortedPairs.map { "\($0): \($1)" }.joined(separator: ", ")
    }
}

// MARK: - MockFunctionHandler

protocol MockFunctionHandler {
    func mock<Output>(
        _ functionName: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        args: [Any?],
        untrackedArgs: [Any?]
    ) -> Output
    
    func mockNoReturn(
        _ functionName: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        args: [Any?],
        untrackedArgs: [Any?]
    )
    
    func mockThrowing<Output>(
        _ functionName: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        args: [Any?],
        untrackedArgs: [Any?]
    ) throws -> Output
    
    func mockThrowingNoReturn(
        _ functionName: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        args: [Any?],
        untrackedArgs: [Any?]
    ) throws
}

// MARK: - CallDetails

internal struct CallDetails: Equatable, Hashable {
    let parameterSummary: String
    let allParameterSummaryCombinations: [ParameterCombination]
}

// MARK: - ParameterCombination

internal struct ParameterCombination: Equatable, Hashable {
    let count: Int
    let summary: String
}

// MARK: - MockFunction

internal class MockFunction {
    var name: String
    var parameterCount: Int
    var parameterSummary: String
    var allParameterSummaryCombinations: [ParameterCombination]
    var actions: [([Any?], [Any?]) -> Void]
    var returnError: (any Error)?
    var returnValue: Any?
    
    init(
        name: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        actions: [([Any?], [Any?]) -> Void],
        returnError: (any Error)?,
        returnValue: Any?
    ) {
        self.name = name
        self.parameterCount = parameterCount
        self.parameterSummary = parameterSummary
        self.allParameterSummaryCombinations = allParameterSummaryCombinations
        self.actions = actions
        self.returnError = returnError
        self.returnValue = returnValue
    }
}

// MARK: - MockFunctionBuilder

internal class MockFunctionBuilder<T, R>: MockFunctionHandler {
    private let callBlock: (inout T) throws -> R
    private let mockInit: (MockFunctionHandler?, ((Mock<T>) -> ())?) -> Mock<T>
    private var functionName: String?
    private var parameterCount: Int?
    private var parameterSummary: String?
    private var allParameterSummaryCombinations: [ParameterCombination]?
    private var actions: [([Any?], [Any?]) -> Void] = []
    private var returnValue: R?
    internal var returnValueGenerator: ((String, Int, String, [ParameterCombination]) -> R?)?
    private var returnError: Error?
    
    // MARK: - Initialization
    
    init(_ callBlock: @escaping (inout T) throws -> R, mockInit: @escaping (MockFunctionHandler?, ((Mock<T>) -> ())?) -> Mock<T>) {
        self.callBlock = callBlock
        self.mockInit = mockInit
    }
    
    // MARK: - Behaviours
    
    /// Closure parameter is an array of arguments called by the function
    @discardableResult func then(_ block: @escaping ([Any?]) -> Void) -> MockFunctionBuilder<T, R> {
        actions.append({ args, _ in block(args) })
        return self
    }
    
    /// Closure parameters are an array of arguments, followed by an array of "untracked" arguments called by the function
    @discardableResult func then(_ block: @escaping ([Any?], [Any?]) -> Void) -> MockFunctionBuilder<T, R> {
        actions.append(block)
        return self
    }
    
    func thenReturn(_ value: R?) {
        returnValue = value
    }
    
    func thenThrow(_ error: Error) {
        returnError = error
    }
    
    // MARK: - MockFunctionHandler
    
    func mock<Output>(
        _ functionName: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        args: [Any?],
        untrackedArgs: [Any?]
    ) -> Output {
        self.functionName = functionName
        self.parameterCount = parameterCount
        self.parameterSummary = parameterSummary
        self.allParameterSummaryCombinations = allParameterSummaryCombinations
        
        let result: Any? = (
            returnValue ??
            returnValueGenerator?(functionName, parameterCount, parameterSummary, allParameterSummaryCombinations)
        )
        
        return (result as! Output)
    }
    
    func mockNoReturn(
        _ functionName: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        args: [Any?],
        untrackedArgs: [Any?]
    ) {
        self.functionName = functionName
        self.parameterCount = parameterCount
        self.parameterSummary = parameterSummary
        self.allParameterSummaryCombinations = allParameterSummaryCombinations
    }
    
    func mockThrowing<Output>(
        _ functionName: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        args: [Any?],
        untrackedArgs: [Any?]
    ) throws -> Output {
        self.functionName = functionName
        self.parameterCount = parameterCount
        self.parameterSummary = parameterSummary
        self.allParameterSummaryCombinations = allParameterSummaryCombinations
        
        if let returnError: Error = returnError { throw returnError }
        
        let anyResult: Any? = (
            returnValue ??
            returnValueGenerator?(functionName, parameterCount, parameterSummary, allParameterSummaryCombinations)
        )
        
        switch anyResult {
            case let value as Output: return value
            default: throw MockError.mockedData
        }
    }
    
    func mockThrowingNoReturn(
        _ functionName: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        args: [Any?],
        untrackedArgs: [Any?]
    ) throws {
        self.functionName = functionName
        self.parameterCount = parameterCount
        self.parameterSummary = parameterSummary
        self.allParameterSummaryCombinations = allParameterSummaryCombinations
        
        if let returnError: Error = returnError { throw returnError }
    }
    
    // MARK: - Build
    
    func build() throws -> MockFunction {
        var completionMock = mockInit(self, nil) as! T
        _ = try? callBlock(&completionMock)
        
        guard
            let name: String = functionName,
            let parameterCount: Int = parameterCount,
            let parameterSummary: String = parameterSummary,
            let allParameterSummaryCombinations: [ParameterCombination] = allParameterSummaryCombinations
        else { preconditionFailure("Attempted to build the MockFunction before it was called") }
        
        return MockFunction(
            name: name,
            parameterCount: parameterCount,
            parameterSummary: parameterSummary,
            allParameterSummaryCombinations: allParameterSummaryCombinations,
            actions: actions,
            returnError: returnError,
            returnValue: returnValue
        )
    }
}

// MARK: - Combine Convenience

extension MockFunctionBuilder {
    func thenReturn<Element>(_ value: [Element]) where R == AnyPublisher<[Element], Never> {
        returnValue = Just(value)
            .setFailureType(to: Never.self)
            .eraseToAnyPublisher()
    }
    
    func thenReturn<Element>(_ value: [Element]) where R == AnyPublisher<[Element], Error> {
        returnValue = Just(value)
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
    
    func thenReturn<Element>(_ value: Set<Element>) where R == AnyPublisher<Set<Element>, Never> {
        returnValue = Just(value)
            .setFailureType(to: Never.self)
            .eraseToAnyPublisher()
    }
    
    func thenReturn<Element>(_ value: Set<Element>) where R == AnyPublisher<Set<Element>, Error> {
        returnValue = Just(value)
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
}

// MARK: - DependenciesSettable

protocol DependenciesSettable {
    var dependencies: Dependencies { get }
    
    func setDependencies(_ dependencies: Dependencies?)
}

// MARK: - FunctionConsumer

internal class FunctionConsumer: MockFunctionHandler {
    struct Key: Equatable, Hashable {
        let name: String
        let paramCount: Int
    }
    
    var trackCalls: Bool = true
    var functionBuilders: [() throws -> MockFunction?] = []
    var functionHandlers: [Key: [String: MockFunction]] = [:]
    var calls: Atomic<[Key: [CallDetails]]> = Atomic([:])
    
    private func getExpectation(
        _ functionName: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        args: [Any?],
        untrackedArgs: [Any?]
    ) -> MockFunction {
        let key: Key = Key(name: functionName, paramCount: parameterCount)
        
        if !functionBuilders.isEmpty {
            functionBuilders
                .compactMap { try? $0() }
                .forEach { function in
                    let key: Key = Key(name: function.name, paramCount: function.parameterCount)
                    var updatedHandlers: [String: MockFunction] = (functionHandlers[key] ?? [:])
                    
                    // Add the actual 'parameterSummary' value for the handlers (override any
                    // existing entries
                    updatedHandlers[function.parameterSummary] = function
                    
                    // Upsert entries for all remaining combinations (assume we want to
                    // overwrite any existing entries)
                    function.allParameterSummaryCombinations.forEach { combination in
                        updatedHandlers[combination.summary] = function
                    }
                    
                    functionHandlers[key] = updatedHandlers
                }
            
            functionBuilders.removeAll()
        }
        
        guard let expectation: MockFunction = firstFunction(for: key, matchingParameterSummaryIfPossible: parameterSummary, allParameterSummaryCombinations: allParameterSummaryCombinations) else {
            preconditionFailure("No expectations found for \(functionName)")
        }
        
        // Record the call so it can be validated later (assuming we are tracking calls)
        if trackCalls {
            calls.mutate {
                $0[key] = ($0[key] ?? []).appending(
                    CallDetails(
                        parameterSummary: parameterSummary,
                        allParameterSummaryCombinations: allParameterSummaryCombinations
                    )
                )
            }
        }
        
        for action in expectation.actions {
            action(args, untrackedArgs)
        }
        
        return expectation
    }
    
    func mock<Output>(
        _ functionName: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        args: [Any?],
        untrackedArgs: [Any?]
    ) -> Output {
        let expectation: MockFunction = getExpectation(
            functionName,
            parameterCount: parameterCount,
            parameterSummary: parameterSummary,
            allParameterSummaryCombinations: allParameterSummaryCombinations,
            args: args,
            untrackedArgs: untrackedArgs
        )
        
        switch expectation.returnValue {
            case .some(let value as Output): return value
            case .some(let value as (any Numeric)):
                guard
                    let numericType: (any Numeric.Type) = Output.self as? any Numeric.Type,
                    let convertedValue: Output = convertNumeric(value, to: numericType) as? Output
                else { return (expectation.returnValue as! Output) }
                
                return convertedValue
            
            default: return (expectation.returnValue as! Output)
        }
    }
    
    func mockNoReturn(
        _ functionName: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        args: [Any?],
        untrackedArgs: [Any?]
    ) {
        _ = getExpectation(
            functionName,
            parameterCount: parameterCount,
            parameterSummary: parameterSummary,
            allParameterSummaryCombinations: allParameterSummaryCombinations,
            args: args,
            untrackedArgs: untrackedArgs
        )
    }
    
    func mockThrowing<Output>(
        _ functionName: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        args: [Any?],
        untrackedArgs: [Any?]
    ) throws -> Output {
        let expectation: MockFunction = getExpectation(
            functionName,
            parameterCount: parameterCount,
            parameterSummary: parameterSummary,
            allParameterSummaryCombinations: allParameterSummaryCombinations,
            args: args,
            untrackedArgs: untrackedArgs
        )

        switch (expectation.returnError, expectation.returnValue) {
            case (.some(let error), _): throw error
            case (_, .some(let value as Output)): return value
            case (_, .some(let value as (any Numeric))):
                guard
                    let numericType: (any Numeric.Type) = Output.self as? any Numeric.Type,
                    let convertedValue: Output = convertNumeric(value, to: numericType) as? Output
                else { throw MockError.mockedData }
                
                return convertedValue
            
            default: return try Optional<Any>.none as? Output ?? { throw MockError.mockedData }()
        }
    }
    
    func mockThrowingNoReturn(
        _ functionName: String,
        parameterCount: Int,
        parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination],
        args: [Any?],
        untrackedArgs: [Any?]
    ) throws {
        let expectation: MockFunction = getExpectation(
            functionName,
            parameterCount: parameterCount,
            parameterSummary: parameterSummary,
            allParameterSummaryCombinations: allParameterSummaryCombinations,
            args: args,
            untrackedArgs: untrackedArgs
        )

        switch expectation.returnError {
            case .some(let error): throw error
            default: return
        }
    }
    
    func firstFunction(
        for key: Key,
        matchingParameterSummaryIfPossible parameterSummary: String,
        allParameterSummaryCombinations: [ParameterCombination]
    ) -> MockFunction? {
        guard let possibleExpectations: [String: MockFunction] = functionHandlers[key] else { return nil }
        
        guard let expectation: MockFunction = possibleExpectations[parameterSummary] else {
            // We didn't find an exact match so try to find the match with the most matching parameters,
            // do this by sorting based on the largest param count and checking if there is a match
            let maybeExpectation: MockFunction? = allParameterSummaryCombinations
                .sorted(by: { lhs, rhs in lhs.count > rhs.count })
                .compactMap { combination in possibleExpectations[combination.summary] }
                .first
            
            if let expectation: MockFunction = maybeExpectation {
                return expectation
            }
            
            // A `nil` response might be value but in a lot of places we will need to force-cast
            // so try to find a non-nil response first
            return (
                possibleExpectations.values.first(where: { $0.returnValue != nil }) ??
                possibleExpectations.values.first
            )
        }
        
        return expectation
    }
}

// MARK: - Conversion Convenience

private extension MockFunctionHandler {
    func convertNumeric(_ value: Any, to type: any Numeric.Type) -> (any Numeric)? {
        switch (value, type) {
            case (let x as any BinaryInteger, is Int64.Type): return Int64(x)
            case (let x as any BinaryInteger, is Int32.Type): return Int32(x)
            case (let x as any BinaryInteger, is Int16.Type): return Int16(x)
            case (let x as any BinaryInteger, is Int8.Type): return Int8(x)
            case (let x as any BinaryInteger, is Int.Type): return Int(x)
            case (let x as any BinaryInteger, is UInt64.Type): return UInt64(x)
            case (let x as any BinaryInteger, is UInt32.Type): return UInt32(x)
            case (let x as any BinaryInteger, is UInt16.Type): return UInt16(x)
            case (let x as any BinaryInteger, is UInt8.Type): return UInt8(x)
            case (let x as any BinaryInteger, is UInt.Type): return UInt(x)
            case (let x as any BinaryInteger, is Float.Type): return Float(x)
            case (let x as any BinaryInteger, is Double.Type): return Double(x)
            case (let x as any BinaryInteger, is TimeInterval.Type): return TimeInterval(x)
                
            case (let x as any BinaryFloatingPoint, is Int64.Type): return Int64(x)
            case (let x as any BinaryFloatingPoint, is Int32.Type): return Int32(x)
            case (let x as any BinaryFloatingPoint, is Int16.Type): return Int16(x)
            case (let x as any BinaryFloatingPoint, is Int8.Type): return Int8(x)
            case (let x as any BinaryFloatingPoint, is Int.Type): return Int(x)
            case (let x as any BinaryFloatingPoint, is UInt64.Type): return UInt64(x)
            case (let x as any BinaryFloatingPoint, is UInt32.Type): return UInt32(x)
            case (let x as any BinaryFloatingPoint, is UInt16.Type): return UInt16(x)
            case (let x as any BinaryFloatingPoint, is UInt8.Type): return UInt8(x)
            case (let x as any BinaryFloatingPoint, is UInt.Type): return UInt(x)
            case (let x as any BinaryFloatingPoint, is Float.Type): return Float(x)
            case (let x as any BinaryFloatingPoint, is Double.Type): return Double(x)
            case (let x as any BinaryFloatingPoint, is TimeInterval.Type): return TimeInterval(x)
            
            default: return nil
        }
    }
}

// MARK: - CustomArgSummaryDescribable

protocol CustomArgSummaryDescribable {
    var customArgSummaryDescribable: String? { get }
}
