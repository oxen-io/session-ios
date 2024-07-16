// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionMessagingKit

class OpenGroupSpec: QuickSpec {
    override class func spec() {
        // MARK: - an Open Group
        describe("an Open Group") {
            // MARK: -- when initializing
            context("when initializing") {
                // MARK: ---- generates the id
                it("generates the id") {
                    let openGroup: OpenGroup = OpenGroup(
                        server: "server",
                        roomToken: "room",
                        publicKey: "1234",
                        isActive: true,
                        name: "name",
                        roomDescription: nil,
                        imageId: nil,
                        userCount: 0,
                        infoUpdates: 0,
                        sequenceNumber: 0,
                        inboxLatestMessageId: 0,
                        outboxLatestMessageId: 0
                    )
                    
                    expect(openGroup.id).to(equal("server.room"))
                }
            }
            
            // MARK: -- when describing
            context("when describing") {
                // MARK: ---- includes relevant information
                it("includes relevant information") {
                    let openGroup: OpenGroup = OpenGroup(
                        server: "server",
                        roomToken: "room",
                        publicKey: "1234",
                        isActive: true,
                        name: "name",
                        roomDescription: nil,
                        imageId: nil,
                        userCount: 0,
                        infoUpdates: 0,
                        sequenceNumber: 0,
                        inboxLatestMessageId: 0,
                        outboxLatestMessageId: 0
                    )
                    
                    expect(openGroup.description)
                        .to(equal("name (Server: server, Room: room)"))
                }
            }
            
            // MARK: -- when describing in debug
            context("when describing in debug") {
                // MARK: ---- includes relevant information
                it("includes relevant information") {
                    let openGroup: OpenGroup = OpenGroup(
                        server: "server",
                        roomToken: "room",
                        publicKey: "1234",
                        isActive: true,
                        name: "name",
                        roomDescription: nil,
                        imageId: nil,
                        userCount: 0,
                        infoUpdates: 0,
                        sequenceNumber: 0,
                        inboxLatestMessageId: 0,
                        outboxLatestMessageId: 0
                    )
                    
                    expect(openGroup.debugDescription)
                        .to(equal("""
                        OpenGroup(
                            server: \"server\",
                            roomToken: \"room\",
                            id: \"server.room\",
                            publicKey: \"1234\",
                            isActive: true,
                            name: \"name\",
                            roomDescription: null,
                            imageId: null,
                            userCount: 0,
                            infoUpdates: 0,
                            sequenceNumber: 0,
                            inboxLatestMessageId: 0,
                            outboxLatestMessageId: 0,
                            pollFailureCount: 0,
                            permissions: ---,
                            displayPictureFilename: null,
                            lastDisplayPictureUpdate: 0.0
                        )
                        """))
                }
            }
            
            // MARK: -- when generating an id
            context("when generating an id") {
                // MARK: ---- generates correctly
                it("generates correctly") {
                    expect(OpenGroup.idFor(roomToken: "room", server: "server")).to(equal("server.room"))
                }
                
                // MARK: ---- converts the server to lowercase
                it("converts the server to lowercase") {
                    expect(OpenGroup.idFor(roomToken: "room", server: "SeRVeR")).to(equal("server.room"))
                }
                
                // MARK: ---- maintains the casing of the roomToken
                it("maintains the casing of the roomToken") {
                    expect(OpenGroup.idFor(roomToken: "RoOM", server: "server")).to(equal("server.RoOM"))
                }
            }
        }
    }
}
