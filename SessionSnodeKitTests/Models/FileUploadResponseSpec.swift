// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionSnodeKit

class FileUploadResponseSpec: QuickSpec {
    override class func spec() {
        // MARK: - a FileUploadResponse
        describe("a FileUploadResponse") {
            // MARK: -- when decoding
            context("when decoding") {
                // MARK: ---- handles a string id value
                it("handles a string id value") {
                    let jsonData: Data = "{\"id\":\"123\"}".data(using: .utf8)!
                    let response: FileUploadResponse? = try? JSONDecoder().decode(FileUploadResponse.self, from: jsonData)
                    
                    expect(response?.id).to(equal("123"))
                }
                
                // MARK: ---- handles an int id value
                it("handles an int id value") {
                    let jsonData: Data = "{\"id\":124}".data(using: .utf8)!
                    let response: FileUploadResponse? = try? JSONDecoder().decode(FileUploadResponse.self, from: jsonData)
                    
                    expect(response?.id).to(equal("124"))
                }
            }
        }
    }
}
