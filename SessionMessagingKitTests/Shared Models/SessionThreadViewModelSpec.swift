// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import Quick
import Nimble
import SessionUtilitiesKit

@testable import SessionMessagingKit

class SessionThreadViewModelSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState(singleton: .storage, in: dependencies) var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            using: dependencies,
            initialData: { db in
                try db.create(table: TestMessage.self) { t in
                    t.column(.body, .text).notNull()
                }
                
                try db.create(virtualTable: TestMessage.fullTextSearchTableName, using: FTS5()) { t in
                    t.synchronize(withTable: TestMessage.databaseTableName)
                    t.tokenizer = .porter(wrapping: .unicode61())
                    
                    t.column(TestMessage.Columns.body.name)
                }
            }
        )
        
        // MARK: - a SessionThreadViewModel
        describe("a SessionThreadViewModel") {
            // MARK: -- when processing a search term
            context("when processing a search term") {
                // MARK: ---- correctly generates a safe search term
                it("correctly generates a safe search term") {
                    expect(SessionThreadViewModel.searchSafeTerm("Test")).to(equal("\"Test\""))
                }
                
                // MARK: ---- standardises odd quote characters
                it("standardises odd quote characters") {
                    expect(SessionThreadViewModel.standardQuotes("\"")).to(equal("\""))
                    expect(SessionThreadViewModel.standardQuotes("”")).to(equal("\""))
                    expect(SessionThreadViewModel.standardQuotes("“")).to(equal("\""))
                }
                
                // MARK: ---- splits on the space character
                it("splits on the space character") {
                    expect(SessionThreadViewModel.searchTermParts("Test Message"))
                        .to(equal([
                            "\"Test\"",
                            "\"Message\""
                        ]))
                }
                
                // MARK: ---- surrounds each split term with quotes
                it("surrounds each split term with quotes") {
                    expect(SessionThreadViewModel.searchTermParts("Test Message"))
                        .to(equal([
                            "\"Test\"",
                            "\"Message\""
                        ]))
                }
                
                // MARK: ---- keeps words within quotes together
                it("keeps words within quotes together") {
                    expect(SessionThreadViewModel.searchTermParts("This ”is a Test“ Message"))
                        .to(equal([
                            "\"This\"",
                            "\"is a Test\"",
                            "\"Message\""
                        ]))
                    expect(SessionThreadViewModel.searchTermParts("\"This is\" a Test Message"))
                        .to(equal([
                            "\"This is\"",
                            "\"a\"",
                            "\"Test\"",
                            "\"Message\""
                        ]))
                    expect(SessionThreadViewModel.searchTermParts("\"This is\" \"a Test\" Message"))
                        .to(equal([
                            "\"This is\"",
                            "\"a Test\"",
                            "\"Message\""
                        ]))
                    expect(SessionThreadViewModel.searchTermParts("\"This is\" a \"Test Message\""))
                        .to(equal([
                            "\"This is\"",
                            "\"a\"",
                            "\"Test Message\""
                        ]))
                    expect(SessionThreadViewModel.searchTermParts("\"This is\"\" a \"Test Message"))
                        .to(equal([
                            "\"This is\"",
                            "\" a \"",
                            "\"Test\"",
                            "\"Message\""
                        ]))
                }
                
                // MARK: ---- keeps words within weird quotes together
                it("keeps words within weird quotes together") {
                    expect(SessionThreadViewModel.searchTermParts("This \"is a Test\" Message"))
                        .to(equal([
                            "\"This\"",
                            "\"is a Test\"",
                            "\"Message\""
                        ]))
                }
                
                // MARK: ---- removes extra whitespace
                it("removes extra whitespace") {
                    expect(SessionThreadViewModel.searchTermParts("  Test         Message     "))
                        .to(equal([
                            "\"Test\"",
                            "\"Message\""
                        ]))
                }
            }
            
            // MARK: -- when searching
            context("when searching") {
                beforeEach {
                    mockStorage.write { db in
                        try TestMessage(body: "Test").insert(db)
                        try TestMessage(body: "Test123").insert(db)
                        try TestMessage(body: "Test234").insert(db)
                        try TestMessage(body: "Test Test123").insert(db)
                        try TestMessage(body: "Test Test123 Test234").insert(db)
                        try TestMessage(body: "Test Test234").insert(db)
                        try TestMessage(body: "Test Test234 Test123").insert(db)
                        try TestMessage(body: "This is a Test Message").insert(db)
                        try TestMessage(body: "is a Message This Test").insert(db)
                        try TestMessage(body: "this message is a test").insert(db)
                        try TestMessage(
                            body: "This content is something which includes a combination of test words found in another message"
                        )
                        .insert(db)
                        try TestMessage(body: "Do test messages contain content?").insert(db)
                        try TestMessage(body: "Is messaging awesome?").insert(db)
                    }
                }
                
                // MARK: ---- returns results
                it("returns results") {
                    let results = mockStorage.read { db in
                        let pattern: FTS5Pattern = try SessionThreadViewModel.pattern(
                            db,
                            searchTerm: "Message",
                            forTable: TestMessage.self
                        )
                        
                        return try SQLRequest<TestMessage>(literal: """
                        SELECT *
                        FROM testMessage
                        JOIN testMessage_fts ON (
                            testMessage_fts.rowId = testMessage.rowId AND
                            testMessage_fts.body MATCH \(pattern)
                        )
                        """).fetchAll(db)
                    }
                    
                    expect(results)
                        .to(equal([
                            TestMessage(body: "This is a Test Message"),
                            TestMessage(body: "is a Message This Test"),
                            TestMessage(body: "this message is a test"),
                            TestMessage(body: "This content is something which includes a combination of test words found in another message"),
                            TestMessage(body: "Do test messages contain content?"),
                            TestMessage(body: "Is messaging awesome?")
                        ]))
                }
                
                // MARK: ---- adds a wildcard to the final part
                it("adds a wildcard to the final part") {
                    let results = mockStorage.read { db in
                        let pattern: FTS5Pattern = try SessionThreadViewModel.pattern(
                            db,
                            searchTerm: "This mes",
                            forTable: TestMessage.self
                        )
                        
                        return try SQLRequest<TestMessage>(literal: """
                        SELECT *
                        FROM testMessage
                        JOIN testMessage_fts ON (
                            testMessage_fts.rowId = testMessage.rowId AND
                            testMessage_fts.body MATCH \(pattern)
                        )
                        """).fetchAll(db)
                    }
                    
                    expect(results)
                        .to(equal([
                            TestMessage(body: "This is a Test Message"),
                            TestMessage(body: "is a Message This Test"),
                            TestMessage(body: "this message is a test"),
                            TestMessage(body: "This content is something which includes a combination of test words found in another message"),
                            TestMessage(body: "Do test messages contain content?"),
                            TestMessage(body: "Is messaging awesome?")
                        ]))
                }
                
                // MARK: ---- does not add a wildcard to other parts
                it("does not add a wildcard to other parts") {
                    let results = mockStorage.read { db in
                        let pattern: FTS5Pattern = try SessionThreadViewModel.pattern(
                            db,
                            searchTerm: "mes Random",
                            forTable: TestMessage.self
                        )
                        
                        return try SQLRequest<TestMessage>(literal: """
                        SELECT *
                        FROM testMessage
                        JOIN testMessage_fts ON (
                            testMessage_fts.rowId = testMessage.rowId AND
                            testMessage_fts.body MATCH \(pattern)
                        )
                        """).fetchAll(db)
                    }
                    
                    expect(results)
                        .to(beEmpty())
                }
                
                // MARK: ---- finds similar words without the wildcard due to the porter tokenizer
                it("finds similar words without the wildcard due to the porter tokenizer") {
                    let results = mockStorage.read { db in
                        let pattern: FTS5Pattern = try SessionThreadViewModel.pattern(
                            db,
                            searchTerm: "message z",
                            forTable: TestMessage.self
                        )
                        
                        return try SQLRequest<TestMessage>(literal: """
                        SELECT *
                        FROM testMessage
                        JOIN testMessage_fts ON (
                            testMessage_fts.rowId = testMessage.rowId AND
                            testMessage_fts.body MATCH \(pattern)
                        )
                        """).fetchAll(db)
                    }
                    
                    expect(results)
                        .to(equal([
                            TestMessage(body: "This is a Test Message"),
                            TestMessage(body: "is a Message This Test"),
                            TestMessage(body: "this message is a test"),
                            TestMessage(
                                body: "This content is something which includes a combination of test words found in another message"
                            ),
                            TestMessage(body: "Do test messages contain content?"),
                            TestMessage(body: "Is messaging awesome?")
                        ]))
                }
                
                // MARK: ---- finds results containing the words regardless of the order
                it("finds results containing the words regardless of the order") {
                    let results = mockStorage.read { db in
                        let pattern: FTS5Pattern = try SessionThreadViewModel.pattern(
                            db,
                            searchTerm: "is a message",
                            forTable: TestMessage.self
                        )
                        
                        return try SQLRequest<TestMessage>(literal: """
                        SELECT *
                        FROM testMessage
                        JOIN testMessage_fts ON (
                            testMessage_fts.rowId = testMessage.rowId AND
                            testMessage_fts.body MATCH \(pattern)
                        )
                        """).fetchAll(db)
                    }
                    
                    expect(results)
                        .to(equal([
                            TestMessage(body: "This is a Test Message"),
                            TestMessage(body: "is a Message This Test"),
                            TestMessage(body: "this message is a test"),
                            TestMessage(
                                body: "This content is something which includes a combination of test words found in another message"
                            ),
                            TestMessage(body: "Do test messages contain content?"),
                            TestMessage(body: "Is messaging awesome?")
                        ]))
                }
                
                // MARK: ---- does not find quoted parts out of order
                it("does not find quoted parts out of order") {
                    let results = mockStorage.read { db in
                        let pattern: FTS5Pattern = try SessionThreadViewModel.pattern(
                            db,
                            searchTerm: "\"this is a\" \"test message\"",
                            forTable: TestMessage.self
                        )
                        
                        return try SQLRequest<TestMessage>(literal: """
                        SELECT *
                        FROM testMessage
                        JOIN testMessage_fts ON (
                            testMessage_fts.rowId = testMessage.rowId AND
                            testMessage_fts.body MATCH \(pattern)
                        )
                        """).fetchAll(db)
                    }
                    
                    expect(results)
                        .to(equal([
                            TestMessage(body: "This is a Test Message"),
                            TestMessage(body: "Do test messages contain content?")
                        ]))
                }
            }
        }
    }
}

// MARK: - Test Types

fileprivate struct TestMessage: Codable, Equatable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "testMessage" }
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case body
    }
    
    public let body: String
}
