// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import Sodium
import SessionUtil
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

class LibSessionUtilSpec: QuickSpec {
    override class func spec() {
        // MARK: - libSession
        describe("libSession") {
            contactsSpec()
            userProfileSpec()
            convoInfoVolatileSpec()
            userGroupsSpec()
            
            // MARK: -- parses community URLs correctly
            it("parses community URLs correctly") {
                let result1 = LibSession.parseCommunity(url: [
                    "https://example.com/",
                    "SomeRoom?public_key=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
                ].joined())
                let result2 = LibSession.parseCommunity(url: [
                    "HTTPS://EXAMPLE.COM/",
                    "sOMErOOM?public_key=0123456789aBcdEF0123456789abCDEF0123456789ABCdef0123456789ABCDEF"
                ].joined())
                let result3 = LibSession.parseCommunity(url: [
                    "HTTPS://EXAMPLE.COM/r/",
                    "someroom?public_key=0123456789aBcdEF0123456789abCDEF0123456789ABCdef0123456789ABCDEF"
                ].joined())
                let result4 = LibSession.parseCommunity(url: [
                    "http://example.com/r/",
                    "someroom?public_key=0123456789aBcdEF0123456789abCDEF0123456789ABCdef0123456789ABCDEF"
                ].joined())
                let result5 = LibSession.parseCommunity(url: [
                    "HTTPS://EXAMPLE.com:443/r/",
                    "someroom?public_key=0123456789aBcdEF0123456789abCDEF0123456789ABCdef0123456789ABCDEF"
                ].joined())
                let result6 = LibSession.parseCommunity(url: [
                    "HTTP://EXAMPLE.com:80/r/",
                    "someroom?public_key=0123456789aBcdEF0123456789abCDEF0123456789ABCdef0123456789ABCDEF"
                ].joined())
                let result7 = LibSession.parseCommunity(url: [
                    "http://example.com:80/r/",
                    "someroom?public_key=ASNFZ4mrze8BI0VniavN7wEjRWeJq83vASNFZ4mrze8"
                ].joined())
                let result8 = LibSession.parseCommunity(url: [
                    "http://example.com:80/r/",
                    "someroom?public_key=yrtwk3hjixg66yjdeiuauk6p7hy1gtm8tgih55abrpnsxnpm3zzo"
                ].joined())
                
                expect(result1?.server).to(equal("https://example.com"))
                expect(result1?.server).to(equal(result2?.server))
                expect(result1?.server).to(equal(result3?.server))
                expect(result1?.server).toNot(equal(result4?.server))
                expect(result4?.server).to(equal("http://example.com"))
                expect(result1?.server).to(equal(result5?.server))
                expect(result4?.server).to(equal(result6?.server))
                expect(result4?.server).to(equal(result7?.server))
                expect(result4?.server).to(equal(result8?.server))
                expect(result1?.room).to(equal("SomeRoom"))
                expect(result2?.room).to(equal("sOMErOOM"))
                expect(result3?.room).to(equal("someroom"))
                expect(result4?.room).to(equal("someroom"))
                expect(result5?.room).to(equal("someroom"))
                expect(result6?.room).to(equal("someroom"))
                expect(result7?.room).to(equal("someroom"))
                expect(result8?.room).to(equal("someroom"))
                expect(result1?.publicKey)
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
                expect(result2?.publicKey)
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
                expect(result3?.publicKey)
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
                expect(result4?.publicKey)
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
                expect(result5?.publicKey)
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
                expect(result6?.publicKey)
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
                expect(result7?.publicKey)
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
                expect(result8?.publicKey)
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
            }
        }
    }
}

// MARK: - CONTACTS

