// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionUtilitiesKit

class BencodeEncoderSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies()
        
        // MARK: - BencodeEncoder
        describe("BencodeEncoder") {
            // MARK: ---- should decode a basic string
            it("should decode a basic string") {
                let result: Data? = try? BencodeEncoder(using: dependencies).encode("howdy")
                
                expect(result).to(equal("5:howdy".data(using: .utf8)!))
            }
            
            // MARK: ---- should decode a basic integer
            it("should decode a basic integer") {
                let result: Data? = try? BencodeEncoder(using: dependencies).encode(3)
                
                expect(result).to(equal("i3e".data(using: .utf8)!))
            }
            
            // MARK: ---- should decode a list of integers
            it("should decode a list of integers") {
                let result: Data? = try? BencodeEncoder(using: dependencies).encode([1, 2])
                
                expect(result).to(equal("li1ei2ee".data(using: .utf8)!))
            }
            
            // MARK: ---- should decode a basic dict
            it("should decode a basic dict") {
                let result: Data? = try? BencodeEncoder(using: dependencies).encode(["spam": ["a", "b"]])
                
                expect(result).to(equal("d4:spaml1:a1:bee".data(using: .utf8)!))
            }
            
            // MARK: ---- decodes a decodable type
            it("decodes a decodable type") {
                let result: Data? = try? BencodeEncoder(using: dependencies).encode(TestType(intValue: 100, stringValue: "Test"))
                
                expect(result).to(equal("d8:intValuei100e11:stringValue4:Teste".data(using: .utf8)!))
            }
        }
    }
}

// MARK: - Test Types

fileprivate struct TestType: Codable, Equatable {
    let intValue: Int
    let stringValue: String
}
