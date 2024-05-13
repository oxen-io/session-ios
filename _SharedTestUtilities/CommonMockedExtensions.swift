// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import Sodium
import Curve25519Kit
import SessionUtilitiesKit

extension KeyPair: Mocked {
    static var mockValue: KeyPair = KeyPair(
        publicKey: Data(hex: TestConstants.publicKey).bytes,
        secretKey: Data(hex: TestConstants.edSecretKey).bytes
    )
}

extension ECKeyPair: Mocked {
    static var mockValue: Self {
        try! Self.init(
            publicKeyData: Data(hex: TestConstants.publicKey),
            privateKeyData: Data(hex: TestConstants.privateKey)
        )
    }
}

extension Database: Mocked {
    static var mockValue: Database {
        var result: Database!
        try! DatabaseQueue().read { result = $0 }
        return result!
    }
}

extension Job: Mocked {
    static var mockValue: Job = Job(variant: .messageSend)
}

extension Job.Variant: Mocked {
    static var mockValue: Job.Variant = .messageSend
}

extension Network.RequestType: MockedGeneric {
    typealias Generic = T
    
    static func mockValue(type: T.Type) -> Network.RequestType<T> {
        return Network.RequestType(id: "mock") { _ in Fail(error: MockError.mockedData).eraseToAnyPublisher() }
    }
}

extension AnyPublisher: MockedGeneric where Failure == Error {
    typealias Generic = Output
    
    static func mockValue(type: Output.Type) -> AnyPublisher<Output, Error> {
        return Fail(error: MockError.mockedData).eraseToAnyPublisher()
    }
}

extension Array: MockedGeneric {
    typealias Generic = Element
    
    static func mockValue(type: Element.Type) -> [Element] { return [] }
}

extension Dictionary: MockedDoubleGeneric {
    typealias GenericA = Key
    typealias GenericB = Value
    
    static func mockValue(typeA: Key.Type, typeB: Value.Type) -> [Key: Value] { return [:] }
}

extension URLRequest: Mocked {
    static var mockValue: URLRequest = URLRequest(url: URL(fileURLWithPath: "mock"))
}

extension NoResponse: Mocked {
    static var mockValue: NoResponse = NoResponse()
}