fileprivate extension LibSessionUtilSpec {
    enum ContactProperty: CaseIterable {
        case name
        case nickname
        case approved
        case approved_me
        case blocked
        case profile_pic
        case created
        case notifications
        case mute_until
        case priority
        case exp_mode
        case exp_seconds
    }

    class func contactsSpec() {
        context("CONTACTS") {
            // MARK: -- when checking error catching
            context("when checking error catching") {
                var seed: Data!
                var identity: (ed25519KeyPair: KeyPair, x25519KeyPair: KeyPair)!
                var edSK: [UInt8]!
                var error: UnsafeMutablePointer<CChar>?
                var conf: UnsafeMutablePointer<config_object>?
                
                beforeEach {
                    seed = Data(hex: "0123456789abcdef0123456789abcdef")
                    
                    // FIXME: Would be good to move these into the libSession-util instead of using Sodium separately
                    identity = try! Identity.generate(from: seed)
                    edSK = identity.ed25519KeyPair.secretKey
                    
                    // Initialize a brand new, empty config because we have no dump data to deal with.
                    error = nil
                    conf = nil
                    _ = contacts_init(&conf, &edSK, nil, 0, error)
                    error?.deallocate()
                }
                
                // MARK: ---- it can catch size limit errors thrown when pushing
                it("can catch size limit errors thrown when pushing") {
                    var randomGenerator: ARC4RandomNumberGenerator = ARC4RandomNumberGenerator(seed: 1000)
                    
                    try (0..<10000).forEach { index in
                        var contact: contacts_contact = try createContact(
                            for: index,
                            in: conf,
                            rand: &randomGenerator,
                            maxing: .allProperties
                        )
                        contacts_set(conf, &contact)
                    }
                    
                    expect(contacts_size(conf)).to(equal(10000))
                    expect(config_needs_push(conf)).to(beTrue())
                    expect(config_needs_dump(conf)).to(beTrue())
                    
                    expect {
                        config_push(conf)?.deallocate()
                        try LibSessionError.throwIfNeeded(conf)
                    }
                    .to(throwError(LibSessionError.libSessionError("Config data is too large.")))
                }
            }
            
            // MARK: -- when checking size limits
            context("when checking size limits") {
                var numRecords: Int!
                var seed: Data!
                var identity: (ed25519KeyPair: KeyPair, x25519KeyPair: KeyPair)!
                var edSK: [UInt8]!
                var error: UnsafeMutablePointer<CChar>?
                var conf: UnsafeMutablePointer<config_object>?
                
                beforeEach {
                    numRecords = 0
                    seed = Data(hex: "0123456789abcdef0123456789abcdef")
                    
                    // FIXME: Would be good to move these into the libSession-util instead of using Sodium separately
                    identity = try! Identity.generate(from: seed)
                    edSK = identity.ed25519KeyPair.secretKey
                    
                    // Initialize a brand new, empty config because we have no dump data to deal with.
                    error = nil
                    conf = nil
                    _ = contacts_init(&conf, &edSK, nil, 0, error)
                    error?.deallocate()
                }
                
                // MARK: ---- has not changed the max empty records
                it("has not changed the max empty records") {
                    var randomGenerator: ARC4RandomNumberGenerator = ARC4RandomNumberGenerator(seed: 1000)
                    
                    for index in (0..<100000) {
                        var contact: contacts_contact = try createContact(
                            for: index,
                            in: conf,
                            rand: &randomGenerator
                        )
                        contacts_set(conf, &contact)
                        
                        do {
                            config_push(conf)?.deallocate()
                            try LibSessionError.throwIfNeeded(conf)
                        }
                        catch { break }
                        
                        // We successfully inserted a contact and didn't hit the limit so increment the counter
                        numRecords += 1
                    }
                    
                    // Check that the record count matches the maximum when we last checked
                    expect(numRecords).to(equal(2212))
                }
                
                // MARK: ---- has not changed the max name only records
                it("has not changed the max name only records") {
                    var randomGenerator: ARC4RandomNumberGenerator = ARC4RandomNumberGenerator(seed: 1000)
                    
                    for index in (0..<100000) {
                        var contact: contacts_contact = try createContact(
                            for: index,
                            in: conf,
                            rand: &randomGenerator,
                            maxing: [.name]
                        )
                        contacts_set(conf, &contact)
                        
                        do {
                            config_push(conf)?.deallocate()
                            try LibSessionError.throwIfNeeded(conf)
                        }
                        catch { break }
                        
                        // We successfully inserted a contact and didn't hit the limit so increment the counter
                        numRecords += 1
                    }
                    
                    // Check that the record count matches the maximum when we last checked
                    expect(numRecords).to(equal(742))
                }
                
                // MARK: ---- has not changed the max name and profile pic only records
                it("has not changed the max name and profile pic only records") {
                    var randomGenerator: ARC4RandomNumberGenerator = ARC4RandomNumberGenerator(seed: 1000)
                    
                    for index in (0..<100000) {
                        var contact: contacts_contact = try createContact(
                            for: index,
                            in: conf,
                            rand: &randomGenerator,
                            maxing: [.name, .profile_pic]
                        )
                        contacts_set(conf, &contact)
                        
                        do {
                            config_push(conf)?.deallocate()
                            try LibSessionError.throwIfNeeded(conf)
                        }
                        catch { break }
                        
                        // We successfully inserted a contact and didn't hit the limit so increment the counter
                        numRecords += 1
                    }
                    
                    // Check that the record count matches the maximum when we last checked
                    expect(numRecords).to(equal(274))
                }
                
                // MARK: ---- has not changed the max filled records
                it("has not changed the max filled records") {
                    var randomGenerator: ARC4RandomNumberGenerator = ARC4RandomNumberGenerator(seed: 1000)
                    
                    for index in (0..<100000) {
                        var contact: contacts_contact = try createContact(
                            for: index,
                            in: conf,
                            rand: &randomGenerator,
                            maxing: .allProperties
                        )
                        contacts_set(conf, &contact)
                        
                        do {
                            config_push(conf)?.deallocate()
                            try LibSessionError.throwIfNeeded(conf)
                        }
                        catch { break }
                        
                        // We successfully inserted a contact and didn't hit the limit so increment the counter
                        numRecords += 1
                    }
                    
                    // Check that the record count matches the maximum when we last checked (seems to swap between
                    // these two on different test runs for some reason)
                    expect(numRecords).to(satisfyAnyOf(equal(222), equal(223)))
                }
            }
            
            // MARK: -- generates config correctly
            
            it("generates config correctly") {
                let createdTs: Int64 = 1680064059
                let nowTs: Int64 = Int64(Date().timeIntervalSince1970)
                let seed: Data = Data(hex: "0123456789abcdef0123456789abcdef")
                
                // FIXME: Would be good to move these into the libSession-util instead of using Sodium separately
                let identity = try! Identity.generate(from: seed)
                var edSK: [UInt8] = identity.ed25519KeyPair.secretKey
                expect(edSK.toHexString().suffix(64))
                    .to(equal("4cb76fdc6d32278e3f83dbf608360ecc6b65727934b85d2fb86862ff98c46ab7"))
                expect(identity.x25519KeyPair.publicKey.toHexString())
                    .to(equal("d2ad010eeb72d72e561d9de7bd7b6989af77dcabffa03a5111a6c859ae5c3a72"))
                expect(String(edSK.toHexString().prefix(32))).to(equal(seed.toHexString()))
                
                // Initialize a brand new, empty config because we have no dump data to deal with.
                let error: UnsafeMutablePointer<CChar>? = nil
                var conf: UnsafeMutablePointer<config_object>? = nil
                expect(contacts_init(&conf, &edSK, nil, 0, error)).to(equal(0))
                error?.deallocate()
                
                // Empty contacts shouldn't have an existing contact
                let definitelyRealId: String = "050000000000000000000000000000000000000000000000000000000000000000"
                var cDefinitelyRealId: [CChar] = definitelyRealId.cString(using: .utf8)!
                let contactPtr: UnsafeMutablePointer<contacts_contact>? = nil
                expect(contacts_get(conf, contactPtr, &cDefinitelyRealId)).to(beFalse())
                
                expect(contacts_size(conf)).to(equal(0))
                
                var contact2: contacts_contact = contacts_contact()
                expect(contacts_get_or_construct(conf, &contact2, &cDefinitelyRealId)).to(beTrue())
                expect(String(libSessionVal: contact2.name)).to(beEmpty())
                expect(String(libSessionVal: contact2.nickname)).to(beEmpty())
                expect(contact2.approved).to(beFalse())
                expect(contact2.approved_me).to(beFalse())
                expect(contact2.blocked).to(beFalse())
                expect(contact2.profile_pic).toNot(beNil()) // Creates an empty instance apparently
                expect(String(libSessionVal: contact2.profile_pic.url)).to(beEmpty())
                expect(contact2.created).to(equal(0))
                expect(contact2.notifications).to(equal(CONVO_NOTIFY_DEFAULT))
                expect(contact2.mute_until).to(equal(0))
                
                expect(config_needs_push(conf)).to(beFalse())
                expect(config_needs_dump(conf)).to(beFalse())
                
                let pushData1: UnsafeMutablePointer<config_push_data> = config_push(conf)
                expect(pushData1.pointee.seqno).to(equal(0))
                pushData1.deallocate()
                
                // Update the contact data
                contact2.name = "Joe".toLibSession()
                contact2.nickname = "Joey".toLibSession()
                contact2.approved = true
                contact2.approved_me = true
                contact2.created = createdTs
                contact2.notifications = CONVO_NOTIFY_ALL
                contact2.mute_until = nowTs + 1800
                
                // Update the contact
                contacts_set(conf, &contact2)
                
                // Ensure the contact details were updated
                var contact3: contacts_contact = contacts_contact()
                expect(contacts_get(conf, &contact3, &cDefinitelyRealId)).to(beTrue())
                expect(String(libSessionVal: contact3.name)).to(equal("Joe"))
                expect(String(libSessionVal: contact3.nickname)).to(equal("Joey"))
                expect(contact3.approved).to(beTrue())
                expect(contact3.approved_me).to(beTrue())
                expect(contact3.profile_pic).toNot(beNil()) // Creates an empty instance apparently
                expect(String(libSessionVal: contact3.profile_pic.url)).to(beEmpty())
                expect(contact3.blocked).to(beFalse())
                expect(String(libSessionVal: contact3.session_id)).to(equal(definitelyRealId))
                expect(contact3.created).to(equal(createdTs))
                expect(contact2.notifications).to(equal(CONVO_NOTIFY_ALL))
                expect(contact2.mute_until).to(equal(nowTs + 1800))
                
                
                // Since we've made changes, we should need to push new config to the swarm, *and* should need
                // to dump the updated state:
                expect(config_needs_push(conf)).to(beTrue())
                expect(config_needs_dump(conf)).to(beTrue())
                
                // incremented since we made changes (this only increments once between
                // dumps; even though we changed multiple fields here).
                let pushData2: UnsafeMutablePointer<config_push_data> = config_push(conf)
                
                // incremented since we made changes (this only increments once between
                // dumps; even though we changed multiple fields here).
                expect(pushData2.pointee.seqno).to(equal(1))
                
                // Pretend we uploaded it
                let fakeHash1: String = "fakehash1"
                var cFakeHash1: [CChar] = fakeHash1.cString(using: .utf8)!
                config_confirm_pushed(conf, pushData2.pointee.seqno, &cFakeHash1)
                expect(config_needs_push(conf)).to(beFalse())
                expect(config_needs_dump(conf)).to(beTrue())
                pushData2.deallocate()
                
                // NB: Not going to check encrypted data and decryption here because that's general (not
                // specific to contacts) and is covered already in the user profile tests.
                var dump1: UnsafeMutablePointer<UInt8>? = nil
                var dump1Len: Int = 0
                config_dump(conf, &dump1, &dump1Len)
                
                let error2: UnsafeMutablePointer<CChar>? = nil
                var conf2: UnsafeMutablePointer<config_object>? = nil
                expect(contacts_init(&conf2, &edSK, dump1, dump1Len, error2)).to(equal(0))
                error2?.deallocate()
                dump1?.deallocate()
                
                expect(config_needs_push(conf2)).to(beFalse())
                expect(config_needs_dump(conf2)).to(beFalse())
                
                let pushData3: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData3.pointee.seqno).to(equal(1))
                pushData3.deallocate()
                
                // Because we just called dump() above, to load up contacts2
                expect(config_needs_dump(conf)).to(beFalse())
                
                // Ensure the contact details were updated
                var contact4: contacts_contact = contacts_contact()
                expect(contacts_get(conf2, &contact4, &cDefinitelyRealId)).to(beTrue())
                expect(String(libSessionVal: contact4.name)).to(equal("Joe"))
                expect(String(libSessionVal: contact4.nickname)).to(equal("Joey"))
                expect(contact4.approved).to(beTrue())
                expect(contact4.approved_me).to(beTrue())
                expect(contact4.profile_pic).toNot(beNil()) // Creates an empty instance apparently
                expect(String(libSessionVal: contact4.profile_pic.url)).to(beEmpty())
                expect(contact4.blocked).to(beFalse())
                expect(contact4.created).to(equal(createdTs))
                
                let anotherId: String = "051111111111111111111111111111111111111111111111111111111111111111"
                var cAnotherId: [CChar] = anotherId.cString(using: .utf8)!
                var contact5: contacts_contact = contacts_contact()
                expect(contacts_get_or_construct(conf2, &contact5, &cAnotherId)).to(beTrue())
                expect(String(libSessionVal: contact5.name)).to(beEmpty())
                expect(String(libSessionVal: contact5.nickname)).to(beEmpty())
                expect(contact5.approved).to(beFalse())
                expect(contact5.approved_me).to(beFalse())
                expect(contact5.profile_pic).toNot(beNil()) // Creates an empty instance apparently
                expect(String(libSessionVal: contact5.profile_pic.url)).to(beEmpty())
                expect(contact5.blocked).to(beFalse())
                
                // We're not setting any fields, but we should still keep a record of the session id
                contacts_set(conf2, &contact5)
                expect(config_needs_push(conf2)).to(beTrue())
                
                let pushData4: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData4.pointee.seqno).to(equal(2))
                
                // Check the merging
                let fakeHash2: String = "fakehash2"
                var cFakeHash2: [CChar] = fakeHash2.cString(using: .utf8)!
                var mergeHashes: [UnsafePointer<CChar>?] = ((try? [cFakeHash2].unsafeCopyCStringArray()) ?? [])
                var mergeData: [UnsafePointer<UInt8>?] = [UnsafePointer(pushData4.pointee.config)]
                var mergeSize: [Int] = [pushData4.pointee.config_len]
                let mergedHashes: UnsafeMutablePointer<config_string_list>? = config_merge(conf, &mergeHashes, &mergeData, &mergeSize, 1)
                expect([String](pointer: mergedHashes?.pointee.value, count: mergedHashes?.pointee.len))
                    .to(equal(["fakehash2"]))
                config_confirm_pushed(conf2, pushData4.pointee.seqno, &cFakeHash2)
                mergeHashes.forEach { $0?.deallocate() }
                mergedHashes?.deallocate()
                pushData4.deallocate()
                
                expect(config_needs_push(conf)).to(beFalse())
                
                let pushData5: UnsafeMutablePointer<config_push_data> = config_push(conf)
                expect(pushData5.pointee.seqno).to(equal(2))
                pushData5.deallocate()
                
                // Iterate through and make sure we got everything we expected
                var sessionIds: [String] = []
                var nicknames: [String] = []
                expect(contacts_size(conf)).to(equal(2))
                
                var contact6: contacts_contact = contacts_contact()
                let contactIterator: UnsafeMutablePointer<contacts_iterator> = contacts_iterator_new(conf)
                while !contacts_iterator_done(contactIterator, &contact6) {
                    sessionIds.append(String(libSessionVal: contact6.session_id))
                    nicknames.append(String(libSessionVal: contact6.nickname, nullIfEmpty: true) ?? "(N/A)")
                    contacts_iterator_advance(contactIterator)
                }
                contacts_iterator_free(contactIterator) // Need to free the iterator
                
                expect(sessionIds.count).to(equal(2))
                expect(sessionIds.count).to(equal(contacts_size(conf)))
                expect(sessionIds.first).to(equal(definitelyRealId))
                expect(sessionIds.last).to(equal(anotherId))
                expect(nicknames.first).to(equal("Joey"))
                expect(nicknames.last).to(equal("(N/A)"))
                
                // Conflict! Oh no!
                
                // On client 1 delete a contact:
                contacts_erase(conf, definitelyRealId)
                
                // Client 2 adds a new friend:
                let thirdId: String = "052222222222222222222222222222222222222222222222222222222222222222"
                var cThirdId: [CChar] = thirdId.cString(using: .utf8)!
                var contact7: contacts_contact = contacts_contact()
                expect(contacts_get_or_construct(conf2, &contact7, &cThirdId)).to(beTrue())
                contact7.nickname = "Nickname 3".toLibSession()
                contact7.approved = true
                contact7.approved_me = true
                contact7.profile_pic.url = "http://example.com/huge.bmp".toLibSession()
                contact7.profile_pic.key = "qwerty78901234567890123456789012".data(using: .utf8)!.toLibSession()
                contacts_set(conf2, &contact7)
                
                expect(config_needs_push(conf)).to(beTrue())
                expect(config_needs_push(conf2)).to(beTrue())
                
                let pushData6: UnsafeMutablePointer<config_push_data> = config_push(conf)
                expect(pushData6.pointee.seqno).to(equal(3))
                
                let pushData7: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData7.pointee.seqno).to(equal(3))
                
                let pushData6Str: String = String(pointer: pushData6.pointee.config, length: pushData6.pointee.config_len, encoding: .ascii)!
                let pushData7Str: String = String(pointer: pushData7.pointee.config, length: pushData7.pointee.config_len, encoding: .ascii)!
                expect(pushData6Str).toNot(equal(pushData7Str))
                expect([String](pointer: pushData6.pointee.obsolete, count: pushData6.pointee.obsolete_len))
                    .to(equal([fakeHash2]))
                expect([String](pointer: pushData7.pointee.obsolete, count: pushData7.pointee.obsolete_len))
                    .to(equal([fakeHash2]))
                
                let fakeHash3a: String = "fakehash3a"
                var cFakeHash3a: [CChar] = fakeHash3a.cString(using: .utf8)!
                let fakeHash3b: String = "fakehash3b"
                var cFakeHash3b: [CChar] = fakeHash3b.cString(using: .utf8)!
                config_confirm_pushed(conf, pushData6.pointee.seqno, &cFakeHash3a)
                config_confirm_pushed(conf2, pushData7.pointee.seqno, &cFakeHash3b)
                
                var mergeHashes2: [UnsafePointer<CChar>?] = ((try? [cFakeHash3b].unsafeCopyCStringArray()) ?? [])
                var mergeData2: [UnsafePointer<UInt8>?] = [UnsafePointer(pushData7.pointee.config)]
                var mergeSize2: [Int] = [pushData7.pointee.config_len]
                let mergedHashes2: UnsafeMutablePointer<config_string_list>? = config_merge(conf, &mergeHashes2, &mergeData2, &mergeSize2, 1)
                expect([String](pointer: mergedHashes2?.pointee.value, count: mergedHashes2?.pointee.len))
                    .to(equal(["fakehash3b"]))
                expect(config_needs_push(conf)).to(beTrue())
                mergeHashes2.forEach { $0?.deallocate() }
                mergedHashes2?.deallocate()
                pushData7.deallocate()
                
                var mergeHashes3: [UnsafePointer<CChar>?] = ((try? [cFakeHash3a].unsafeCopyCStringArray()) ?? [])
                var mergeData3: [UnsafePointer<UInt8>?] = [UnsafePointer(pushData6.pointee.config)]
                var mergeSize3: [Int] = [pushData6.pointee.config_len]
                let mergedHashes3: UnsafeMutablePointer<config_string_list>? = config_merge(conf2, &mergeHashes3, &mergeData3, &mergeSize3, 1)
                expect([String](pointer: mergedHashes3?.pointee.value, count: mergedHashes3?.pointee.len))
                    .to(equal(["fakehash3a"]))
                expect(config_needs_push(conf2)).to(beTrue())
                mergeHashes3.forEach { $0?.deallocate() }
                mergedHashes3?.deallocate()
                pushData6.deallocate()
                
                let pushData8: UnsafeMutablePointer<config_push_data> = config_push(conf)
                expect(pushData8.pointee.seqno).to(equal(4))
                
                let pushData9: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData9.pointee.seqno).to(equal(pushData8.pointee.seqno))
                
                let pushData8Str: String = String(pointer: pushData8.pointee.config, length: pushData8.pointee.config_len, encoding: .ascii)!
                let pushData9Str: String = String(pointer: pushData9.pointee.config, length: pushData9.pointee.config_len, encoding: .ascii)!
                expect(pushData8Str).to(equal(pushData9Str))
                expect([String](pointer: pushData8.pointee.obsolete, count: pushData8.pointee.obsolete_len))
                    .to(equal([fakeHash3b, fakeHash3a]))
                expect([String](pointer: pushData9.pointee.obsolete, count: pushData9.pointee.obsolete_len))
                    .to(equal([fakeHash3a, fakeHash3b]))
                
                let fakeHash4: String = "fakeHash4"
                var cFakeHash4: [CChar] = fakeHash4.cString(using: .utf8)!
                config_confirm_pushed(conf, pushData8.pointee.seqno, &cFakeHash4)
                config_confirm_pushed(conf2, pushData9.pointee.seqno, &cFakeHash4)
                pushData8.deallocate()
                pushData9.deallocate()
                
                expect(config_needs_push(conf)).to(beFalse())
                expect(config_needs_push(conf2)).to(beFalse())
                
                // Validate the changes
                var sessionIds2: [String] = []
                var nicknames2: [String] = []
                expect(contacts_size(conf)).to(equal(2))
                
                var contact8: contacts_contact = contacts_contact()
                let contactIterator2: UnsafeMutablePointer<contacts_iterator> = contacts_iterator_new(conf)
                while !contacts_iterator_done(contactIterator2, &contact8) {
                    sessionIds2.append(String(libSessionVal: contact8.session_id))
                    nicknames2.append(String(libSessionVal: contact8.nickname, nullIfEmpty: true) ?? "(N/A)")
                    contacts_iterator_advance(contactIterator2)
                }
                contacts_iterator_free(contactIterator2) // Need to free the iterator
                
                expect(sessionIds2.count).to(equal(2))
                expect(sessionIds2.first).to(equal(anotherId))
                expect(sessionIds2.last).to(equal(thirdId))
                expect(nicknames2.first).to(equal("(N/A)"))
                expect(nicknames2.last).to(equal("Nickname 3"))
            }
        }
    }
    
    // MARK: - Convenience
    
    private static func createContact(
        for index: Int,
        in conf: UnsafeMutablePointer<config_object>?,
        rand: inout ARC4RandomNumberGenerator,
        maxing properties: [ContactProperty] = []
    ) throws -> contacts_contact {
        let postPrefixId: String = "05\(rand.nextBytes(count: 32).toHexString())"
        let sessionId: String = ("05\(index)a" + postPrefixId.suffix(postPrefixId.count - "05\(index)a".count))
        var cSessionId: [CChar] = sessionId.cString(using: .utf8)!
        var contact: contacts_contact = contacts_contact()
        
        guard contacts_get_or_construct(conf, &contact, &cSessionId) else {
            throw LibSessionError.getOrConstructFailedUnexpectedly
        }
        
        // Set the values to the maximum data that can fit
        properties.forEach { property in
            switch property {
                case .approved: contact.approved = true
                case .approved_me: contact.approved_me = true
                case .blocked: contact.blocked = true
                case .created: contact.created = Int64.max
                case .notifications: contact.notifications = CONVO_NOTIFY_MENTIONS_ONLY
                case .mute_until: contact.mute_until = Int64.max
                case .priority: contact.priority = Int32.max
                case .exp_mode: contact.exp_mode = CONVO_EXPIRATION_AFTER_SEND
                case .exp_seconds: contact.exp_seconds = Int32.max
                
                case .name:
                    contact.name = rand.nextBytes(count: LibSession.libSessionMaxNameByteLength)
                        .toHexString()
                        .toLibSession()
                
                case .nickname:
                    contact.nickname = rand.nextBytes(count: LibSession.libSessionMaxNameByteLength)
                        .toHexString()
                        .toLibSession()
                    
                case .profile_pic:
                    contact.profile_pic = user_profile_pic(
                        url: rand.nextBytes(count: LibSession.libSessionMaxProfileUrlByteLength)
                            .toHexString()
                            .toLibSession(),
                        key: Data(rand.nextBytes(count: 32))
                            .toLibSession()
                    )
            }
        }
        
        return contact
    }
}

