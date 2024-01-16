// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import SessionMessagingKit
import SessionUtilitiesKit

enum MockDataGenerator {
    // MARK: - Generation
        
    static var printProgress: Bool = true
    static var hasStartedGenerationThisRun: Bool = false
    
    static func generateMockData(_ db: Database, dependencies: Dependencies = Dependencies()) {
        // Don't re-generate the mock data if it already exists
        guard !hasStartedGenerationThisRun && !(try! SessionThread.exists(db, id: "MockDatabaseThread")) else {
            hasStartedGenerationThisRun = true
            return
        }
        
        /// The mock data generation is quite slow, there are 3 parts which take a decent amount of time (deleting the account afterwards will
        /// also take a long time):
        ///     Generating the threads & content - ~3s per 100
        ///     Writing to the database - ~10s per 1000
        ///     Updating the UI - ~10s per 1000
        let dmThreadCount: Int = 1000
        let closedGroupThreadCount: Int = 50
        let openGroupThreadCount: Int = 20
        let messageRangePerThread: [ClosedRange<Int>] = [(0...500)]
        let dmRandomSeed: Int = 1111
        let cgRandomSeed: Int = 2222
        let ogRandomSeed: Int = 3333
        let chunkSize: Int = 1000    // Chunk up the thread writing to prevent memory issues
        let stringContent: [String] = "abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789 ".map { String($0) }
        let wordContent: [String] = ["alias", "consequatur", "aut", "perferendis", "sit", "voluptatem", "accusantium", "doloremque", "aperiam", "eaque", "ipsa", "quae", "ab", "illo", "inventore", "veritatis", "et", "quasi", "architecto", "beatae", "vitae", "dicta", "sunt", "explicabo", "aspernatur", "aut", "odit", "aut", "fugit", "sed", "quia", "consequuntur", "magni", "dolores", "eos", "qui", "ratione", "voluptatem", "sequi", "nesciunt", "neque", "dolorem", "ipsum", "quia", "dolor", "sit", "amet", "consectetur", "adipisci", "velit", "sed", "quia", "non", "numquam", "eius", "modi", "tempora", "incidunt", "ut", "labore", "et", "dolore", "magnam", "aliquam", "quaerat", "voluptatem", "ut", "enim", "ad", "minima", "veniam", "quis", "nostrum", "exercitationem", "ullam", "corporis", "nemo", "enim", "ipsam", "voluptatem", "quia", "voluptas", "sit", "suscipit", "laboriosam", "nisi", "ut", "aliquid", "ex", "ea", "commodi", "consequatur", "quis", "autem", "vel", "eum", "iure", "reprehenderit", "qui", "in", "ea", "voluptate", "velit", "esse", "quam", "nihil", "molestiae", "et", "iusto", "odio", "dignissimos", "ducimus", "qui", "blanditiis", "praesentium", "laudantium", "totam", "rem", "voluptatum", "deleniti", "atque", "corrupti", "quos", "dolores", "et", "quas", "molestias", "excepturi", "sint", "occaecati", "cupiditate", "non", "provident", "sed", "ut", "perspiciatis", "unde", "omnis", "iste", "natus", "error", "similique", "sunt", "in", "culpa", "qui", "officia", "deserunt", "mollitia", "animi", "id", "est", "laborum", "et", "dolorum", "fuga", "et", "harum", "quidem", "rerum", "facilis", "est", "et", "expedita", "distinctio", "nam", "libero", "tempore", "cum", "soluta", "nobis", "est", "eligendi", "optio", "cumque", "nihil", "impedit", "quo", "porro", "quisquam", "est", "qui", "minus", "id", "quod", "maxime", "placeat", "facere", "possimus", "omnis", "voluptas", "assumenda", "est", "omnis", "dolor", "repellendus", "temporibus", "autem", "quibusdam", "et", "aut", "consequatur", "vel", "illum", "qui", "dolorem", "eum", "fugiat", "quo", "voluptas", "nulla", "pariatur", "at", "vero", "eos", "et", "accusamus", "officiis", "debitis", "aut", "rerum", "necessitatibus", "saepe", "eveniet", "ut", "et", "voluptates", "repudiandae", "sint", "et", "molestiae", "non", "recusandae", "itaque", "earum", "rerum", "hic", "tenetur", "a", "sapiente", "delectus", "ut", "aut", "reiciendis", "voluptatibus", "maiores", "doloribus", "asperiores", "repellat"]
        let timestampNow: TimeInterval = Date().timeIntervalSince1970
        let userSessionId: SessionId = getUserSessionId(db)
        let logProgress: (String, String) -> () = { title, event in
            guard printProgress else { return }
            
            print("[MockDataGenerator] (\(Date().timeIntervalSince1970)) \(title) - \(event)")
        }
        
        hasStartedGenerationThisRun = true
        
        // FIXME: Make sure this data doesn't go off device somehow?
        logProgress("", "Start")
        
        // First create the thread used to indicate that the mock data has been generated
        _ = try? SessionThread.fetchOrCreate(
            db,
            id: "MockDatabaseThread",
            variant: .contact,
            shouldBeVisible: false,
            calledFromConfigHandling: false
        )
        
        // MARK: - -- DM Thread
        
        var dmThreadRandomGenerator: ARC4RandomNumberGenerator = ARC4RandomNumberGenerator(seed: dmRandomSeed)
        var dmThreadIndex: Int = 0
        logProgress("DM Threads", "Start Generating \(dmThreadCount) threads")
        
        while dmThreadIndex < dmThreadCount {
            let remainingThreads: Int = (dmThreadCount - dmThreadIndex)
            
            (0..<min(chunkSize, remainingThreads)).forEach { index in
                let threadIndex: Int = (dmThreadIndex + index)
                
                logProgress("DM Thread \(threadIndex)", "Start")
            
                let data: Data = Data(dmThreadRandomGenerator.nextBytes(count: 16))
                let randomSessionId: String = SessionId(.standard, publicKey: try! Identity.generate(from: data).x25519KeyPair.publicKey).hexString
                let isMessageRequest: Bool = Bool.random(using: &dmThreadRandomGenerator)
                let contactNameLength: Int = ((5..<20).randomElement(using: &dmThreadRandomGenerator) ?? 0)
                let numMessages: Int = (messageRangePerThread[threadIndex % messageRangePerThread.count]
                    .randomElement(using: &dmThreadRandomGenerator) ?? 0)
                
                // Generate the thread
                let thread: SessionThread = try! SessionThread
                    .fetchOrCreate(
                        db,
                        id: randomSessionId,
                        variant: .contact,
                        shouldBeVisible: true,
                        calledFromConfigHandling: false
                    )
                
                // Generate the contact
                let contact: Contact = try! Contact(
                    id: randomSessionId,
                    isTrusted: true,
                    isApproved: (!isMessageRequest || Bool.random(using: &dmThreadRandomGenerator)),
                    isBlocked: false,
                    didApproveMe: (
                        !isMessageRequest &&
                        (((0..<10).randomElement(using: &dmThreadRandomGenerator) ?? 0) < 8) // 80% approved the current user
                    ),
                    hasBeenBlocked: false
                )
                .upserted(db)
                try! Profile(
                    id: randomSessionId,
                    name: (0..<contactNameLength)
                        .compactMap { _ in stringContent.randomElement(using: &dmThreadRandomGenerator) }
                        .joined()
                )
                .upserted(db)
                
                // Generate the message history (Note: Unapproved message requests will only include incoming messages)
                logProgress("DM Thread \(threadIndex)", "Generate \(numMessages) Messages")
                (0..<numMessages).forEach { index in
                    let isIncoming: Bool = (
                        Bool.random(using: &dmThreadRandomGenerator) &&
                        (!isMessageRequest || contact.isApproved)
                    )
                    let messageWords: Int = ((1..<20).randomElement(using: &dmThreadRandomGenerator) ?? 0)
                    
                    _ = try! Interaction(
                        threadId: thread.id,
                        authorId: (isIncoming ? randomSessionId : userSessionId.hexString),
                        variant: (isIncoming ? .standardIncoming : .standardOutgoing),
                        body: (0..<messageWords)
                            .compactMap { _ in wordContent.randomElement(using: &dmThreadRandomGenerator) }
                            .joined(separator: " "),
                        timestampMs: Int64(floor(timestampNow - Double(index * 5)) * 1000)
                    )
                    .inserted(db)
                }
                
                logProgress("DM Thread \(threadIndex)", "Done")
            }
            logProgress("DM Threads", "Done")
            
            dmThreadIndex += chunkSize
        }
        logProgress("DM Threads", "Done")
            
        // MARK: - -- Closed Group
        
        var cgThreadRandomGenerator: ARC4RandomNumberGenerator = ARC4RandomNumberGenerator(seed: cgRandomSeed)
        var cgThreadIndex: Int = 0
        logProgress("Closed Group Threads", "Start Generating \(closedGroupThreadCount) threads")
            
        while cgThreadIndex < closedGroupThreadCount {
            let remainingThreads: Int = (closedGroupThreadCount - cgThreadIndex)
            
            (0..<min(chunkSize, remainingThreads)).forEach { index in
                let threadIndex: Int = (cgThreadIndex + index)
                
                logProgress("Closed Group Thread \(threadIndex)", "Start")
                
                let data: Data = Data(cgThreadRandomGenerator.nextBytes(count: 16))
                let randomLegacyGroupPublicKey: String = SessionId(.standard, publicKey: try! Identity.generate(from: data).x25519KeyPair.publicKey).hexString
                let groupNameLength: Int = ((5..<20).randomElement(using: &cgThreadRandomGenerator) ?? 0)
                let groupName: String = (0..<groupNameLength)
                    .compactMap { _ in stringContent.randomElement(using: &cgThreadRandomGenerator) }
                    .joined()
                let numGroupMembers: Int = ((0..<10).randomElement(using: &cgThreadRandomGenerator) ?? 0)
                let numMessages: Int = (messageRangePerThread[threadIndex % messageRangePerThread.count]
                    .randomElement(using: &cgThreadRandomGenerator) ?? 0)
                
                // Generate the Contacts in the group
                var members: [String] = [userSessionId.hexString]
                logProgress("Closed Group Thread \(threadIndex)", "Generate \(numGroupMembers) Contacts")
                
                (0..<numGroupMembers).forEach { _ in
                    let contactData: Data = Data(cgThreadRandomGenerator.nextBytes(count: 16))
                    let randomSessionId: String = SessionId(.standard, publicKey: try! Identity.generate(from: contactData).x25519KeyPair.publicKey).hexString
                    let contactNameLength: Int = ((5..<20).randomElement(using: &cgThreadRandomGenerator) ?? 0)
                    
                    try! Contact(
                        id: randomSessionId,
                        isTrusted: true,
                        isApproved: true,
                        isBlocked: false,
                        didApproveMe: true,
                        hasBeenBlocked: false
                    )
                    .upserted(db)
                    try! Profile(
                        id: randomSessionId,
                        name: (0..<contactNameLength)
                            .compactMap { _ in stringContent.randomElement(using: &cgThreadRandomGenerator) }
                            .joined()
                    )
                    .upserted(db)
                    
                    members.append(randomSessionId)
                }
                
                let thread: SessionThread = try! SessionThread
                    .fetchOrCreate(
                        db,
                        id: randomLegacyGroupPublicKey,
                        variant: .legacyGroup,
                        shouldBeVisible: true,
                        calledFromConfigHandling: false
                    )
                try! ClosedGroup(
                    threadId: randomLegacyGroupPublicKey,
                    name: groupName,
                    formationTimestamp: timestampNow,
                    shouldPoll: true,
                    invited: false
                )
                .upserted(db)
                
                members.forEach { memberId in
                    try! GroupMember(
                        groupId: randomLegacyGroupPublicKey,
                        profileId: memberId,
                        role: .standard,
                        roleStatus: .accepted,  // Legacy group members don't have role statuses
                        isHidden: false
                    )
                    .upsert(db)
                }
                [members.randomElement(using: &cgThreadRandomGenerator) ?? userSessionId.hexString].forEach { adminId in
                    try! GroupMember(
                        groupId: randomLegacyGroupPublicKey,
                        profileId: adminId,
                        role: .admin,
                        roleStatus: .accepted,  // Legacy group members don't have role statuses
                        isHidden: false
                    )
                    .upsert(db)
                }
                
                // Add the group to the user's set of public keys to poll for and store the key pair
                let encryptionKeyPair = dependencies[singleton: .crypto].generate(.x25519KeyPair())!
                try! ClosedGroupKeyPair(
                    threadId: randomLegacyGroupPublicKey,
                    publicKey: Data(encryptionKeyPair.publicKey),
                    secretKey: Data(encryptionKeyPair.secretKey),
                    receivedTimestamp: timestampNow
                )
                .upsert(db)
                
                // Generate the message history (Note: Unapproved message requests will only include incoming messages)
                logProgress("Closed Group Thread \(threadIndex)", "Generate \(numMessages) Messages")
                
                (0..<numMessages).forEach { index in
                    let messageWords: Int = ((1..<20).randomElement(using: &cgThreadRandomGenerator) ?? 0)
                    let senderId: String = (members.randomElement(using: &cgThreadRandomGenerator) ?? userSessionId.hexString)
                    
                    _ = try! Interaction(
                        threadId: thread.id,
                        authorId: senderId,
                        variant: (senderId != userSessionId.hexString ? .standardIncoming : .standardOutgoing),
                        body: (0..<messageWords)
                            .compactMap { _ in wordContent.randomElement(using: &cgThreadRandomGenerator) }
                            .joined(separator: " "),
                        timestampMs: Int64(floor(timestampNow - Double(index * 5)) * 1000)
                    )
                    .inserted(db)
                }
                
                logProgress("Closed Group Thread \(threadIndex)", "Done")
            }
            
            cgThreadIndex += chunkSize
        }
        logProgress("Closed Group Threads", "Done")
        
        // MARK: - --Open Group
        
        var ogThreadRandomGenerator: ARC4RandomNumberGenerator = ARC4RandomNumberGenerator(seed: ogRandomSeed)
        var ogThreadIndex: Int = 0
        logProgress("Open Group Threads", "Start Generating \(openGroupThreadCount) threads")
            
        while ogThreadIndex < openGroupThreadCount {
            let remainingThreads: Int = (openGroupThreadCount - ogThreadIndex)
            
            (0..<min(chunkSize, remainingThreads)).forEach { index in
                let threadIndex: Int = (ogThreadIndex + index)
                    
                logProgress("Open Group Thread \(threadIndex)", "Start")
                
                let randomGroupPublicKey: String = ((0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &dmThreadRandomGenerator) }).toHexString()
                let serverNameLength: Int = ((5..<20).randomElement(using: &ogThreadRandomGenerator) ?? 0)
                let roomNameLength: Int = ((5..<20).randomElement(using: &ogThreadRandomGenerator) ?? 0)
                let roomDescriptionLength: Int = ((10..<50).randomElement(using: &ogThreadRandomGenerator) ?? 0)
                let serverName: String = (0..<serverNameLength)
                    .compactMap { _ in stringContent.randomElement(using: &ogThreadRandomGenerator) }
                    .joined()
                let roomName: String = (0..<roomNameLength)
                    .compactMap { _ in stringContent.randomElement(using: &ogThreadRandomGenerator) }
                    .joined()
                let roomDescription: String = (0..<roomDescriptionLength)
                    .compactMap { _ in stringContent.randomElement(using: &ogThreadRandomGenerator) }
                    .joined()
                let numGroupMembers: Int64 = ((0..<250).randomElement(using: &ogThreadRandomGenerator) ?? 0)
                let numMessages: Int = (messageRangePerThread[threadIndex % messageRangePerThread.count]
                    .randomElement(using: &ogThreadRandomGenerator) ?? 0)
                
                // Generate the Contacts in the group
                var members: [String] = [userSessionId.hexString]
                logProgress("Open Group Thread \(threadIndex)", "Generate \(numGroupMembers) Contacts")

                (0..<numGroupMembers).forEach { _ in
                    let contactData: Data = Data(ogThreadRandomGenerator.nextBytes(count: 16))
                    let randomSessionId: String = SessionId(.standard, publicKey: try! Identity.generate(from: contactData).x25519KeyPair.publicKey).hexString
                    let contactNameLength: Int = ((5..<20).randomElement(using: &ogThreadRandomGenerator) ?? 0)
                    try! Contact(
                        id: randomSessionId,
                        isTrusted: true,
                        isApproved: true,
                        isBlocked: false,
                        didApproveMe: true,
                        hasBeenBlocked: false
                    )
                    .upserted(db)
                    try! Profile(
                        id: randomSessionId,
                        name: (0..<contactNameLength)
                            .compactMap { _ in stringContent.randomElement(using: &ogThreadRandomGenerator) }
                            .joined()
                    )
                    .upserted(db)

                    members.append(randomSessionId)
                }
                
                // Create the open group model and the thread
                let thread: SessionThread = try! SessionThread
                    .fetchOrCreate(
                        db,
                        id: randomGroupPublicKey,
                        variant: .community,
                        shouldBeVisible: true,
                        calledFromConfigHandling: false
                    )
                try! OpenGroup(
                    server: serverName,
                    roomToken: roomName,
                    publicKey: randomGroupPublicKey,
                    isActive: true,
                    name: roomName,
                    roomDescription: roomDescription,
                    userCount: numGroupMembers,
                    infoUpdates: 0,
                    sequenceNumber: 0,
                    inboxLatestMessageId: 0,
                    outboxLatestMessageId: 0
                )
                .upserted(db)
                
                // Generate the capabilities object
                let hasBlinding: Bool = Bool.random(using: &dmThreadRandomGenerator)
                
                try! Capability(
                    openGroupServer: serverName.lowercased(),
                    variant: .sogs,
                    isMissing: false
                ).upserted(db)
                
                if hasBlinding {
                    try! Capability(
                        openGroupServer: serverName.lowercased(),
                        variant: .blind,
                        isMissing: false
                    ).upserted(db)
                }
                
                // Generate the message history (Note: Unapproved message requests will only include incoming messages)
                logProgress("Open Group Thread \(threadIndex)", "Generate \(numMessages) Messages")

                (0..<numMessages).forEach { index in
                    let messageWords: Int = ((1..<20).randomElement(using: &ogThreadRandomGenerator) ?? 0)
                    let senderId: String = (members.randomElement(using: &ogThreadRandomGenerator) ?? userSessionId.hexString)
                    
                    _ = try! Interaction(
                        threadId: thread.id,
                        authorId: senderId,
                        variant: (senderId != userSessionId.hexString ? .standardIncoming : .standardOutgoing),
                        body: (0..<messageWords)
                            .compactMap { _ in wordContent.randomElement(using: &ogThreadRandomGenerator) }
                            .joined(separator: " "),
                        timestampMs: Int64(floor(timestampNow - Double(index * 5)) * 1000)
                    )
                    .inserted(db)
                }

                logProgress("Open Group Thread \(threadIndex)", "Done")
            }
            
            ogThreadIndex += chunkSize
        }
        
        logProgress("Open Group Threads", "Done")
        logProgress("", "Complete")
    }
}
