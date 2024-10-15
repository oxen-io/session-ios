// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionMessagingKit

class SOGSErrorSpec: QuickSpec {
    override class func spec() {
        // MARK: - a SOGSError
        describe("a SOGSError") {
            // MARK: -- generates the error description correctly
            it("generates the error description correctly") {
                expect(OpenGroupAPIError.decryptionFailed.description).to(equal("Couldn't decrypt response."))
                expect(OpenGroupAPIError.signingFailed.description).to(equal("Couldn't sign message."))
                expect(OpenGroupAPIError.noPublicKey.description).to(equal("Couldn't find server public key."))
                expect(OpenGroupAPIError.invalidEmoji.description).to(equal("The emoji is invalid."))
                expect(OpenGroupAPIError.invalidPoll.description).to(equal("Poller in invalid state."))
            }
        }
    }
}