fileprivate extension Array where Element == LibSessionUtilSpec.ContactProperty {
    static var allProperties: [LibSessionUtilSpec.ContactProperty] = LibSessionUtilSpec.ContactProperty.allCases
}

// MARK: - USER_PROFILE

fileprivate extension LibSessionUtilSpec {
    class func userProfileSpec() {
        context("USER_PROFILE") {
            // MARK: -- generates config correctly
            it("generates config correctly") {
                let seed: Data = Data(hex: "0123456789abcdef0123456789abcdef")
                
                // FIXME: Would be good to move these into the libSession-util instead of using Sodium separately
                let identity = try! Identity.generate(from: seed)
                var edSK: [UInt8] = identity.ed25519KeyPair.secretKey
                expect(edSK.toHexString().suffix(64))
                    .to(equal("4cb76fdc6d32278e3f83dbf608360ecc6b65727934b85d2fb86862ff98c46ab7"))
                expect(identity.x25519KeyPair.publicKey.toHexString())
                    .to(equal("d2ad010eeb72d72e561d9de7bd7b6989af77dcabffa03a5111a6c859ae5c3a72"))
                expect(String(edSK.toHexString().prefix(32))).to(equal(seed.toHexString()))
                
                // Initialize a brand new, empty config because we have no dump data to deal with.
                let error: UnsafeMutablePointer<CChar>? = nil
                var conf: UnsafeMutablePointer<config_object>? = nil
                expect(user_profile_init(&conf, &edSK, nil, 0, error)).to(equal(0))
                error?.deallocate()
                
                // We don't need to push anything, since this is an empty config
                expect(config_needs_push(conf)).to(beFalse())
                // And we haven't changed anything so don't need to dump to db
                expect(config_needs_dump(conf)).to(beFalse())
                
                // Since it's empty there shouldn't be a name.
                let namePtr: UnsafePointer<CChar>? = user_profile_get_name(conf)
                expect(namePtr).to(beNil())
                
                // We don't need to push since we haven't changed anything, so this call is mainly just for
                // testing:
                let pushData1: UnsafeMutablePointer<config_push_data> = config_push(conf)
                expect(pushData1.pointee).toNot(beNil())
                expect(pushData1.pointee.seqno).to(equal(0))
                expect(pushData1.pointee.config_len).to(equal(432))
                
                // This should also be unset:
                let pic: user_profile_pic = user_profile_get_pic(conf)
                expect(String(libSessionVal: pic.url)).to(beEmpty())
                
                // Now let's go set a profile name and picture:
                expect(user_profile_set_name(conf, "Kallie")).to(equal(0))
                let p: user_profile_pic = user_profile_pic(
                    url: "http://example.org/omg-pic-123.bmp".toLibSession(),
                    key: "secret78901234567890123456789012".data(using: .utf8)!.toLibSession()
                )
                expect(user_profile_set_pic(conf, p)).to(equal(0))
                user_profile_set_nts_priority(conf, 9)
                
                // Retrieve them just to make sure they set properly:
                let namePtr2: UnsafePointer<CChar>? = user_profile_get_name(conf)
                expect(namePtr2).toNot(beNil())
                expect(String(cString: namePtr2!)).to(equal("Kallie"))
                
                let pic2: user_profile_pic = user_profile_get_pic(conf);
                expect(String(libSessionVal: pic2.url)).to(equal("http://example.org/omg-pic-123.bmp"))
                expect(Data(libSessionVal: pic2.key, count: ProfileManager.avatarAES256KeyByteLength))
                    .to(equal("secret78901234567890123456789012".data(using: .utf8)))
                expect(user_profile_get_nts_priority(conf)).to(equal(9))
                
                // Since we've made changes, we should need to push new config to the swarm, *and* should need
                // to dump the updated state:
                expect(config_needs_push(conf)).to(beTrue())
                expect(config_needs_dump(conf)).to(beTrue())
                
                // incremented since we made changes (this only increments once between
                // dumps; even though we changed two fields here).
                let pushData2: UnsafeMutablePointer<config_push_data> = config_push(conf)
                expect(pushData2.pointee.seqno).to(equal(1))
                
                let expPush1Encrypted: [UInt8] = Array(Data(hex: [
                    "9693a69686da3055f1ecdfb239c3bf8e746951a36d888c2fb7c02e856a5c2091b24e39a7e1af828f",
                    "1fa09fe8bf7d274afde0a0847ba143c43ffb8722301b5ae32e2f078b9a5e19097403336e50b18c84",
                    "aade446cd2823b011f97d6ad2116a53feb814efecc086bc172d31f4214b4d7c630b63bbe575b0868",
                    "2d146da44915063a07a78556ab5eff4f67f6aa26211e8d330b53d28567a931028c393709a325425d",
                    "e7486ccde24416a7fd4a8ba5fa73899c65f4276dfaddd5b2100adcf0f793104fb235b31ce32ec656",
                    "056009a9ebf58d45d7d696b74e0c7ff0499c4d23204976f19561dc0dba6dc53a2497d28ce03498ea",
                    "49bf122762d7bc1d6d9c02f6d54f8384"
                ].joined()))
                
                // We haven't dumped, so still need to dump:
                expect(config_needs_dump(conf)).to(beTrue())
                // We did call push, but we haven't confirmed it as stored yet, so this will still return true:
                expect(config_needs_push(conf)).to(beTrue())
                
                var dump1: UnsafeMutablePointer<UInt8>? = nil
                var dump1Len: Int = 0
                
                config_dump(conf, &dump1, &dump1Len)
                // (in a real client we'd now store this to disk)
                
                expect(config_needs_dump(conf)).to(beFalse())
                dump1?.deallocate()
                
                // So now imagine we got back confirmation from the swarm that the push has been stored:
                let fakeHash1: String = "fakehash1"
                var cFakeHash1: [CChar] = fakeHash1.cString(using: .utf8)!
                config_confirm_pushed(conf, pushData2.pointee.seqno, &cFakeHash1)
                pushData2.deallocate()
                
                expect(config_needs_push(conf)).to(beFalse())
                expect(config_needs_dump(conf)).to(beTrue()) // The confirmation changes state, so this makes us need a dump
                
                var dump2: UnsafeMutablePointer<UInt8>? = nil
                var dump2Len: Int = 0
                config_dump(conf, &dump2, &dump2Len)
                dump2?.deallocate()
                expect(config_needs_dump(conf)).to(beFalse())
                
                // Now we're going to set up a second, competing config object (in the real world this would be
                // another Session client somewhere).
                
                // Start with an empty config, as above:
                let error2: UnsafeMutablePointer<CChar>? = nil
                var conf2: UnsafeMutablePointer<config_object>? = nil
                expect(user_profile_init(&conf2, &edSK, nil, 0, error2)).to(equal(0))
                expect(config_needs_dump(conf2)).to(beFalse())
                error2?.deallocate()
                
                // Now imagine we just pulled down the `exp_push1` string from the swarm; we merge it into
                // conf2:
                var mergeHashes: [UnsafePointer<CChar>?] = ((try? [cFakeHash1].unsafeCopyCStringArray()) ?? [])
                var mergeData: [UnsafePointer<UInt8>?] = ((try? [expPush1Encrypted].unsafeCopyUInt8Array()) ?? [])
                var mergeSize: [Int] = [expPush1Encrypted.count]
                let mergedHashes: UnsafeMutablePointer<config_string_list>? = config_merge(conf2, &mergeHashes, &mergeData, &mergeSize, 1)
                expect([String](pointer: mergedHashes?.pointee.value, count: mergedHashes?.pointee.len))
                    .to(equal(["fakehash1"]))
                mergeHashes.forEach { $0?.deallocate() }
                mergeData.forEach { $0?.deallocate() }
                mergedHashes?.deallocate()
                
                // Our state has changed, so we need to dump:
                expect(config_needs_dump(conf2)).to(beTrue())
                var dump3: UnsafeMutablePointer<UInt8>? = nil
                var dump3Len: Int = 0
                config_dump(conf2, &dump3, &dump3Len)
                // (store in db)
                dump3?.deallocate()
                expect(config_needs_dump(conf2)).to(beFalse())
                
                // We *don't* need to push: even though we updated, all we did is update to the merged data (and
                // didn't have any sort of merge conflict needed):
                expect(config_needs_push(conf2)).to(beFalse())
                
                // Now let's create a conflicting update:
                
                // Change the name on both clients:
                user_profile_set_name(conf, "Nibbler")
                user_profile_set_name(conf2, "Raz")
                
                // And, on conf2, we're also going to change the profile pic:
                let p2: user_profile_pic = user_profile_pic(
                    url: "http://new.example.com/pic".toLibSession(),
                    key: "qwert\0yuio1234567890123456789012".data(using: .utf8)!.toLibSession()
                )
                user_profile_set_pic(conf2, p2)
                
                user_profile_set_nts_expiry(conf2, 86400)
                expect(user_profile_get_nts_expiry(conf2)).to(equal(86400))
                
                expect(user_profile_get_blinded_msgreqs(conf2)).to(equal(-1))
                user_profile_set_blinded_msgreqs(conf2, 0)
                expect(user_profile_get_blinded_msgreqs(conf2)).to(equal(0))
                user_profile_set_blinded_msgreqs(conf2, -1)
                expect(user_profile_get_blinded_msgreqs(conf2)).to(equal(-1))
                user_profile_set_blinded_msgreqs(conf2, 1)
                expect(user_profile_get_blinded_msgreqs(conf2)).to(equal(1))
                
                // Both have changes, so push need a push
                expect(config_needs_push(conf)).to(beTrue())
                expect(config_needs_push(conf2)).to(beTrue())
                
                let fakeHash2: String = "fakehash2"
                var cFakeHash2: [CChar] = fakeHash2.cString(using: .utf8)!
                let pushData3: UnsafeMutablePointer<config_push_data> = config_push(conf)
                expect(pushData3.pointee.seqno).to(equal(2)) // incremented, since we made a field change
                config_confirm_pushed(conf, pushData3.pointee.seqno, &cFakeHash2)
                
                let fakeHash3: String = "fakehash3"
                var cFakeHash3: [CChar] = fakeHash3.cString(using: .utf8)!
                let pushData4: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData4.pointee.seqno).to(equal(2)) // incremented, since we made a field change
                config_confirm_pushed(conf, pushData4.pointee.seqno, &cFakeHash3)
                
                var dump4: UnsafeMutablePointer<UInt8>? = nil
                var dump4Len: Int = 0
                config_dump(conf, &dump4, &dump4Len);
                var dump5: UnsafeMutablePointer<UInt8>? = nil
                var dump5Len: Int = 0
                config_dump(conf2, &dump5, &dump5Len);
                // (store in db)
                dump4?.deallocate()
                dump5?.deallocate()
                
                // Since we set different things, we're going to get back different serialized data to be
                // pushed:
                let pushData3Str: String? = String(pointer: pushData3.pointee.config, length: pushData3.pointee.config_len, encoding: .ascii)
                let pushData4Str: String? = String(pointer: pushData4.pointee.config, length: pushData4.pointee.config_len, encoding: .ascii)
                expect(pushData3Str).toNot(equal(pushData4Str))
                
                // Now imagine that each client pushed its `seqno=2` config to the swarm, but then each client
                // also fetches new messages and pulls down the other client's `seqno=2` value.
                
                // Feed the new config into each other.  (This array could hold multiple configs if we pulled
                // down more than one).
                var mergeHashes2: [UnsafePointer<CChar>?] = ((try? [cFakeHash2].unsafeCopyCStringArray()) ?? [])
                var mergeData2: [UnsafePointer<UInt8>?] = [UnsafePointer(pushData3.pointee.config)]
                var mergeSize2: [Int] = [pushData3.pointee.config_len]
                let mergedHashes2: UnsafeMutablePointer<config_string_list>? = config_merge(conf2, &mergeHashes2, &mergeData2, &mergeSize2, 1)
                expect([String](pointer: mergedHashes2?.pointee.value, count: mergedHashes2?.pointee.len))
                    .to(equal(["fakehash2"]))
                mergeHashes2.forEach { $0?.deallocate() }
                mergedHashes2?.deallocate()
                pushData3.deallocate()
                
                var mergeHashes3: [UnsafePointer<CChar>?] = ((try? [cFakeHash3].unsafeCopyCStringArray()) ?? [])
                var mergeData3: [UnsafePointer<UInt8>?] = [UnsafePointer(pushData4.pointee.config)]
                var mergeSize3: [Int] = [pushData4.pointee.config_len]
                let mergedHashes3: UnsafeMutablePointer<config_string_list>? = config_merge(conf, &mergeHashes3, &mergeData3, &mergeSize3, 1)
                expect([String](pointer: mergedHashes3?.pointee.value, count: mergedHashes3?.pointee.len))
                    .to(equal(["fakehash3"]))
                mergeHashes3.forEach { $0?.deallocate() }
                mergedHashes3?.deallocate()
                pushData4.deallocate()
                
                // Now after the merge we *will* want to push from both client, since both will have generated a
                // merge conflict update (with seqno = 3).
                expect(config_needs_push(conf)).to(beTrue())
                expect(config_needs_push(conf2)).to(beTrue())
                let pushData5: UnsafeMutablePointer<config_push_data> = config_push(conf)
                let pushData6: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData5.pointee.seqno).to(equal(3))
                expect(pushData6.pointee.seqno).to(equal(3))
                
                // They should have resolved the conflict to the same thing:
                expect(String(cString: user_profile_get_name(conf)!)).to(equal("Nibbler"))
                expect(String(cString: user_profile_get_name(conf2)!)).to(equal("Nibbler"))
                // (Note that they could have also both resolved to "Raz" here, but the hash of the serialized
                // message just happens to have a higher hash -- and thus gets priority -- for this particular
                // test).
                
                // Since only one of them set a profile pic there should be no conflict there:
                let pic3: user_profile_pic = user_profile_get_pic(conf)
                expect(pic3.url).toNot(beNil())
                expect(String(libSessionVal: pic3.url)).to(equal("http://new.example.com/pic"))
                expect(pic3.key).toNot(beNil())
                expect(Data(libSessionVal: pic3.key, count: 32).toHexString())
                    .to(equal("7177657274007975696f31323334353637383930313233343536373839303132"))
                let pic4: user_profile_pic = user_profile_get_pic(conf2)
                expect(pic4.url).toNot(beNil())
                expect(String(libSessionVal: pic4.url)).to(equal("http://new.example.com/pic"))
                expect(pic4.key).toNot(beNil())
                expect(Data(libSessionVal: pic4.key, count: 32).toHexString())
                    .to(equal("7177657274007975696f31323334353637383930313233343536373839303132"))
                expect(user_profile_get_nts_priority(conf)).to(equal(9))
                expect(user_profile_get_nts_priority(conf2)).to(equal(9))
                expect(user_profile_get_nts_expiry(conf)).to(equal(86400))
                expect(user_profile_get_nts_expiry(conf2)).to(equal(86400))
                expect(user_profile_get_blinded_msgreqs(conf)).to(equal(1))
                expect(user_profile_get_blinded_msgreqs(conf2)).to(equal(1))
                
                let fakeHash4: String = "fakehash4"
                var cFakeHash4: [CChar] = fakeHash4.cString(using: .utf8)!
                let fakeHash5: String = "fakehash5"
                var cFakeHash5: [CChar] = fakeHash5.cString(using: .utf8)!
                config_confirm_pushed(conf, pushData5.pointee.seqno, &cFakeHash4)
                config_confirm_pushed(conf2, pushData6.pointee.seqno, &cFakeHash5)
                pushData5.deallocate()
                pushData6.deallocate()
                
                var dump6: UnsafeMutablePointer<UInt8>? = nil
                var dump6Len: Int = 0
                config_dump(conf, &dump6, &dump6Len);
                var dump7: UnsafeMutablePointer<UInt8>? = nil
                var dump7Len: Int = 0
                config_dump(conf2, &dump7, &dump7Len);
                // (store in db)
                dump6?.deallocate()
                dump7?.deallocate()
                
                expect(config_needs_dump(conf)).to(beFalse())
                expect(config_needs_dump(conf2)).to(beFalse())
                expect(config_needs_push(conf)).to(beFalse())
                expect(config_needs_push(conf2)).to(beFalse())
                
                // Wouldn't do this in a normal session but doing it here to properly clean up
                // after the test
                conf?.deallocate()
                conf2?.deallocate()
            }
        }
    }
}

