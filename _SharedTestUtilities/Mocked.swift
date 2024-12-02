// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import UIKit.UIApplication
import Combine
import GRDB
import SessionUtilitiesKit

// MARK: - Mocked

protocol Mocked { static var mock: Self { get } }
protocol MockedGeneric {
    associatedtype Generic
    
    static func mock(type: Generic.Type) -> Self
}
protocol MockedDoubleGeneric {
    associatedtype GenericA
    associatedtype GenericB
    
    static func mock(typeA: GenericA.Type, typeB: GenericB.Type) -> Self
}

// MARK: - DSL

/// Needs to be a function as you can't extend 'Any'
func anyAny() -> Any { 0 }

extension Mocked { static var any: Self { mock } }

extension Int: Mocked { static var mock: Int { 0 } }
extension Int64: Mocked { static var mock: Int64 { 0 } }
extension Dictionary: Mocked { static var mock: Self { [:] } }
extension Array: Mocked { static var mock: Self { [] } }
extension Set: Mocked { static var mock: Self { [] } }
extension Float: Mocked { static var mock: Float { 0 } }
extension Double: Mocked { static var mock: Double { 0 } }
extension String: Mocked { static var mock: String { "" } }
extension Data: Mocked { static var mock: Data { Data() } }
extension Bool: Mocked { static var mock: Bool { false } }
extension UnsafeMutablePointer<ObjCBool>?: Mocked { static var mock: UnsafeMutablePointer<ObjCBool>? { nil } }

// The below types either can't be mocked or use the 'MockedGeneric' or 'MockedDoubleGeneric' types
// so need their own direct 'any' values

extension Error { static var any: Error { TestError.mock } }

extension UIApplication.State { static var any: UIApplication.State { .active } }
extension TimeInterval { static var any: TimeInterval { 0 } }
extension SessionId { static var any: SessionId { SessionId.invalid } }
extension Dependencies {
    static var any: Dependencies {
        TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
            dependencies.forceSynchronous = true
        }
    }
}

// MARK: - Conformance

extension Database: Mocked {
    static var mock: Database {
        var result: Database!
        try! DatabaseQueue().read { result = $0 }
        return result!
    }
}

extension URLRequest: Mocked {
    static var mock: URLRequest = URLRequest(url: URL(fileURLWithPath: "mock"))
}

extension AnyPublisher: MockedGeneric where Failure == Error {
    typealias Generic = Output
    
    static func any(type: Output.Type) -> AnyPublisher<Output, Error> { mock(type: type) }
    
    static func mock(type: Output.Type) -> AnyPublisher<Output, Error> {
        return Fail(error: MockError.mockedData).eraseToAnyPublisher()
    }
}

extension KeyPair: Mocked {
    static var mock: KeyPair = KeyPair(
        publicKey: Data(hex: TestConstants.publicKey).bytes,
        secretKey: Data(hex: TestConstants.edSecretKey).bytes
    )
}

extension Job: Mocked {
    static var mock: Job = Job(variant: .mock)
}

extension Job.Variant: Mocked {
    static var mock: Job.Variant = .messageSend
}

extension JobRunner.JobResult: Mocked {
    static var mock: JobRunner.JobResult = .succeeded
}

extension FileProtectionType: Mocked {
    static var mock: FileProtectionType = .complete
}

// MARK: - Encodable Convenience

extension Mocked where Self: Encodable {
    func encoded(using dependencies: Dependencies) -> Data {
        try! JSONEncoder(using: dependencies).with(outputFormatting: .sortedKeys).encode(self)
    }
}

extension MockedGeneric where Self: Encodable {
    func encoded(using dependencies: Dependencies) -> Data {
        try! JSONEncoder(using: dependencies).with(outputFormatting: .sortedKeys).encode(self)
    }
}

extension Array where Element: Encodable {
    func encoded(using dependencies: Dependencies) -> Data {
        try! JSONEncoder(using: dependencies).with(outputFormatting: .sortedKeys).encode(self)
    }
}
