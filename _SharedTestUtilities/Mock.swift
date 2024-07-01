// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

// MARK: - MockError

public enum MockError: Error {
    case mockedData
}

// MARK: - Mock<T>

public class Mock<T> {
    private let functionHandler: MockFunctionHandler
    internal let functionConsumer: FunctionConsumer
    
    // MARK: - Initialization
    
    internal required init(
        functionHandler: MockFunctionHandler? = nil,
        initialSetup: ((Mock<T>) -> ())? = nil
    ) {
        self.functionConsumer = FunctionConsumer()
        self.functionHandler = (functionHandler ?? self.functionConsumer)
        initialSetup?(self)
    }
    
    // MARK: - MockFunctionHandler
    
    @discardableResult internal func accept(funcName: String = #function, args: [Any?] = []) -> Any? {
        return accept(funcName: funcName, checkArgs: args, actionArgs: args)
    }
    
    @discardableResult internal func accept(funcName: String = #function, checkArgs: [Any?], actionArgs: [Any?]) -> Any? {
        return functionHandler.accept(
            funcName,
            parameterCount: checkArgs.count,
            parameterSummary: summary(for: checkArgs),
            actionArgs: actionArgs
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
                
            default: return String(reflecting: argument)    // Default to the `debugDescription` if available
        }
    }
}

// MARK: - MockFunctionHandler

protocol MockFunctionHandler {
    func accept(_ functionName: String, parameterCount: Int, parameterSummary: String, actionArgs: [Any?]) -> Any?
}

// MARK: - MockFunction

internal class MockFunction {
    var name: String
    var parameterCount: Int
    var parameterSummary: String
    var actions: [([Any?]) -> Void]
    var returnValue: Any?
    
    init(name: String, parameterCount: Int, parameterSummary: String, actions: [([Any?]) -> Void], returnValue: Any?) {
        self.name = name
        self.parameterCount = parameterCount
        self.parameterSummary = parameterSummary
        self.actions = actions
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
    private var actions: [([Any?]) -> Void] = []
    private var returnValue: R?
    internal var returnValueGenerator: ((String, Int, String) -> R?)?
    
    // MARK: - Initialization
    
    init(_ callBlock: @escaping (inout T) throws -> R, mockInit: @escaping (MockFunctionHandler?, ((Mock<T>) -> ())?) -> Mock<T>) {
        self.callBlock = callBlock
        self.mockInit = mockInit
    }
    
    // MARK: - Behaviours
    
    @discardableResult func then(_ block: @escaping ([Any?]) -> Void) -> MockFunctionBuilder<T, R> {
        actions.append(block)
        return self
    }
    
    func thenReturn(_ value: R?) {
        returnValue = value
    }
    
    // MARK: - MockFunctionHandler
    
    func accept(_ functionName: String, parameterCount: Int, parameterSummary: String, actionArgs: [Any?]) -> Any? {
        self.functionName = functionName
        self.parameterCount = parameterCount
        self.parameterSummary = parameterSummary
        return (returnValue ?? returnValueGenerator?(functionName, parameterCount, parameterSummary))
    }
    
    // MARK: - Build
    
    func build() throws -> MockFunction {
        var completionMock = mockInit(self, nil) as! T
        _ = try? callBlock(&completionMock)
        
        guard let name: String = functionName, let parameterCount: Int = parameterCount, let parameterSummary: String = parameterSummary else {
            preconditionFailure("Attempted to build the MockFunction before it was called")
        }
        
        return MockFunction(name: name, parameterCount: parameterCount, parameterSummary: parameterSummary, actions: actions, returnValue: returnValue)
    }
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
    var calls: Atomic<[Key: [String]]> = Atomic([:])
    
    func accept(_ functionName: String, parameterCount: Int, parameterSummary: String, actionArgs: [Any?]) -> Any? {
        let key: Key = Key(name: functionName, paramCount: parameterCount)
        
        if !functionBuilders.isEmpty {
            functionBuilders
                .compactMap { try? $0() }
                .forEach { function in
                    let key: Key = Key(name: function.name, paramCount: function.parameterCount)
                    
                    functionHandlers[key] = (functionHandlers[key] ?? [:])
                        .setting(function.parameterSummary, function)
                }
            
            functionBuilders.removeAll()
        }
        
        guard let expectation: MockFunction = firstFunction(for: key, matchingParameterSummaryIfPossible: parameterSummary) else {
            preconditionFailure("No expectations found for \(functionName)")
        }
        
        // Record the call so it can be validated later (assuming we are tracking calls)
        if trackCalls {
            calls.mutate { $0[key] = ($0[key] ?? []).appending(parameterSummary) }
        }
        
        for action in expectation.actions {
            action(actionArgs)
        }

        return expectation.returnValue
    }
    
    func firstFunction(for key: Key, matchingParameterSummaryIfPossible parameterSummary: String) -> MockFunction? {
        guard let possibleExpectations: [String: MockFunction] = functionHandlers[key] else { return nil }
        
        guard let expectation: MockFunction = possibleExpectations[parameterSummary] else {
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

// MARK: - CustomArgSummaryDescribable

protocol CustomArgSummaryDescribable {
    var customArgSummaryDescribable: String? { get }
}