// MARK: - CONVO_INFO_VOLATILE

fileprivate extension LibSessionUtilSpec {
    class func convoInfoVolatileSpec() {
        context("CONVO_INFO_VOLATILE") {
            // MARK: -- generates config correctly
            it("generates config correctly") {
                let seed: Data = Data(hex: "0123456789abcdef0123456789abcdef")
                
                // FIXME: Would be good to move these into the libSession-util instead of using Sodium separately
                let identity = try! Identity.generate(from: seed)
                var edSK: [UInt8] = identity.ed25519KeyPair.secretKey
                expect(edSK.toHexString().suffix(64))
                    .to(equal("4cb76fdc6d32278e3f83dbf608360ecc6b65727934b85d2fb86862ff98c46ab7"))
                expect(identity.x25519KeyPair.publicKey.toHexString())
                    .to(equal("d2ad010eeb72d72e561d9de7bd7b6989af77dcabffa03a5111a6c859ae5c3a72"))
                expect(String(edSK.toHexString().prefix(32))).to(equal(seed.toHexString()))
                
                // Initialize a brand new, empty config because we have no dump data to deal with.
                let error: UnsafeMutablePointer<CChar>? = nil
                var conf: UnsafeMutablePointer<config_object>? = nil
                expect(convo_info_volatile_init(&conf, &edSK, nil, 0, error)).to(equal(0))
                error?.deallocate()
                
                // Empty contacts shouldn't have an existing contact
                let definitelyRealId: String = "055000000000000000000000000000000000000000000000000000000000000000"
                var cDefinitelyRealId: [CChar] = definitelyRealId.cString(using: .utf8)!
                var oneToOne1: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                expect(convo_info_volatile_get_1to1(conf, &oneToOne1, &cDefinitelyRealId)).to(beFalse())
                expect(convo_info_volatile_size(conf)).to(equal(0))
                
                var oneToOne2: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                expect(convo_info_volatile_get_or_construct_1to1(conf, &oneToOne2, &cDefinitelyRealId))
                    .to(beTrue())
                expect(String(libSessionVal: oneToOne2.session_id)).to(equal(definitelyRealId))
                expect(oneToOne2.last_read).to(equal(0))
                expect(oneToOne2.unread).to(beFalse())
                
                // No need to sync a conversation with a default state
                expect(config_needs_push(conf)).to(beFalse())
                expect(config_needs_dump(conf)).to(beFalse())
                
                // Update the last read
                let nowTimestampMs: Int64 = Int64(floor(Date().timeIntervalSince1970 * 1000))
                oneToOne2.last_read = nowTimestampMs
                
                // The new data doesn't get stored until we call this:
                convo_info_volatile_set_1to1(conf, &oneToOne2)
                
                var legacyGroup1: convo_info_volatile_legacy_group = convo_info_volatile_legacy_group()
                var oneToOne3: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                expect(convo_info_volatile_get_legacy_group(conf, &legacyGroup1, &cDefinitelyRealId))
                    .to(beFalse())
                expect(convo_info_volatile_get_1to1(conf, &oneToOne3, &cDefinitelyRealId)).to(beTrue())
                expect(oneToOne3.last_read).to(equal(nowTimestampMs))
                
                expect(config_needs_push(conf)).to(beTrue())
                expect(config_needs_dump(conf)).to(beTrue())
                
                let openGroupBaseUrl: String = "http://Example.ORG:5678"
                var cOpenGroupBaseUrl: [CChar] = openGroupBaseUrl.cString(using: .utf8)!
                let openGroupBaseUrlResult: String = openGroupBaseUrl.lowercased()
                //            ("http://Example.ORG:5678"
                //                .lowercased()
                //                .cArray +
                //                [CChar](repeating: 0, count: (268 - openGroupBaseUrl.count))
                //            )
                let openGroupRoom: String = "SudokuRoom"
                var cOpenGroupRoom: [CChar] = openGroupRoom.cString(using: .utf8)!
                let openGroupRoomResult: String = openGroupRoom.lowercased()
                //            ("SudokuRoom"
                //                .lowercased()
                //                .cArray +
                //                [CChar](repeating: 0, count: (65 - openGroupRoom.count))
                //            )
                var cOpenGroupPubkey: [UInt8] = Data(hex: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
                    .bytes
                var community1: convo_info_volatile_community = convo_info_volatile_community()
                expect(convo_info_volatile_get_or_construct_community(conf, &community1, &cOpenGroupBaseUrl, &cOpenGroupRoom, &cOpenGroupPubkey)).to(beTrue())
                expect(String(libSessionVal: community1.base_url)).to(equal(openGroupBaseUrlResult))
                expect(String(libSessionVal: community1.room)).to(equal(openGroupRoomResult))
                expect(Data(libSessionVal: community1.pubkey, count: 32).toHexString())
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
                community1.unread = true
                
                // The new data doesn't get stored until we call this:
                convo_info_volatile_set_community(conf, &community1);
                
                // We don't need to push since we haven't changed anything, so this call is mainly just for
                // testing:
                let pushData1: UnsafeMutablePointer<config_push_data> = config_push(conf)
                expect(pushData1.pointee.seqno).to(equal(1))
                
                // Pretend we uploaded it
                let fakeHash1: String = "fakehash1"
                var cFakeHash1: [CChar] = fakeHash1.cString(using: .utf8)!
                config_confirm_pushed(conf, pushData1.pointee.seqno, &cFakeHash1)
                expect(config_needs_dump(conf)).to(beTrue())
                expect(config_needs_push(conf)).to(beFalse())
                pushData1.deallocate()
                
                var dump1: UnsafeMutablePointer<UInt8>? = nil
                var dump1Len: Int = 0
                config_dump(conf, &dump1, &dump1Len)
                
                let error2: UnsafeMutablePointer<CChar>? = nil
                var conf2: UnsafeMutablePointer<config_object>? = nil
                expect(convo_info_volatile_init(&conf2, &edSK, dump1, dump1Len, error2)).to(equal(0))
                error2?.deallocate()
                dump1?.deallocate()
                
                expect(config_needs_dump(conf2)).to(beFalse())
                expect(config_needs_push(conf2)).to(beFalse())
                
                var oneToOne4: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                expect(convo_info_volatile_get_1to1(conf2, &oneToOne4, &cDefinitelyRealId)).to(equal(true))
                expect(oneToOne4.last_read).to(equal(nowTimestampMs))
                expect(String(libSessionVal: oneToOne4.session_id)).to(equal(definitelyRealId))
                expect(oneToOne4.unread).to(beFalse())
                
                var community2: convo_info_volatile_community = convo_info_volatile_community()
                expect(convo_info_volatile_get_community(conf2, &community2, &cOpenGroupBaseUrl, &cOpenGroupRoom)).to(beTrue())
                expect(String(libSessionVal: community2.base_url)).to(equal(openGroupBaseUrlResult))
                expect(String(libSessionVal: community2.room)).to(equal(openGroupRoomResult))
                expect(Data(libSessionVal: community2.pubkey, count: 32).toHexString())
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
                community2.unread = true
                
                let anotherId: String = "051111111111111111111111111111111111111111111111111111111111111111"
                var cAnotherId: [CChar] = anotherId.cString(using: .utf8)!
                var oneToOne5: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                expect(convo_info_volatile_get_or_construct_1to1(conf2, &oneToOne5, &cAnotherId)).to(beTrue())
                oneToOne5.unread = true
                convo_info_volatile_set_1to1(conf2, &oneToOne5)
                
                let thirdId: String = "05cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
                var cThirdId: [CChar] = thirdId.cString(using: .utf8)!
                var legacyGroup2: convo_info_volatile_legacy_group = convo_info_volatile_legacy_group()
                expect(convo_info_volatile_get_or_construct_legacy_group(conf2, &legacyGroup2, &cThirdId)).to(beTrue())
                legacyGroup2.last_read = (nowTimestampMs - 50)
                convo_info_volatile_set_legacy_group(conf2, &legacyGroup2)
                expect(config_needs_push(conf2)).to(beTrue())
                
                let pushData2: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData2.pointee.seqno).to(equal(2))
                
                // Check the merging
                let fakeHash2: String = "fakehash2"
                var cFakeHash2: [CChar] = fakeHash2.cString(using: .utf8)!
                var mergeHashes: [UnsafePointer<CChar>?] = ((try? [cFakeHash2].unsafeCopyCStringArray()) ?? [])
                var mergeData: [UnsafePointer<UInt8>?] = [UnsafePointer(pushData2.pointee.config)]
                var mergeSize: [Int] = [pushData2.pointee.config_len]
                let mergedHashes: UnsafeMutablePointer<config_string_list>? = config_merge(conf, &mergeHashes, &mergeData, &mergeSize, 1)
                expect([String](pointer: mergedHashes?.pointee.value, count: mergedHashes?.pointee.len))
                    .to(equal(["fakehash2"]))
                config_confirm_pushed(conf, pushData2.pointee.seqno, &cFakeHash2)
                mergeHashes.forEach { $0?.deallocate() }
                mergedHashes?.deallocate()
                pushData2.deallocate()
                
                expect(config_needs_push(conf)).to(beFalse())
                
                for targetConf in [conf, conf2] {
                    // Iterate through and make sure we got everything we expected
                    var seen: [String] = []
                    expect(convo_info_volatile_size(conf)).to(equal(4))
                    expect(convo_info_volatile_size_1to1(conf)).to(equal(2))
                    expect(convo_info_volatile_size_communities(conf)).to(equal(1))
                    expect(convo_info_volatile_size_legacy_groups(conf)).to(equal(1))
                    
                    var c1: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                    var c2: convo_info_volatile_community = convo_info_volatile_community()
                    var c3: convo_info_volatile_legacy_group = convo_info_volatile_legacy_group()
                    let it: OpaquePointer = convo_info_volatile_iterator_new(targetConf)
                    
                    while !convo_info_volatile_iterator_done(it) {
                        if convo_info_volatile_it_is_1to1(it, &c1) {
                            seen.append("1-to-1: \(String(libSessionVal: c1.session_id))")
                        }
                        else if convo_info_volatile_it_is_community(it, &c2) {
                            seen.append("og: \(String(libSessionVal: c2.base_url))/r/\(String(libSessionVal: c2.room))")
                        }
                        else if convo_info_volatile_it_is_legacy_group(it, &c3) {
                            seen.append("cl: \(String(libSessionVal: c3.group_id))")
                        }
                        
                        convo_info_volatile_iterator_advance(it)
                    }
                    
                    convo_info_volatile_iterator_free(it)
                    
                    expect(seen).to(equal([
                        "1-to-1: 051111111111111111111111111111111111111111111111111111111111111111",
                        "1-to-1: 055000000000000000000000000000000000000000000000000000000000000000",
                        "og: http://example.org:5678/r/sudokuroom",
                        "cl: 05cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
                    ]))
                }
                
                let fourthId: String = "052000000000000000000000000000000000000000000000000000000000000000"
                var cFourthId: [CChar] = fourthId.cString(using: .utf8)!
                expect(config_needs_push(conf)).to(beFalse())
                convo_info_volatile_erase_1to1(conf, &cFourthId)
                expect(config_needs_push(conf)).to(beFalse())
                convo_info_volatile_erase_1to1(conf, &cDefinitelyRealId)
                expect(config_needs_push(conf)).to(beTrue())
                expect(convo_info_volatile_size(conf)).to(equal(3))
                expect(convo_info_volatile_size_1to1(conf)).to(equal(1))
                
                // Check the single-type iterators:
                var seen1: [String?] = []
                var c1: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                let it1: OpaquePointer = convo_info_volatile_iterator_new_1to1(conf)
                
                while !convo_info_volatile_iterator_done(it1) {
                    expect(convo_info_volatile_it_is_1to1(it1, &c1)).to(beTrue())
                    
                    seen1.append(String(libSessionVal: c1.session_id))
                    convo_info_volatile_iterator_advance(it1)
                }
                
                convo_info_volatile_iterator_free(it1)
                expect(seen1).to(equal([
                    "051111111111111111111111111111111111111111111111111111111111111111"
                ]))
                
                var seen2: [String?] = []
                var c2: convo_info_volatile_community = convo_info_volatile_community()
                let it2: OpaquePointer = convo_info_volatile_iterator_new_communities(conf)
                
                while !convo_info_volatile_iterator_done(it2) {
                    expect(convo_info_volatile_it_is_community(it2, &c2)).to(beTrue())
                    
                    seen2.append(String(libSessionVal: c2.base_url))
                    convo_info_volatile_iterator_advance(it2)
                }
                
                convo_info_volatile_iterator_free(it2)
                expect(seen2).to(equal([
                    "http://example.org:5678"
                ]))
                
                var seen3: [String?] = []
                var c3: convo_info_volatile_legacy_group = convo_info_volatile_legacy_group()
                let it3: OpaquePointer = convo_info_volatile_iterator_new_legacy_groups(conf)
                
                while !convo_info_volatile_iterator_done(it3) {
                    expect(convo_info_volatile_it_is_legacy_group(it3, &c3)).to(beTrue())
                    
                    seen3.append(String(libSessionVal: c3.group_id))
                    convo_info_volatile_iterator_advance(it3)
                }
                
                convo_info_volatile_iterator_free(it3)
                expect(seen3).to(equal([
                    "05cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
                ]))
            }
        }
    }
}

