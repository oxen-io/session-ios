// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

// MARK: - Mocked

protocol Mocked { static var mockValue: Self { get } }
protocol MockedGeneric {
    associatedtype Generic
    
    static func mockValue(type: Generic.Type) -> Self
}
protocol MockedDoubleGeneric {
    associatedtype GenericA
    associatedtype GenericB
    
    static func mockValue(typeA: GenericA.Type, typeB: GenericB.Type) -> Self
}

// MARK: - DSL

func any<R: Mocked>() -> R { R.mockValue }
func any<R: MockedGeneric>(type: R.Generic.Type) -> R { R.mockValue(type: type) }
func any<R: MockedDoubleGeneric>(typeA: R.GenericA.Type, typeB: R.GenericB.Type) -> R {
    R.mockValue(typeA: typeA, typeB: typeB)
}
func any<R: FixedWidthInteger>() -> R { unsafeBitCast(0, to: R.self) }
func any<K: Hashable, V>() -> [K: V] { [:] }
func any() -> Float { 0 }
func any() -> Double { 0 }
func any() -> String { "" }
func any() -> Data { Data() }
func any() -> Bool { false }
func any() -> Dependencies {
    let result: Dependencies = Dependencies(
        storage: nil,
        network: MockNetwork(),
        crypto: MockCrypto(),
        standardUserDefaults: MockUserDefaults(),
        caches: MockCaches(),
        jobRunner: MockJobRunner(),
        scheduler: .immediate,
        dateNow: Date(timeIntervalSince1970: 1234567890),
        fixedTime: 0,
        forceSynchronous: true
    )
    let storage: SynchronousStorage = SynchronousStorage(customWriter: try! DatabaseQueue(), using: result)
    result.storage = storage
    
    return result
}

func anyAny() -> Any { 0 }              // Unique name for compilation performance reasons
func anyArray<R>() -> [R] { [] }        // Unique name for compilation performance reasons
func anySet<R>() -> Set<R> { Set() }    // Unique name for compilation performance reasons

// MARK: - Extensions

extension Network.BatchSubResponse: MockedGeneric where T: Mocked {
    typealias Generic = T
    
    static func mockValue(type: Generic.Type) -> Network.BatchSubResponse<Generic> {
        return Network.BatchSubResponse(
            code: 200,
            headers: [:],
            body: Generic.mockValue,
            failedToParseBody: false
        )
    }
}

extension Network.BatchSubResponse {
    static func mockArrayValue<M: Mocked>(type: M.Type) -> Network.BatchSubResponse<Array<M>> {
        return Network.BatchSubResponse(
            code: 200,
            headers: [:],
            body: [M.mockValue],
            failedToParseBody: false
        )
    }
}

// MARK: - Encodable Convenience

extension Mocked where Self: Encodable {
    func encoded() -> Data { try! JSONEncoder().with(outputFormatting: .sortedKeys).encode(self) }
}

extension MockedGeneric where Self: Encodable {
    func encoded() -> Data { try! JSONEncoder().with(outputFormatting: .sortedKeys).encode(self) }
}

extension Array where Element: Encodable {
    func encoded() -> Data { try! JSONEncoder().with(outputFormatting: .sortedKeys).encode(self) }
}