// MARK: - USER_GROUPS

fileprivate extension LibSessionUtilSpec {
    class func userGroupsSpec() {
        context("USER_GROUPS") {
            // MARK: -- generates config correctly
            it("generates config correctly") {
                let createdTs: Int64 = 1680064059
                let nowTs: Int64 = Int64(Date().timeIntervalSince1970)
                let seed: Data = Data(hex: "0123456789abcdef0123456789abcdef")
                
                // FIXME: Would be good to move these into the libSession-util instead of using Sodium separately
                let identity = try! Identity.generate(from: seed)
                var edSK: [UInt8] = identity.ed25519KeyPair.secretKey
                expect(edSK.toHexString().suffix(64))
                    .to(equal("4cb76fdc6d32278e3f83dbf608360ecc6b65727934b85d2fb86862ff98c46ab7"))
                expect(identity.x25519KeyPair.publicKey.toHexString())
                    .to(equal("d2ad010eeb72d72e561d9de7bd7b6989af77dcabffa03a5111a6c859ae5c3a72"))
                expect(String(edSK.toHexString().prefix(32))).to(equal(seed.toHexString()))
                
                // Initialize a brand new, empty config because we have no dump data to deal with.
                let error: UnsafeMutablePointer<CChar>? = nil
                var conf: UnsafeMutablePointer<config_object>? = nil
                expect(user_groups_init(&conf, &edSK, nil, 0, error)).to(equal(0))
                error?.deallocate()
                
                // Empty contacts shouldn't have an existing contact
                let definitelyRealId: String = "055000000000000000000000000000000000000000000000000000000000000000"
                var cDefinitelyRealId: [CChar] = definitelyRealId.cString(using: .utf8)!
                let legacyGroup1: UnsafeMutablePointer<ugroups_legacy_group_info>? = user_groups_get_legacy_group(conf, &cDefinitelyRealId)
                expect(legacyGroup1?.pointee).to(beNil())
                expect(user_groups_size(conf)).to(equal(0))
                
                let legacyGroup2: UnsafeMutablePointer<ugroups_legacy_group_info> = user_groups_get_or_construct_legacy_group(conf, &cDefinitelyRealId)
                expect(legacyGroup2.pointee).toNot(beNil())
                expect(String(libSessionVal: legacyGroup2.pointee.session_id))
                    .to(equal(definitelyRealId))
                expect(legacyGroup2.pointee.disappearing_timer).to(equal(0))
                expect(String(libSessionVal: legacyGroup2.pointee.enc_pubkey, fixedLength: 32)).to(equal(""))
                expect(String(libSessionVal: legacyGroup2.pointee.enc_seckey, fixedLength: 32)).to(equal(""))
                expect(legacyGroup2.pointee.priority).to(equal(0))
                expect(String(libSessionVal: legacyGroup2.pointee.name)).to(equal(""))
                expect(legacyGroup2.pointee.joined_at).to(equal(0))
                expect(legacyGroup2.pointee.notifications).to(equal(CONVO_NOTIFY_DEFAULT))
                expect(legacyGroup2.pointee.mute_until).to(equal(0))
                
                // Iterate through and make sure we got everything we expected
                var membersSeen1: [String: Bool] = [:]
                var memberSessionId1: UnsafePointer<CChar>? = nil
                var memberAdmin1: Bool = false
                let membersIt1: OpaquePointer = ugroups_legacy_members_begin(legacyGroup2)
                
                while ugroups_legacy_members_next(membersIt1, &memberSessionId1, &memberAdmin1) {
                    membersSeen1[String(cString: memberSessionId1!)] = memberAdmin1
                }
                
                ugroups_legacy_members_free(membersIt1)
                
                expect(membersSeen1).to(beEmpty())
                
                // No need to sync a conversation with a default state
                expect(config_needs_push(conf)).to(beFalse())
                expect(config_needs_dump(conf)).to(beFalse())
                
                // We don't need to push since we haven't changed anything, so this call is mainly just for
                // testing:
                let pushData1: UnsafeMutablePointer<config_push_data> = config_push(conf)
                expect(pushData1.pointee.seqno).to(equal(0))
                expect([String](pointer: pushData1.pointee.obsolete, count: pushData1.pointee.obsolete_len))
                    .to(beEmpty())
                expect(pushData1.pointee.config_len).to(equal(432))
                pushData1.deallocate()
                
                let users: [String] = [
                    "050000000000000000000000000000000000000000000000000000000000000000",
                    "051111111111111111111111111111111111111111111111111111111111111111",
                    "052222222222222222222222222222222222222222222222222222222222222222",
                    "053333333333333333333333333333333333333333333333333333333333333333",
                    "054444444444444444444444444444444444444444444444444444444444444444",
                    "055555555555555555555555555555555555555555555555555555555555555555",
                    "056666666666666666666666666666666666666666666666666666666666666666"
                ]
                var cUsers: [[CChar]] = users.map { $0.cString(using: .utf8)! }
                legacyGroup2.pointee.name = "Englishmen".toLibSession()
                legacyGroup2.pointee.disappearing_timer = 60
                legacyGroup2.pointee.joined_at = createdTs
                legacyGroup2.pointee.notifications = CONVO_NOTIFY_ALL
                legacyGroup2.pointee.mute_until = (nowTs + 3600)
                expect(ugroups_legacy_member_add(legacyGroup2, &cUsers[0], false)).to(beTrue())
                expect(ugroups_legacy_member_add(legacyGroup2, &cUsers[1], true)).to(beTrue())
                expect(ugroups_legacy_member_add(legacyGroup2, &cUsers[2], false)).to(beTrue())
                expect(ugroups_legacy_member_add(legacyGroup2, &cUsers[4], true)).to(beTrue())
                expect(ugroups_legacy_member_add(legacyGroup2, &cUsers[5], false)).to(beTrue())
                expect(ugroups_legacy_member_add(legacyGroup2, &cUsers[2], false)).to(beFalse())
                
                // Flip to and from admin
                expect(ugroups_legacy_member_add(legacyGroup2, &cUsers[2], true)).to(beTrue())
                expect(ugroups_legacy_member_add(legacyGroup2, &cUsers[1], false)).to(beTrue())
                
                expect(ugroups_legacy_member_remove(legacyGroup2, &cUsers[5])).to(beTrue())
                expect(ugroups_legacy_member_remove(legacyGroup2, &cUsers[4])).to(beTrue())
                
                var membersSeen2: [String: Bool] = [:]
                var memberSessionId2: UnsafePointer<CChar>? = nil
                var memberAdmin2: Bool = false
                let membersIt2: OpaquePointer = ugroups_legacy_members_begin(legacyGroup2)
                
                while ugroups_legacy_members_next(membersIt2, &memberSessionId2, &memberAdmin2) {
                    membersSeen2[String(cString: memberSessionId2!)] = memberAdmin2
                }
                
                ugroups_legacy_members_free(membersIt2)
                
                expect(membersSeen2).to(equal([
                    "050000000000000000000000000000000000000000000000000000000000000000": false,
                    "051111111111111111111111111111111111111111111111111111111111111111": false,
                    "052222222222222222222222222222222222222222222222222222222222222222": true
                ]))
                
                // FIXME: Would be good to move these into the libSession-util instead of using Sodium separately
                let groupSeed: Data = Data(hex: "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
                let groupEd25519KeyPair = Sodium().sign.keyPair(seed: groupSeed.bytes)!
                let groupX25519PublicKey = Sodium().sign.toX25519(ed25519PublicKey: groupEd25519KeyPair.publicKey)!
                
                // Note: this isn't exactly what Session actually does here for legacy closed
                // groups (rather it uses X25519 keys) but for this test the distinction doesn't matter.
                legacyGroup2.pointee.enc_pubkey = Data(groupX25519PublicKey).toLibSession()
                legacyGroup2.pointee.enc_seckey = Data(groupEd25519KeyPair.secretKey).toLibSession()
                legacyGroup2.pointee.priority = 3
                
                expect(Data(libSessionVal: legacyGroup2.pointee.enc_pubkey, count: 32).toHexString())
                    .to(equal("c5ba413c336f2fe1fb9a2c525f8a86a412a1db128a7841b4e0e217fa9eb7fd5e"))
                expect(Data(libSessionVal: legacyGroup2.pointee.enc_seckey, count: 32).toHexString())
                    .to(equal("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"))
                
                // The new data doesn't get stored until we call this:
                user_groups_set_free_legacy_group(conf, legacyGroup2)
                
                let legacyGroup3: UnsafeMutablePointer<ugroups_legacy_group_info>? = user_groups_get_legacy_group(conf, &cDefinitelyRealId)
                expect(legacyGroup3?.pointee).toNot(beNil())
                expect(config_needs_push(conf)).to(beTrue())
                expect(config_needs_dump(conf)).to(beTrue())
                ugroups_legacy_group_free(legacyGroup3)
                
                let communityPubkey: String = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
                var cCommunityPubkey: [UInt8] = Array(Data(hex: communityPubkey))
                var cCommunityBaseUrl: [CChar] = "http://Example.ORG:5678".cString(using: .utf8)!
                var cCommunityRoom: [CChar] = "SudokuRoom".cString(using: .utf8)!
                var community1: ugroups_community_info = ugroups_community_info()
                expect(user_groups_get_or_construct_community(conf, &community1, &cCommunityBaseUrl, &cCommunityRoom, &cCommunityPubkey))
                    .to(beTrue())
                
                expect(String(libSessionVal: community1.base_url)).to(equal("http://example.org:5678")) // Note: lower-case
                expect(String(libSessionVal: community1.room)).to(equal("SudokuRoom")) // Note: case-preserving
                expect(Data(libSessionVal: community1.pubkey, count: 32).toHexString())
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
                community1.priority = 14
                
                // The new data doesn't get stored until we call this:
                user_groups_set_community(conf, &community1)
                
                // incremented since we made changes (this only increments once between
                // dumps; even though we changed two fields here).
                let pushData2: UnsafeMutablePointer<config_push_data> = config_push(conf)
                expect(pushData2.pointee.seqno).to(equal(1))
                expect([String](pointer: pushData2.pointee.obsolete, count: pushData2.pointee.obsolete_len))
                    .to(beEmpty())
                
                // Pretend we uploaded it
                let fakeHash1: String = "fakehash1"
                var cFakeHash1: [CChar] = fakeHash1.cString(using: .utf8)!
                config_confirm_pushed(conf, pushData2.pointee.seqno, &cFakeHash1)
                expect(config_needs_dump(conf)).to(beTrue())
                expect(config_needs_push(conf)).to(beFalse())
                
                var dump1: UnsafeMutablePointer<UInt8>? = nil
                var dump1Len: Int = 0
                config_dump(conf, &dump1, &dump1Len)
                
                let error2: UnsafeMutablePointer<CChar>? = nil
                var conf2: UnsafeMutablePointer<config_object>? = nil
                expect(user_groups_init(&conf2, &edSK, dump1, dump1Len, error2)).to(equal(0))
                error2?.deallocate()
                dump1?.deallocate()
                
                expect(config_needs_dump(conf)).to(beFalse())  // Because we just called dump() above, to load up conf2
                expect(config_needs_push(conf)).to(beFalse())
                
                let pushData3: UnsafeMutablePointer<config_push_data> = config_push(conf)
                expect(pushData3.pointee.seqno).to(equal(1))
                expect([String](pointer: pushData3.pointee.obsolete, count: pushData3.pointee.obsolete_len))
                    .to(beEmpty())
                pushData3.deallocate()
                
                let currentHashes1: UnsafeMutablePointer<config_string_list>? = config_current_hashes(conf)
                expect([String](pointer: currentHashes1?.pointee.value, count: currentHashes1?.pointee.len))
                    .to(equal(["fakehash1"]))
                currentHashes1?.deallocate()
                
                expect(config_needs_push(conf2)).to(beFalse())
                expect(config_needs_dump(conf2)).to(beFalse())
                
                let pushData4: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData4.pointee.seqno).to(equal(1))
                expect(config_needs_dump(conf2)).to(beFalse())
                expect([String](pointer: pushData4.pointee.obsolete, count: pushData4.pointee.obsolete_len))
                    .to(beEmpty())
                pushData4.deallocate()
                
                let currentHashes2: UnsafeMutablePointer<config_string_list>? = config_current_hashes(conf2)
                expect([String](pointer: currentHashes2?.pointee.value, count: currentHashes2?.pointee.len))
                    .to(equal(["fakehash1"]))
                currentHashes2?.deallocate()
                
                expect(user_groups_size(conf2)).to(equal(2))
                expect(user_groups_size_communities(conf2)).to(equal(1))
                expect(user_groups_size_legacy_groups(conf2)).to(equal(1))
                
                let legacyGroup4: UnsafeMutablePointer<ugroups_legacy_group_info>? = user_groups_get_legacy_group(conf2, &cDefinitelyRealId)
                expect(legacyGroup4?.pointee).toNot(beNil())
                expect(String(libSessionVal: legacyGroup4?.pointee.enc_pubkey, fixedLength: 32)).to(equal(""))
                expect(String(libSessionVal: legacyGroup4?.pointee.enc_seckey, fixedLength: 32)).to(equal(""))
                expect(legacyGroup4?.pointee.disappearing_timer).to(equal(60))
                expect(String(libSessionVal: legacyGroup4?.pointee.session_id)).to(equal(definitelyRealId))
                expect(legacyGroup4?.pointee.priority).to(equal(3))
                expect(String(libSessionVal: legacyGroup4?.pointee.name)).to(equal("Englishmen"))
                expect(legacyGroup4?.pointee.joined_at).to(equal(createdTs))
                expect(legacyGroup2.pointee.notifications).to(equal(CONVO_NOTIFY_ALL))
                expect(legacyGroup2.pointee.mute_until).to(equal(nowTs + 3600))
                
                var membersSeen3: [String: Bool] = [:]
                var memberSessionId3: UnsafePointer<CChar>? = nil
                var memberAdmin3: Bool = false
                let membersIt3: OpaquePointer = ugroups_legacy_members_begin(legacyGroup4)
                
                while ugroups_legacy_members_next(membersIt3, &memberSessionId3, &memberAdmin3) {
                    membersSeen3[String(cString: memberSessionId3!)] = memberAdmin3
                }
                
                ugroups_legacy_members_free(membersIt3)
                ugroups_legacy_group_free(legacyGroup4)
                
                expect(membersSeen3).to(equal([
                    "050000000000000000000000000000000000000000000000000000000000000000": false,
                    "051111111111111111111111111111111111111111111111111111111111111111": false,
                    "052222222222222222222222222222222222222222222222222222222222222222": true
                ]))
                
                expect(config_needs_push(conf2)).to(beFalse())
                expect(config_needs_dump(conf2)).to(beFalse())
                
                let pushData5: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData5.pointee.seqno).to(equal(1))
                expect(config_needs_dump(conf2)).to(beFalse())
                pushData5.deallocate()
                
                for targetConf in [conf, conf2] {
                    // Iterate through and make sure we got everything we expected
                    var seen: [String] = []
                    
                    var c1: ugroups_legacy_group_info = ugroups_legacy_group_info()
                    var c2: ugroups_community_info = ugroups_community_info()
                    let it: OpaquePointer = user_groups_iterator_new(targetConf)
                    
                    while !user_groups_iterator_done(it) {
                        if user_groups_it_is_legacy_group(it, &c1) {
                            var memberCount: Int = 0
                            var adminCount: Int = 0
                            ugroups_legacy_members_count(&c1, &memberCount, &adminCount)
                            seen.append("legacy: \(String(libSessionVal: c1.name)), \(adminCount) admins, \(memberCount) members")
                        }
                        else if user_groups_it_is_community(it, &c2) {
                            seen.append("community: \(String(libSessionVal: c2.base_url))/r/\(String(libSessionVal: c2.room))")
                        }
                        else {
                            seen.append("unknown")
                        }
                        
                        user_groups_iterator_advance(it)
                    }
                    
                    user_groups_iterator_free(it)
                    
                    expect(seen).to(equal([
                        "community: http://example.org:5678/r/SudokuRoom",
                        "legacy: Englishmen, 1 admins, 2 members"
                    ]))
                }
                
                var cCommunity2BaseUrl: [CChar] = "http://example.org:5678".cString(using: .utf8)!
                var cCommunity2Room: [CChar] = "sudokuRoom".cString(using: .utf8)!
                var community2: ugroups_community_info = ugroups_community_info()
                expect(user_groups_get_community(conf2, &community2, &cCommunity2BaseUrl, &cCommunity2Room))
                    .to(beTrue())
                expect(String(libSessionVal: community2.base_url)).to(equal("http://example.org:5678"))
                expect(String(libSessionVal: community2.room)).to(equal("SudokuRoom")) // Case preserved from the stored value, not the input value
                expect(Data(libSessionVal: community2.pubkey, count: 32).toHexString())
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
                expect(community2.priority).to(equal(14))
                
                expect(config_needs_push(conf2)).to(beFalse())
                expect(config_needs_dump(conf2)).to(beFalse())
                
                let pushData6: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData6.pointee.seqno).to(equal(1))
                expect(config_needs_dump(conf2)).to(beFalse())
                pushData6.deallocate()
                
                community2.room = "sudokuRoom".toLibSession()  // Change capitalization
                user_groups_set_community(conf2, &community2)
                
                expect(config_needs_push(conf2)).to(beTrue())
                expect(config_needs_dump(conf2)).to(beTrue())
                
                let fakeHash2: String = "fakehash2"
                var cFakeHash2: [CChar] = fakeHash2.cString(using: .utf8)!
                let pushData7: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData7.pointee.seqno).to(equal(2))
                config_confirm_pushed(conf2, pushData7.pointee.seqno, &cFakeHash2)
                expect([String](pointer: pushData7.pointee.obsolete, count: pushData7.pointee.obsolete_len))
                    .to(equal([fakeHash1]))
                
                let currentHashes3: UnsafeMutablePointer<config_string_list>? = config_current_hashes(conf2)
                expect([String](pointer: currentHashes3?.pointee.value, count: currentHashes3?.pointee.len))
                    .to(equal([fakeHash2]))
                currentHashes3?.deallocate()
                
                var dump2: UnsafeMutablePointer<UInt8>? = nil
                var dump2Len: Int = 0
                config_dump(conf2, &dump2, &dump2Len)
                
                expect(config_needs_push(conf2)).to(beFalse())
                expect(config_needs_dump(conf2)).to(beFalse())
                
                let pushData8: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData8.pointee.seqno).to(equal(2))
                config_confirm_pushed(conf2, pushData8.pointee.seqno, &cFakeHash2)
                expect(config_needs_dump(conf2)).to(beFalse())
                
                var mergeHashes1: [UnsafePointer<CChar>?] = ((try? [cFakeHash2].unsafeCopyCStringArray()) ?? [])
                var mergeData1: [UnsafePointer<UInt8>?] = [UnsafePointer(pushData8.pointee.config)]
                var mergeSize1: [Int] = [pushData8.pointee.config_len]
                let mergedHashes1: UnsafeMutablePointer<config_string_list>? = config_merge(conf, &mergeHashes1, &mergeData1, &mergeSize1, 1)
                expect([String](pointer: mergedHashes1?.pointee.value, count: mergedHashes1?.pointee.len))
                    .to(equal(["fakehash2"]))
                mergeHashes1.forEach { $0?.deallocate() }
                mergedHashes1?.deallocate()
                pushData8.deallocate()
                
                var cCommunity3BaseUrl: [CChar] = "http://example.org:5678".cString(using: .utf8)!
                var cCommunity3Room: [CChar] = "SudokuRoom".cString(using: .utf8)!
                var community3: ugroups_community_info = ugroups_community_info()
                expect(user_groups_get_community(conf, &community3, &cCommunity3BaseUrl, &cCommunity3Room))
                    .to(beTrue())
                expect(String(libSessionVal: community3.room)).to(equal("sudokuRoom")) // We picked up the capitalization change
                
                expect(user_groups_size(conf)).to(equal(2))
                expect(user_groups_size_communities(conf)).to(equal(1))
                expect(user_groups_size_legacy_groups(conf)).to(equal(1))
                
                let legacyGroup5: UnsafeMutablePointer<ugroups_legacy_group_info>? = user_groups_get_legacy_group(conf2, &cDefinitelyRealId)
                expect(ugroups_legacy_member_add(legacyGroup5, &cUsers[4], false)).to(beTrue())
                expect(ugroups_legacy_member_add(legacyGroup5, &cUsers[5], true)).to(beTrue())
                expect(ugroups_legacy_member_add(legacyGroup5, &cUsers[6], true)).to(beTrue())
                expect(ugroups_legacy_member_remove(legacyGroup5, &cUsers[1])).to(beTrue())
                
                expect(config_needs_push(conf2)).to(beFalse())
                expect(config_needs_dump(conf2)).to(beFalse())
                
                let pushData9: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData9.pointee.seqno).to(equal(2))
                expect(config_needs_dump(conf2)).to(beFalse())
                pushData9.deallocate()
                
                user_groups_set_free_legacy_group(conf2, legacyGroup5)
                expect(config_needs_push(conf2)).to(beTrue())
                expect(config_needs_dump(conf2)).to(beTrue())
                
                var cCommunity4BaseUrl: [CChar] = "http://exAMple.ORG:5678".cString(using: .utf8)!
                var cCommunity4Room: [CChar] = "sudokuROOM".cString(using: .utf8)!
                user_groups_erase_community(conf2, &cCommunity4BaseUrl, &cCommunity4Room)
                
                let fakeHash3: String = "fakehash3"
                var cFakeHash3: [CChar] = fakeHash3.cString(using: .utf8)!
                let pushData10: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                config_confirm_pushed(conf2, pushData10.pointee.seqno, &cFakeHash3)
                
                expect(pushData10.pointee.seqno).to(equal(3))
                expect([String](pointer: pushData10.pointee.obsolete, count: pushData10.pointee.obsolete_len))
                    .to(equal([fakeHash2]))
                
                let currentHashes4: UnsafeMutablePointer<config_string_list>? = config_current_hashes(conf2)
                expect([String](pointer: currentHashes4?.pointee.value, count: currentHashes4?.pointee.len))
                    .to(equal([fakeHash3]))
                currentHashes4?.deallocate()
                
                var mergeHashes2: [UnsafePointer<CChar>?] = ((try? [cFakeHash3].unsafeCopyCStringArray()) ?? [])
                var mergeData2: [UnsafePointer<UInt8>?] = [UnsafePointer(pushData10.pointee.config)]
                var mergeSize2: [Int] = [pushData10.pointee.config_len]
                let mergedHashes2: UnsafeMutablePointer<config_string_list>? = config_merge(conf, &mergeHashes2, &mergeData2, &mergeSize2, 1)
                expect([String](pointer: mergedHashes2?.pointee.value, count: mergedHashes2?.pointee.len))
                    .to(equal(["fakehash3"]))
                mergeHashes2.forEach { $0?.deallocate() }
                mergedHashes2?.deallocate()
                
                expect(user_groups_size(conf)).to(equal(1))
                expect(user_groups_size_communities(conf)).to(equal(0))
                expect(user_groups_size_legacy_groups(conf)).to(equal(1))
                
                var prio: Int32 = 0
                var cBeanstalkBaseUrl: [CChar] = "http://jacksbeanstalk.org".cString(using: .utf8)!
                var cBeanstalkPubkey: [UInt8] = Array(Data(
                    hex: "0000111122223333444455556666777788889999aaaabbbbccccddddeeeeffff"
                ))
                
                ["fee", "fi", "fo", "fum"].forEach { room in
                    var cRoom: [CChar] = room.cString(using: .utf8)!
                    prio += 1
                    
                    var community4: ugroups_community_info = ugroups_community_info()
                    expect(user_groups_get_or_construct_community(conf, &community4, &cBeanstalkBaseUrl, &cRoom, &cBeanstalkPubkey))
                        .to(beTrue())
                    community4.priority = prio
                    user_groups_set_community(conf, &community4)
                }
                
                expect(user_groups_size(conf)).to(equal(5))
                expect(user_groups_size_communities(conf)).to(equal(4))
                expect(user_groups_size_legacy_groups(conf)).to(equal(1))
                
                let fakeHash4: String = "fakehash4"
                var cFakeHash4: [CChar] = fakeHash4.cString(using: .utf8)!
                let pushData11: UnsafeMutablePointer<config_push_data> = config_push(conf)
                config_confirm_pushed(conf, pushData11.pointee.seqno, &cFakeHash4)
                expect(pushData11.pointee.seqno).to(equal(4))
                expect([String](pointer: pushData11.pointee.obsolete, count: pushData11.pointee.obsolete_len))
                    .to(equal([fakeHash3, fakeHash2, fakeHash1]))
                
                // Load some obsolete ones in just to check that they get immediately obsoleted
                let fakeHash10: String = "fakehash10"
                let cFakeHash10: [CChar] = fakeHash10.cString(using: .utf8)!
                let fakeHash11: String = "fakehash11"
                let cFakeHash11: [CChar] = fakeHash11.cString(using: .utf8)!
                let fakeHash12: String = "fakehash12"
                let cFakeHash12: [CChar] = fakeHash12.cString(using: .utf8)!
                var mergeHashes3: [UnsafePointer<CChar>?] = ((try? [cFakeHash10, cFakeHash11, cFakeHash12, cFakeHash4].unsafeCopyCStringArray()) ?? [])
                var mergeData3: [UnsafePointer<UInt8>?] = [
                    UnsafePointer(pushData10.pointee.config),
                    UnsafePointer(pushData2.pointee.config),
                    UnsafePointer(pushData7.pointee.config),
                    UnsafePointer(pushData11.pointee.config)
                ]
                var mergeSize3: [Int] = [
                    pushData10.pointee.config_len,
                    pushData2.pointee.config_len,
                    pushData7.pointee.config_len,
                    pushData11.pointee.config_len
                ]
                let mergedHashes3: UnsafeMutablePointer<config_string_list>? = config_merge(conf2, &mergeHashes3, &mergeData3, &mergeSize3, 4)
                expect([String](pointer: mergedHashes3?.pointee.value, count: mergedHashes3?.pointee.len))
                    .to(equal(["fakehash10", "fakehash11", "fakehash12", "fakehash4"]))
                expect(config_needs_dump(conf2)).to(beTrue())
                expect(config_needs_push(conf2)).to(beFalse())
                mergeHashes3.forEach { $0?.deallocate() }
                mergedHashes3?.deallocate()
                pushData2.deallocate()
                pushData7.deallocate()
                pushData10.deallocate()
                pushData11.deallocate()
                
                let currentHashes5: UnsafeMutablePointer<config_string_list>? = config_current_hashes(conf2)
                expect([String](pointer: currentHashes5?.pointee.value, count: currentHashes5?.pointee.len))
                    .to(equal([fakeHash4]))
                currentHashes5?.deallocate()
                
                let pushData12: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData12.pointee.seqno).to(equal(4))
                expect([String](pointer: pushData12.pointee.obsolete, count: pushData12.pointee.obsolete_len))
                    .to(equal([fakeHash11, fakeHash12, fakeHash10, fakeHash3]))
                pushData12.deallocate()
                
                for targetConf in [conf, conf2] {
                    // Iterate through and make sure we got everything we expected
                    var seen: [String] = []
                    
                    var c1: ugroups_legacy_group_info = ugroups_legacy_group_info()
                    var c2: ugroups_community_info = ugroups_community_info()
                    let it: OpaquePointer = user_groups_iterator_new(targetConf)
                    
                    while !user_groups_iterator_done(it) {
                        if user_groups_it_is_legacy_group(it, &c1) {
                            var memberCount: Int = 0
                            var adminCount: Int = 0
                            ugroups_legacy_members_count(&c1, &memberCount, &adminCount)
                            
                            seen.append("legacy: \(String(libSessionVal: c1.name)), \(adminCount) admins, \(memberCount) members")
                        }
                        else if user_groups_it_is_community(it, &c2) {
                            seen.append("community: \(String(libSessionVal: c2.base_url))/r/\(String(libSessionVal: c2.room))")
                        }
                        else {
                            seen.append("unknown")
                        }
                        
                        user_groups_iterator_advance(it)
                    }
                    
                    user_groups_iterator_free(it)
                    
                    expect(seen).to(equal([
                        "community: http://jacksbeanstalk.org/r/fee",
                        "community: http://jacksbeanstalk.org/r/fi",
                        "community: http://jacksbeanstalk.org/r/fo",
                        "community: http://jacksbeanstalk.org/r/fum",
                        "legacy: Englishmen, 3 admins, 2 members"
                    ]))
                }
            }
        }
    }
}
