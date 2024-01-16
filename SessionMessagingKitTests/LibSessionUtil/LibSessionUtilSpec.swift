// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

class LibSessionUtilSpec: QuickSpec {
    static let maxMessageSizeBytes: Int = 76800  // Storage server's limit, should match `config.hpp` in libSession
    
    static let userSeed: Data = Data(hex: "0123456789abcdef0123456789abcdef")
    static let seed: Data = Data(hex: "0123456789abcdef0123456789abcdeffedcba9876543210fedcba9876543210")
    static let identity: (ed25519KeyPair: KeyPair, x25519KeyPair: KeyPair) = try! Identity.generate(from: userSeed)
    static let keyPair: KeyPair = Crypto().generate(.ed25519KeyPair(seed: Array(seed)))!
    static let userEdSK: [UInt8] = identity.ed25519KeyPair.secretKey
    static let edPK: [UInt8] = keyPair.publicKey
    static let edSK: [UInt8] = keyPair.secretKey
    
    // Since we can't test the group without encryption keys and the C API doesn't have
    // a way to manually provide encryption keys we needed to create a dump with valid
    // key data and load that in so we can test the other cases, this dump contains a
    // single admin member and a single encryption key
    static let groupKeysDump: Data = Data(hex:
        "64363a6163746976656c65343a6b6579736c65373a70656e64696e6764313a633136373a" +
        "64313a2332343ae3abc434666653cb7e913a3101b83704e86a7395ac21a026313a476930" +
        "65313a4b34383a150c55d933f0c44d1e2527590ae8efbb482f17e04e2a6a3a23f7e900ad" +
        "2f69f9442fcd4e2fc623e63d7ccaf9a79ffcac313a6b6c65313a7e36343a64d960c70ff1" +
        "2967b677a8a2ce6e624e1da4c8e372c56d8c8e212ea6b420359e4b244efcb3f5cac8a86d" +
        "4bfe9dcb6fe9bbdfc98180851decf965dc6a6d2dce0865313a67693065313a6b33323a3e" +
        "c807213e56d2e3ddcf5096ae414db1689d2f436a6e6ec8e9178b4205e65f926565"
    )
    
    override class func spec() {
        // MARK: - libSession
        describe("libSession") {
            contactsSpec()
            userProfileSpec()
            convoInfoVolatileSpec()
            userGroupsSpec()
            groupInfoSpec()
            groupMembersSpec()
            groupKeysSpec()
            
            // MARK: -- has correct test seed data
            it("has correct test seed data") {
                expect(LibSessionUtilSpec.userEdSK.toHexString().suffix(64))
                    .to(equal("4cb76fdc6d32278e3f83dbf608360ecc6b65727934b85d2fb86862ff98c46ab7"))
                expect(LibSessionUtilSpec.identity.x25519KeyPair.publicKey.toHexString())
                    .to(equal("d2ad010eeb72d72e561d9de7bd7b6989af77dcabffa03a5111a6c859ae5c3a72"))
                expect(String(LibSessionUtilSpec.userEdSK.toHexString().prefix(32)))
                    .to(equal(LibSessionUtilSpec.userSeed.toHexString()))
                
                expect(LibSessionUtilSpec.edPK.toHexString())
                    .to(equal("cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"))
                expect(String(Data(LibSessionUtilSpec.edSK.prefix(32)).toHexString()))
                    .to(equal(LibSessionUtilSpec.seed.toHexString()))
            }
            
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
    }

    class func contactsSpec() {
        context("CONTACTS") {
            @TestState var userEdSK: [UInt8]! = LibSessionUtilSpec.userEdSK
            @TestState var error: [CChar]! = [CChar](repeating: 0, count: 256)
            @TestState var conf: UnsafeMutablePointer<config_object>?
            @TestState var initResult: Int32! = { contacts_init(&conf, &userEdSK, nil, 0, &error) }()
            @TestState var numRecords: Int! = 0
            @TestState var randomGenerator: ARC4RandomNumberGenerator! = ARC4RandomNumberGenerator(seed: 1000)
            
            // MARK: -- when checking error catching
            context("when checking error catching") {
                // MARK: ---- it can catch size limit errors thrown when pushing
                it("can catch size limit errors thrown when pushing") {
                    try (0..<2500).forEach { index in
                        var contact: contacts_contact = try createContact(
                            for: index,
                            in: conf,
                            rand: &randomGenerator,
                            maxing: .allProperties
                        )
                        contacts_set(conf, &contact)
                    }
                    
                    expect(contacts_size(conf)).to(equal(2500))
                    expect(config_needs_push(conf)).to(beTrue())
                    expect(config_needs_dump(conf)).to(beTrue())
                    
                    expect {
                        try CExceptionHelper.performSafely { config_push(conf).deallocate() }
                    }
                    .to(throwError(NSError(domain: "cpp_exception", code: -2, userInfo: ["NSLocalizedDescription": "Config data is too large"])))
                }
            }
            
            // MARK: -- when checking size limits
            context("when checking size limits") {
                // MARK: ---- has not changed the max empty records
                it("has not changed the max empty records") {
                    for index in (0..<2500) {
                        var contact: contacts_contact = try createContact(
                            for: index,
                            in: conf,
                            rand: &randomGenerator
                        )
                        contacts_set(conf, &contact)
                        
                        do { try CExceptionHelper.performSafely { config_push(conf).deallocate() } }
                        catch { break }
                        
                        // We successfully inserted a contact and didn't hit the limit so increment the counter
                        numRecords += 1
                    }
                    
                    // Check that the record count matches the maximum when we last checked
                    expect(numRecords).to(equal(2212))
                }
                
                // MARK: ---- has not changed the max name only records
                it("has not changed the max name only records") {
                    for index in (0..<2500) {
                        var contact: contacts_contact = try createContact(
                            for: index,
                            in: conf,
                            rand: &randomGenerator,
                            maxing: [.name]
                        )
                        contacts_set(conf, &contact)
                        
                        do { try CExceptionHelper.performSafely { config_push(conf).deallocate() } }
                        catch { break }
                        
                        // We successfully inserted a contact and didn't hit the limit so increment the counter
                        numRecords += 1
                    }
                    
                    // Check that the record count matches the maximum when we last checked
                    expect(numRecords).to(equal(742))
                }
                
                // MARK: ---- has not changed the max name and profile pic only records
                it("has not changed the max name and profile pic only records") {
                    for index in (0..<2500) {
                        var contact: contacts_contact = try createContact(
                            for: index,
                            in: conf,
                            rand: &randomGenerator,
                            maxing: [.name, .profile_pic]
                        )
                        contacts_set(conf, &contact)
                        
                        do { try CExceptionHelper.performSafely { config_push(conf).deallocate() } }
                        catch { break }
                        
                        // We successfully inserted a contact and didn't hit the limit so increment the counter
                        numRecords += 1
                    }
                    
                    // Check that the record count matches the maximum when we last checked
                    expect(numRecords).to(equal(270))
                }
                
                // MARK: ---- has not changed the max filled records
                it("has not changed the max filled records") {
                    for index in (0..<2500) {
                        var contact: contacts_contact = try createContact(
                            for: index,
                            in: conf,
                            rand: &randomGenerator,
                            maxing: .allProperties
                        )
                        contacts_set(conf, &contact)
                        
                        do { try CExceptionHelper.performSafely { config_push(conf).deallocate() } }
                        catch { break }
                        
                        // We successfully inserted a contact and didn't hit the limit so increment the counter
                        numRecords += 1
                    }
                    
                    // Check that the record count matches the maximum when we last checked
                    expect(numRecords).to(equal(220))
                }
            }
            
            // MARK: -- generates config correctly
            
            it("generates config correctly") {
                let createdTs: Int64 = 1680064059
                let nowTs: Int64 = Int64(Date().timeIntervalSince1970)
                expect(initResult).to(equal(0))
                
                // Empty contacts shouldn't have an existing contact
                let definitelyRealId: String = "050000000000000000000000000000000000000000000000000000000000000000"
                var cDefinitelyRealId: [CChar] = definitelyRealId.cArray.nullTerminated()
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
                var cFakeHash1: [CChar] = fakeHash1.cArray.nullTerminated()
                config_confirm_pushed(conf, pushData2.pointee.seqno, &cFakeHash1)
                expect(config_needs_push(conf)).to(beFalse())
                expect(config_needs_dump(conf)).to(beTrue())
                pushData2.deallocate()
                
                // NB: Not going to check encrypted data and decryption here because that's general (not
                // specific to contacts) and is covered already in the user profile tests.
                var dump1: UnsafeMutablePointer<UInt8>? = nil
                var dump1Len: Int = 0
                config_dump(conf, &dump1, &dump1Len)
                
                var error2: [CChar] = [CChar](repeating: 0, count: 256)
                var conf2: UnsafeMutablePointer<config_object>? = nil
                expect(contacts_init(&conf2, &userEdSK, dump1, dump1Len, &error2)).to(equal(0))
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
                var cAnotherId: [CChar] = anotherId.cArray.nullTerminated()
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
                var cFakeHash2: [CChar] = fakeHash2.cArray.nullTerminated()
                var mergeHashes: [UnsafePointer<CChar>?] = [cFakeHash2].unsafeCopy()
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
                var cThirdId: [CChar] = thirdId.cArray.nullTerminated()
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
                var cFakeHash3a: [CChar] = fakeHash3a.cArray.nullTerminated()
                let fakeHash3b: String = "fakehash3b"
                var cFakeHash3b: [CChar] = fakeHash3b.cArray.nullTerminated()
                config_confirm_pushed(conf, pushData6.pointee.seqno, &cFakeHash3a)
                config_confirm_pushed(conf2, pushData7.pointee.seqno, &cFakeHash3b)
                
                var mergeHashes2: [UnsafePointer<CChar>?] = [cFakeHash3b].unsafeCopy()
                var mergeData2: [UnsafePointer<UInt8>?] = [UnsafePointer(pushData7.pointee.config)]
                var mergeSize2: [Int] = [pushData7.pointee.config_len]
                let mergedHashes2: UnsafeMutablePointer<config_string_list>? = config_merge(conf, &mergeHashes2, &mergeData2, &mergeSize2, 1)
                expect([String](pointer: mergedHashes2?.pointee.value, count: mergedHashes2?.pointee.len))
                    .to(equal(["fakehash3b"]))
                expect(config_needs_push(conf)).to(beTrue())
                mergeHashes2.forEach { $0?.deallocate() }
                mergedHashes2?.deallocate()
                pushData7.deallocate()
                
                var mergeHashes3: [UnsafePointer<CChar>?] = [cFakeHash3a].unsafeCopy()
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
                var cFakeHash4: [CChar] = fakeHash4.cArray.nullTerminated()
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
        var cSessionId: [CChar] = sessionId.cArray.nullTerminated()
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
                
                case .name:
                    contact.name = rand.nextBytes(count: LibSession.sizeMaxNameBytes)
                        .toHexString()
                        .toLibSession()
                
                case .nickname:
                    contact.nickname = rand.nextBytes(count: LibSession.sizeMaxNicknameBytes)
                        .toHexString()
                        .toLibSession()
                    
                case .profile_pic:
                    contact.profile_pic = user_profile_pic(
                        url: rand.nextBytes(count: LibSession.sizeMaxProfileUrlBytes)
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
            @TestState var userEdSK: [UInt8]! = LibSessionUtilSpec.userEdSK
            @TestState var error: [CChar]! = [CChar](repeating: 0, count: 256)
            @TestState var conf: UnsafeMutablePointer<config_object>?
            @TestState var initResult: Int32! = { user_profile_init(&conf, &userEdSK, nil, 0, &error) }()
            
            // MARK: -- generates config correctly
            it("generates config correctly") {
                expect(initResult).to(equal(0))
                
                // We don't need to push anything, since this is an empty config
                expect(config_needs_push(conf)).to(beFalse())
                // And we haven't changed anything so don't need to dump to db
                expect(config_needs_dump(conf)).to(beFalse())
                
                // Since it's empty there shouldn't be a name.
                let namePtr: UnsafePointer<CChar>? = user_profile_get_name(conf)
                expect(namePtr).to(beNil())
                
                // We don't need to push since we haven't changed anything, so this call is mainly just for
                // testing:
                let PROTOBUF_OVERHEAD: Int = 176  // To be removed once we no longer protobuf wrap this
                let pushData1: UnsafeMutablePointer<config_push_data> = config_push(conf)
                expect(pushData1.pointee).toNot(beNil())
                expect(pushData1.pointee.seqno).to(equal(0))
                expect(pushData1.pointee.config_len).to(equal(256 + PROTOBUF_OVERHEAD))
                expect(String(cString: config_encryption_domain(conf))).to(equal("UserProfile"))
                
                // There's nothing particularly profound about this value (it is multiple layers of nested
                // protobuf with some encryption and padding halfway through); this test is just here to ensure
                // that our pushed messages are deterministic:
                let expectedPushData1: Data = Data(hex: [
                    "080112ab030a0012001aa20308062801429b0326ec9746282053eb119228e6c36012966e7d2642163169ba39" +
                    "98af44ca65f967768dd78ee80fffab6f809f6cef49c73a36c82a89622ff0de2ceee06b8c638e2c876fa9047f" +
                    "449dbe24b1fc89281a264fe90abdeffcdd44f797bd4572a6c5ae8d88bf372c3c717943ebd570222206fabf0e" +
                    "e9f3c6756f5d71a32616b1df53d12887961f5c129207a79622ccc1a4bba976886d9a6ddf0fe5d570e5075d01" +
                    "ecd627f656e95f27b4c40d5661b5664cedd3e568206effa1308b0ccd663ca61a6d39c0731891804a8cf5edcf" +
                    "8b98eaa5580c3d436e22156e38455e403869700956c3c1dd0b4470b663e75c98c5b859b53ccef6559215d804" +
                    "9f755be9c2d6b3f4a310f97c496fc392f65b6431dd87788ac61074fd8cd409702e1b839b3f774d38cf8b28f0" +
                    "226c4efa5220ac6ae060793e36e7ef278d42d042f15b21291f3bb29e3158f09d154b93f83fd8a319811a26cb" +
                    "5240d90cbb360fafec0b7eff4c676ae598540813d062dc9468365c73b4cfa2ffd02d48cdcd8f0c71324c6d0a" +
                    "60346a7a0e50af3be64684b37f9e6c831115bf112ddd18acde08eaec376f0872a3952000"
                ].joined())
                
                expect(Data(bytes: pushData1.pointee.config, count: pushData1.pointee.config_len))
                    .to(equal(expectedPushData1))
                pushData1.deallocate()
                
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
                expect(Data(libSessionVal: pic2.key, count: DisplayPictureManager.aes256KeyByteLength))
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
                
                // Note: This hex value differs from the value in the library tests because
                // it looks like the library has an "end of cell mark" character added at the
                // end (0x07 or '0007') so we need to manually add it to work
                let expHash0: [UInt8] = Data(hex: "ea173b57beca8af18c3519a7bbf69c3e7a05d1c049fa9558341d8ebb48b0c965")
                    .bytes
                // The data to be actually pushed, expanded like this to make it somewhat human-readable:
                let expPush1Decrypted: [UInt8] = ["""
                    d
                      1:#i1e
                      1:& d
                        1:+ i9e
                        1:n 6:Kallie
                        1:p 34:http://example.org/omg-pic-123.bmp
                        1:q 32:secret78901234567890123456789012
                      e
                      1:< l
                        l i0e 32:
                """.removeCharacters(characterSet: CharacterSet.whitespacesAndNewlines) // For readability
                    .bytes,
                expHash0,
                """
                de e
                      e
                      1:= d
                        1:+ 0:
                        1:n 0:
                        1:p 0:
                        1:q 0:
                      e
                    e
                """.removeCharacters(characterSet: CharacterSet.whitespacesAndNewlines) // For readability
                    .bytes
                ].flatMap { $0 }
                let expPush1Encrypted: [UInt8] = Data(hex: [
                    "9693a69686da3055f1ecdfb239c3bf8e746951a36d888c2fb7c02e856a5c2091b24e39a7e1af828f",
                    "1fa09fe8bf7d274afde0a0847ba143c43ffb8722301b5ae32e2f078b9a5e19097403336e50b18c84",
                    "aade446cd2823b011f97d6ad2116a53feb814efecc086bc172d31f4214b4d7c630b63bbe575b0868",
                    "2d146da44915063a07a78556ab5eff4f67f6aa26211e8d330b53d28567a931028c393709a325425d",
                    "e7486ccde24416a7fd4a8ba5fa73899c65f4276dfaddd5b2100adcf0f793104fb235b31ce32ec656",
                    "056009a9ebf58d45d7d696b74e0c7ff0499c4d23204976f19561dc0dba6dc53a2497d28ce03498ea",
                    "49bf122762d7bc1d6d9c02f6d54f8384"
                ].joined()).bytes
                
                // We haven't dumped, so still need to dump:
                expect(config_needs_dump(conf)).to(beTrue())
                // We did call push, but we haven't confirmed it as stored yet, so this will still return true:
                expect(config_needs_push(conf)).to(beTrue())
                
                var dump1: UnsafeMutablePointer<UInt8>? = nil
                var dump1Len: Int = 0
                
                config_dump(conf, &dump1, &dump1Len)
                // (in a real client we'd now store this to disk)
                
                expect(config_needs_dump(conf)).to(beFalse())
                
                let expDump1: [CChar] = [
                    """
                        d
                          1:! i2e
                          1:$ \(expPush1Decrypted.count):
                    """
                        .removeCharacters(characterSet: CharacterSet.whitespacesAndNewlines)
                        .bytes
                        .map { CChar(bitPattern: $0) },
                    expPush1Decrypted
                        .map { CChar(bitPattern: $0) },
                    """
                          1:(0:
                          1:)le
                        e
                    """.removeCharacters(characterSet: CharacterSet.whitespacesAndNewlines)
                        .bytes
                        .map { CChar(bitPattern: $0) }
                ].flatMap { $0 }
                expect(String(pointer: dump1, length: dump1Len, encoding: .ascii))
                    .to(equal(String(pointer: expDump1, length: expDump1.count, encoding: .ascii)))
                dump1?.deallocate()
                
                // So now imagine we got back confirmation from the swarm that the push has been stored:
                let fakeHash1: String = "fakehash1"
                var cFakeHash1: [CChar] = fakeHash1.cArray.nullTerminated()
                config_confirm_pushed(conf, pushData2.pointee.seqno, &cFakeHash1)
                pushData2.deallocate()
                
                expect(config_needs_push(conf)).to(beFalse())
                expect(config_needs_dump(conf)).to(beTrue()) // The confirmation changes state, so this makes us need a dump
                
                var dump2: UnsafeMutablePointer<UInt8>? = nil
                var dump2Len: Int = 0
                config_dump(conf, &dump2, &dump2Len)
                
                let expDump2: [CChar] = [
                    """
                        d
                          1:! i0e
                          1:$ \(expPush1Decrypted.count):
                    """
                        .removeCharacters(characterSet: CharacterSet.whitespacesAndNewlines)
                        .bytes
                        .map { CChar(bitPattern: $0) },
                    expPush1Decrypted
                        .map { CChar(bitPattern: $0) },
                    """
                          1:(9:fakehash1
                          1:)le
                        e
                    """.removeCharacters(characterSet: CharacterSet.whitespacesAndNewlines)
                        .bytes
                        .map { CChar(bitPattern: $0) }
                ].flatMap { $0 }
                expect(String(pointer: dump2, length: dump2Len, encoding: .ascii))
                    .to(equal(String(pointer: expDump2, length: expDump2.count, encoding: .ascii)))
                dump2?.deallocate()
                expect(config_needs_dump(conf)).to(beFalse())
                
                // Now we're going to set up a second, competing config object (in the real world this would be
                // another Session client somewhere).
                
                // Start with an empty config, as above:
                var error2: [CChar] = [CChar](repeating: 0, count: 256)
                var conf2: UnsafeMutablePointer<config_object>? = nil
                expect(user_profile_init(&conf2, &userEdSK, nil, 0, &error2)).to(equal(0))
                expect(config_needs_dump(conf2)).to(beFalse())
                
                // Now imagine we just pulled down the encrypted string from the swarm; we merge it into conf2:
                var mergeHashes: [UnsafePointer<CChar>?] = [cFakeHash1].unsafeCopy()
                var mergeData: [UnsafePointer<UInt8>?] = [expPush1Encrypted].unsafeCopy()
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
                var cFakeHash2: [CChar] = fakeHash2.cArray.nullTerminated()
                let pushData3: UnsafeMutablePointer<config_push_data> = config_push(conf)
                expect(pushData3.pointee.seqno).to(equal(2)) // incremented, since we made a field change
                config_confirm_pushed(conf, pushData3.pointee.seqno, &cFakeHash2)
                
                let fakeHash3: String = "fakehash3"
                var cFakeHash3: [CChar] = fakeHash3.cArray.nullTerminated()
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
                var mergeHashes2: [UnsafePointer<CChar>?] = [cFakeHash2].unsafeCopy()
                var mergeData2: [UnsafePointer<UInt8>?] = [UnsafePointer(pushData3.pointee.config)]
                var mergeSize2: [Int] = [pushData3.pointee.config_len]
                let mergedHashes2: UnsafeMutablePointer<config_string_list>? = config_merge(conf2, &mergeHashes2, &mergeData2, &mergeSize2, 1)
                expect([String](pointer: mergedHashes2?.pointee.value, count: mergedHashes2?.pointee.len))
                    .to(equal(["fakehash2"]))
                mergeHashes2.forEach { $0?.deallocate() }
                mergedHashes2?.deallocate()
                pushData3.deallocate()
                
                var mergeHashes3: [UnsafePointer<CChar>?] = [cFakeHash3].unsafeCopy()
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
                var cFakeHash4: [CChar] = fakeHash4.cArray.nullTerminated()
                let fakeHash5: String = "fakehash5"
                var cFakeHash5: [CChar] = fakeHash5.cArray.nullTerminated()
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
            @TestState var userEdSK: [UInt8]! = LibSessionUtilSpec.userEdSK
            @TestState var error: [CChar]! = [CChar](repeating: 0, count: 256)
            @TestState var conf: UnsafeMutablePointer<config_object>?
            @TestState var initResult: Int32! = {
                convo_info_volatile_init(&conf, &userEdSK, nil, 0, &error)
            }()
            
            // MARK: -- generates config correctly
            it("generates config correctly") {
                expect(initResult).to(equal(0))
                
                // Empty contacts shouldn't have an existing contact
                let definitelyRealId: String = "055000000000000000000000000000000000000000000000000000000000000000"
                var cDefinitelyRealId: [CChar] = definitelyRealId.cArray.nullTerminated()
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
                var cOpenGroupBaseUrl: [CChar] = openGroupBaseUrl.cArray.nullTerminated()
                let openGroupBaseUrlResult: String = openGroupBaseUrl.lowercased()
                //            ("http://Example.ORG:5678"
                //                .lowercased()
                //                .cArray +
                //                [CChar](repeating: 0, count: (268 - openGroupBaseUrl.count))
                //            )
                let openGroupRoom: String = "SudokuRoom"
                var cOpenGroupRoom: [CChar] = openGroupRoom.cArray.nullTerminated()
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
                var cFakeHash1: [CChar] = fakeHash1.cArray.nullTerminated()
                config_confirm_pushed(conf, pushData1.pointee.seqno, &cFakeHash1)
                expect(config_needs_dump(conf)).to(beTrue())
                expect(config_needs_push(conf)).to(beFalse())
                pushData1.deallocate()
                
                var dump1: UnsafeMutablePointer<UInt8>? = nil
                var dump1Len: Int = 0
                config_dump(conf, &dump1, &dump1Len)
                
                var error2: [CChar] = [CChar](repeating: 0, count: 256)
                var conf2: UnsafeMutablePointer<config_object>? = nil
                expect(convo_info_volatile_init(&conf2, &userEdSK, dump1, dump1Len, &error2)).to(equal(0))
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
                var cAnotherId: [CChar] = anotherId.cArray.nullTerminated()
                var oneToOne5: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                expect(convo_info_volatile_get_or_construct_1to1(conf2, &oneToOne5, &cAnotherId)).to(beTrue())
                oneToOne5.unread = true
                convo_info_volatile_set_1to1(conf2, &oneToOne5)
                
                let thirdId: String = "05cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
                var cThirdId: [CChar] = thirdId.cArray.nullTerminated()
                var legacyGroup2: convo_info_volatile_legacy_group = convo_info_volatile_legacy_group()
                expect(convo_info_volatile_get_or_construct_legacy_group(conf2, &legacyGroup2, &cThirdId)).to(beTrue())
                legacyGroup2.last_read = (nowTimestampMs - 50)
                convo_info_volatile_set_legacy_group(conf2, &legacyGroup2)
                expect(config_needs_push(conf2)).to(beTrue())
                
                let pushData2: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData2.pointee.seqno).to(equal(2))
                
                // Check the merging
                let fakeHash2: String = "fakehash2"
                var cFakeHash2: [CChar] = fakeHash2.cArray.nullTerminated()
                var mergeHashes: [UnsafePointer<CChar>?] = [cFakeHash2].unsafeCopy()
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
                var cFourthId: [CChar] = fourthId.cArray.nullTerminated()
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
            @TestState var userEdSK: [UInt8]! = LibSessionUtilSpec.userEdSK
            @TestState var error: [CChar]! = [CChar](repeating: 0, count: 256)
            @TestState var conf: UnsafeMutablePointer<config_object>?
            @TestState var initResult: Int32! = { user_groups_init(&conf, &userEdSK, nil, 0, &error) }()
            
            // MARK: -- generates config correctly
            it("generates config correctly") {
                let createdTs: Int64 = 1680064059
                let nowTs: Int64 = Int64(Date().timeIntervalSince1970)
                expect(initResult).to(equal(0))
                
                // Empty contacts shouldn't have an existing contact
                let definitelyRealId: String = "055000000000000000000000000000000000000000000000000000000000000000"
                var cDefinitelyRealId: [CChar] = definitelyRealId.cArray.nullTerminated()
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
                expect(legacyGroup2.pointee.invited).to(beFalse())
                
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
                var cUsers: [[CChar]] = users.map { $0.cArray.nullTerminated() }
                legacyGroup2.pointee.name = "Englishmen".toLibSession()
                legacyGroup2.pointee.disappearing_timer = 60
                legacyGroup2.pointee.joined_at = createdTs
                legacyGroup2.pointee.notifications = CONVO_NOTIFY_ALL
                legacyGroup2.pointee.mute_until = (nowTs + 3600)
                legacyGroup2.pointee.invited = true
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
                
                let groupSeed: Data = Data(hex: "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
                let groupEd25519KeyPair: KeyPair = Crypto().generate(.ed25519KeyPair(seed: Array(groupSeed)))!
                let groupX25519PublicKey: [UInt8] = Crypto().generate(.x25519(ed25519Pubkey: groupEd25519KeyPair.publicKey))!
                
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
                var cCommunityPubkey: [UInt8] = Data(hex: communityPubkey).cArray
                var cCommunityBaseUrl: [CChar] = "http://Example.ORG:5678".cArray.nullTerminated()
                var cCommunityRoom: [CChar] = "SudokuRoom".cArray.nullTerminated()
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
                var cFakeHash1: [CChar] = fakeHash1.cArray.nullTerminated()
                config_confirm_pushed(conf, pushData2.pointee.seqno, &cFakeHash1)
                expect(config_needs_dump(conf)).to(beTrue())
                expect(config_needs_push(conf)).to(beFalse())
                
                var dump1: UnsafeMutablePointer<UInt8>? = nil
                var dump1Len: Int = 0
                config_dump(conf, &dump1, &dump1Len)
                
                var error2: [CChar] = [CChar](repeating: 0, count: 256)
                var conf2: UnsafeMutablePointer<config_object>? = nil
                expect(user_groups_init(&conf2, &userEdSK, dump1, dump1Len, &error2)).to(equal(0))
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
                expect(legacyGroup4?.pointee.notifications).to(equal(CONVO_NOTIFY_ALL))
                expect(legacyGroup4?.pointee.mute_until).to(equal(nowTs + 3600))
                expect(legacyGroup4?.pointee.invited).to(beTrue())
                
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
                
                var cCommunity2BaseUrl: [CChar] = "http://example.org:5678".cArray.nullTerminated()
                var cCommunity2Room: [CChar] = "sudokuRoom".cArray.nullTerminated()
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
                var cFakeHash2: [CChar] = fakeHash2.cArray.nullTerminated()
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
                
                var mergeHashes1: [UnsafePointer<CChar>?] = [cFakeHash2].unsafeCopy()
                var mergeData1: [UnsafePointer<UInt8>?] = [UnsafePointer(pushData8.pointee.config)]
                var mergeSize1: [Int] = [pushData8.pointee.config_len]
                let mergedHashes1: UnsafeMutablePointer<config_string_list>? = config_merge(conf, &mergeHashes1, &mergeData1, &mergeSize1, 1)
                expect([String](pointer: mergedHashes1?.pointee.value, count: mergedHashes1?.pointee.len))
                    .to(equal(["fakehash2"]))
                mergeHashes1.forEach { $0?.deallocate() }
                mergedHashes1?.deallocate()
                pushData8.deallocate()
                
                var cCommunity3BaseUrl: [CChar] = "http://example.org:5678".cArray.nullTerminated()
                var cCommunity3Room: [CChar] = "SudokuRoom".cArray.nullTerminated()
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
                
                var cCommunity4BaseUrl: [CChar] = "http://exAMple.ORG:5678".cArray.nullTerminated()
                var cCommunity4Room: [CChar] = "sudokuROOM".cArray.nullTerminated()
                user_groups_erase_community(conf2, &cCommunity4BaseUrl, &cCommunity4Room)
                
                let fakeHash3: String = "fakehash3"
                var cFakeHash3: [CChar] = fakeHash3.cArray.nullTerminated()
                let pushData10: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                config_confirm_pushed(conf2, pushData10.pointee.seqno, &cFakeHash3)
                
                expect(pushData10.pointee.seqno).to(equal(3))
                expect([String](pointer: pushData10.pointee.obsolete, count: pushData10.pointee.obsolete_len))
                    .to(equal([fakeHash2]))
                
                let currentHashes4: UnsafeMutablePointer<config_string_list>? = config_current_hashes(conf2)
                expect([String](pointer: currentHashes4?.pointee.value, count: currentHashes4?.pointee.len))
                    .to(equal([fakeHash3]))
                currentHashes4?.deallocate()
                
                var mergeHashes2: [UnsafePointer<CChar>?] = [cFakeHash3].unsafeCopy()
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
                var cBeanstalkBaseUrl: [CChar] = "http://jacksbeanstalk.org".cArray.nullTerminated()
                var cBeanstalkPubkey: [UInt8] = Data(
                    hex: "0000111122223333444455556666777788889999aaaabbbbccccddddeeeeffff"
                ).cArray
                
                ["fee", "fi", "fo", "fum"].forEach { room in
                    var cRoom: [CChar] = room.cArray.nullTerminated()
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
                var cFakeHash4: [CChar] = fakeHash4.cArray.nullTerminated()
                let pushData11: UnsafeMutablePointer<config_push_data> = config_push(conf)
                config_confirm_pushed(conf, pushData11.pointee.seqno, &cFakeHash4)
                expect(pushData11.pointee.seqno).to(equal(4))
                expect([String](pointer: pushData11.pointee.obsolete, count: pushData11.pointee.obsolete_len))
                    .to(equal([fakeHash3, fakeHash2, fakeHash1]))
                
                // Load some obsolete ones in just to check that they get immediately obsoleted
                let fakeHash10: String = "fakehash10"
                let cFakeHash10: [CChar] = fakeHash10.cArray.nullTerminated()
                let fakeHash11: String = "fakehash11"
                let cFakeHash11: [CChar] = fakeHash11.cArray.nullTerminated()
                let fakeHash12: String = "fakehash12"
                let cFakeHash12: [CChar] = fakeHash12.cArray.nullTerminated()
                var mergeHashes3: [UnsafePointer<CChar>?] = [cFakeHash10, cFakeHash11, cFakeHash12, cFakeHash4].unsafeCopy()
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

// MARK: - GROUP_INFO

fileprivate extension LibSessionUtilSpec {
    class func groupInfoSpec() {
        context("GROUP_INFO") {
            @TestState var userEdSK: [UInt8]! = LibSessionUtilSpec.userEdSK
            @TestState var edPK: [UInt8]! = LibSessionUtilSpec.edPK
            @TestState var edSK: [UInt8]! = LibSessionUtilSpec.edSK
            @TestState var error: [CChar]! = [CChar](repeating: 0, count: 256)
            @TestState var infoConf: UnsafeMutablePointer<config_object>?
            @TestState var membersConf: UnsafeMutablePointer<config_object>?
            @TestState var keysConf: UnsafeMutablePointer<config_group_keys>?
            @TestState var infoInitResult: Int32! = {
                groups_info_init(&infoConf, &edPK, &edSK, nil, 0, &error)
            }()
            @TestState var membersInitResult: Int32! = {
                groups_members_init(&membersConf, &edPK, &edSK, nil, 0, &error)
            }()
            @TestState var keysInitResult: Int32! = {
                LibSessionUtilSpec.initKeysConf(&keysConf, &infoConf, &membersConf)
            }()
            
            @TestState var infoConf2: UnsafeMutablePointer<config_object>?
            @TestState var keysConf2: UnsafeMutablePointer<config_group_keys>?
            @TestState var infoInitResult2: Int32! = {
                groups_info_init(&infoConf2, &edPK, &edSK, nil, 0, &error)
            }()
            @TestState var keysInitResult2: Int32! = {
                LibSessionUtilSpec.initKeysConf(&keysConf2, &infoConf2, &membersConf)
            }()
            
            // Convenience
            var conf: UnsafeMutablePointer<config_object>? { infoConf }
            var conf2: UnsafeMutablePointer<config_object>? { infoConf2 }
            
            // MARK: -- generates config correctly
            it("generates config correctly") {
                expect(infoInitResult).to(equal(0))
                expect(membersInitResult).to(equal(0))
                expect(keysInitResult).to(equal(0))
                
                // Create a second conf to test merging
                expect(infoInitResult2).to(equal(0))
                expect(keysInitResult2).to(equal(0))
                
                expect(groups_info_set_name(conf, "GROUP Name")).to(equal(0))
                expect(groups_info_set_description(conf, "this is where you go to play in the tomato sauce, I guess")).to(equal(0))
                expect(config_needs_push(conf)).to(beTrue())
                expect(config_needs_dump(conf)).to(beTrue())
                
                let pushData1: UnsafeMutablePointer<config_push_data> = config_push(conf)
                expect(pushData1.pointee.seqno).to(equal(1))
                expect(pushData1.pointee.config_len).to(equal(512))
                expect(pushData1.pointee.obsolete_len).to(equal(0))
                
                let fakeHash1: String = "fakehash1"
                var cFakeHash1: [CChar] = fakeHash1.cArray.nullTerminated()
                config_confirm_pushed(conf, pushData1.pointee.seqno, &cFakeHash1)
                expect(config_needs_push(conf)).to(beFalse())
                expect(config_needs_dump(conf)).to(beTrue())
                
                var mergeHashes1: [UnsafePointer<CChar>?] = [cFakeHash1].unsafeCopy()
                var mergeData1: [UnsafePointer<UInt8>?] = [UnsafePointer(pushData1.pointee.config)]
                var mergeSize1: [Int] = [pushData1.pointee.config_len]
                let mergedHashes1: UnsafeMutablePointer<config_string_list>? = config_merge(conf2, &mergeHashes1, &mergeData1, &mergeSize1, 1)
                expect([String](pointer: mergedHashes1?.pointee.value, count: mergedHashes1?.pointee.len))
                    .to(equal(["fakehash1"]))
                expect(config_needs_push(conf2)).to(beFalse())
                mergeHashes1.forEach { $0?.deallocate() }
                mergedHashes1?.deallocate()
                pushData1.deallocate()
                
                let namePtr: UnsafePointer<CChar>? = groups_info_get_name(conf2)
                let descPtr: UnsafePointer<CChar>? = groups_info_get_description(conf2)
                expect(namePtr).toNot(beNil())
                expect(descPtr).toNot(beNil())
                expect(String(cString: namePtr!)).to(equal("GROUP Name"))
                expect(String(cString: descPtr!)).to(equal("this is where you go to play in the tomato sauce, I guess"))
                
                let createTime: Int64 = 1682529839
                let pic: user_profile_pic = user_profile_pic(
                    url: "http://example.com/12345".toLibSession(),
                    key: Data(hex: "abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd")
                        .toLibSession()
                )
                
                expect(groups_info_set_pic(conf2, pic)).to(equal(0))
                expect(groups_info_set_name(conf2, "GROUP Name2")).to(equal(0))
                expect(groups_info_set_description(conf2, "Test Description 2")).to(equal(0))
                groups_info_set_expiry_timer(conf2, 60 * 60)
                groups_info_set_created(conf2, createTime)
                groups_info_set_delete_before(conf2, createTime + (50 * 86400))
                groups_info_set_attach_delete_before(conf2, createTime + (70 * 86400))
                groups_info_destroy_group(conf2)
                
                let pushData2: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                let obsoleteHashes: [String] = [String](
                    pointer: pushData2.pointee.obsolete,
                    count: pushData2.pointee.obsolete_len,
                    defaultValue: []
                )
                expect(pushData2.pointee.seqno).to(equal(2))
                expect(pushData2.pointee.config_len).to(equal(512))
                expect(obsoleteHashes).to(equal(["fakehash1"]))
                
                let fakeHash2: String = "fakehash2"
                var cFakeHash2: [CChar] = fakeHash2.cArray.nullTerminated()
                config_confirm_pushed(conf2, pushData2.pointee.seqno, &cFakeHash2)

                var mergeHashes2: [UnsafePointer<CChar>?] = [cFakeHash2].unsafeCopy()
                var mergeData2: [UnsafePointer<UInt8>?] = [UnsafePointer(pushData2.pointee.config)]
                var mergeSize2: [Int] = [pushData2.pointee.config_len]
                let mergedHashes2: UnsafeMutablePointer<config_string_list>? = config_merge(conf, &mergeHashes2, &mergeData2, &mergeSize2, 1)
                expect([String](pointer: mergedHashes2?.pointee.value, count: mergedHashes2?.pointee.len))
                    .to(equal(["fakehash2"]))
                mergeHashes2.forEach { $0?.deallocate() }
                mergedHashes2?.deallocate()
                
                expect(groups_info_set_name(conf, "Better name!")).to(equal(0))
                expect(groups_info_set_description(conf, "Test New Name Really long abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz")).to(equal(0))
                
                expect(config_needs_push(conf)).to(beTrue())
                
                let pushData3: UnsafeMutablePointer<config_push_data> = config_push(conf)
                
                let namePtr2: UnsafePointer<CChar>? = groups_info_get_name(conf)
                let descPtr2: UnsafePointer<CChar>? = groups_info_get_description(conf)
                let pic2: user_profile_pic = groups_info_get_pic(conf)
                expect(namePtr2).toNot(beNil())
                expect(descPtr2).toNot(beNil())
                expect(String(cString: namePtr2!)).to(equal("Better name!"))
                expect(String(cString: descPtr2!)).to(equal("Test New Name Really long abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz"))
                expect(String(libSessionVal: pic2.url)).to(equal("http://example.com/12345"))
                expect(Data(libSessionVal: pic2.key, count: DisplayPictureManager.aes256KeyByteLength))
                    .to(equal(Data(
                        hex: "abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd"
                    )))
                expect(groups_info_get_expiry_timer(conf)).to(equal(60 * 60))
                expect(groups_info_get_created(conf)).to(equal(createTime))
                expect(groups_info_get_delete_before(conf)).to(equal(createTime + (50 * 86400)))
                expect(groups_info_get_attach_delete_before(conf)).to(equal(createTime + (70 * 86400)))
                expect(groups_info_is_destroyed(conf)).to(beTrue())
                
                expect(groups_info_set_name(conf, "Better name!")).to(equal(0))
                expect(groups_info_set_description(conf, "Test New Name Really long abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz")).to(equal(0))
                
                let fakeHash3: String = "fakehash3"
                var cFakeHash3: [CChar] = fakeHash3.cArray.nullTerminated()
                config_confirm_pushed(conf, pushData3.pointee.seqno, &cFakeHash3)
                
                var mergeHashes3: [UnsafePointer<CChar>?] = [cFakeHash3].unsafeCopy()
                var mergeData3: [UnsafePointer<UInt8>?] = [UnsafePointer(pushData3.pointee.config)]
                var mergeSize3: [Int] = [pushData3.pointee.config_len]
                let mergedHashes3: UnsafeMutablePointer<config_string_list>? = config_merge(conf2, &mergeHashes3, &mergeData3, &mergeSize3, 1)
                expect([String](pointer: mergedHashes3?.pointee.value, count: mergedHashes3?.pointee.len))
                    .to(equal(["fakehash3"]))
                mergeHashes3.forEach { $0?.deallocate() }
                mergedHashes3?.deallocate()
                pushData3.deallocate()
                
                let namePtr3: UnsafePointer<CChar>? = groups_info_get_name(conf2)
                let descPtr3: UnsafePointer<CChar>? = groups_info_get_description(conf2)
                let pic3: user_profile_pic = groups_info_get_pic(conf2)
                expect(namePtr3).toNot(beNil())
                expect(descPtr3).toNot(beNil())
                expect(String(cString: namePtr3!)).to(equal("Better name!"))
                expect(String(cString: descPtr3!)).to(equal("Test New Name Really long abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz"))
                expect(String(libSessionVal: pic3.url)).to(equal("http://example.com/12345"))
                expect(Data(libSessionVal: pic3.key, count: DisplayPictureManager.aes256KeyByteLength))
                    .to(equal(Data(
                        hex: "abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd"
                    )))
                expect(groups_info_get_expiry_timer(conf2)).to(equal(60 * 60))
                expect(groups_info_get_created(conf2)).to(equal(createTime))
                expect(groups_info_get_delete_before(conf2)).to(equal(createTime + (50 * 86400)))
                expect(groups_info_get_attach_delete_before(conf2)).to(equal(createTime + (70 * 86400)))
                expect(groups_info_is_destroyed(conf2)).to(beTrue())
            }
            
            // MARK: -- prevents writes without admin key
            it("prevents writes without admin key") {
                let cachedKeysDump: (data: UnsafePointer<UInt8>, length: Int)? = LibSessionUtilSpec.groupKeysDump.withUnsafeBytes { unsafeBytes in
                    return unsafeBytes.baseAddress.map {
                        (
                            $0.assumingMemoryBound(to: UInt8.self),
                            unsafeBytes.count
                        )
                    }
                }
                
                // Initialize a brand new, empty config with a null `edSK` value
                expect(groups_info_init(&infoConf, &edPK, nil, nil, 0, &error)).to(equal(0))
                expect(groups_keys_init(&keysConf, &userEdSK, &edPK, nil, infoConf, membersConf, cachedKeysDump?.data, (cachedKeysDump?.length ?? 0), &error)).to(equal(0))
                
                expect(groups_info_set_name(conf, "Super Group!")).toNot(equal(0))
                expect((conf?.pointee.last_error).map { String(cString: $0) })
                    .to(equal("Unable to make changes to a read-only config object"))
                expect(config_needs_push(conf)).to(beFalse())
                expect(config_needs_dump(conf)).to(beFalse())
            }
        }
    }
}

// MARK: - GROUP_MEMBERS

fileprivate extension LibSessionUtilSpec {
    enum GroupMemberProperty: CaseIterable {
        case name
        case profile_pic
        case admin
        case invited
        case promoted
    }
    
    class func groupMembersSpec() {
        context("GROUP_MEMBERS") {
            @TestState var userEdSK: [UInt8]! = LibSessionUtilSpec.userEdSK
            @TestState var edPK: [UInt8]! = LibSessionUtilSpec.edPK
            @TestState var edSK: [UInt8]! = LibSessionUtilSpec.edSK
            @TestState var error: [CChar]! = [CChar](repeating: 0, count: 256)
            @TestState var infoConf: UnsafeMutablePointer<config_object>?
            @TestState var membersConf: UnsafeMutablePointer<config_object>?
            @TestState var keysConf: UnsafeMutablePointer<config_group_keys>?
            @TestState var infoInitResult: Int32! = {
                groups_info_init(&infoConf, &edPK, &edSK, nil, 0, &error)
            }()
            @TestState var membersInitResult: Int32! = {
                groups_members_init(&membersConf, &edPK, &edSK, nil, 0, &error)
            }()
            @TestState var keysInitResult: Int32! = {
                LibSessionUtilSpec.initKeysConf(&keysConf, &infoConf, &membersConf)
            }()
            
            @TestState var membersConf2: UnsafeMutablePointer<config_object>?
            @TestState var keysConf2: UnsafeMutablePointer<config_group_keys>?
            @TestState var membersInitResult2: Int32! = {
                groups_members_init(&membersConf2, &edPK, &edSK, nil, 0, &error)
            }()
            @TestState var keysInitResult2: Int32! = {
                LibSessionUtilSpec.initKeysConf(&keysConf2, &infoConf, &membersConf2)
            }()
            @TestState var numRecords: Int! = 0
            
            // Convenience
            var conf: UnsafeMutablePointer<config_object>? { membersConf }
            var conf2: UnsafeMutablePointer<config_object>? { membersConf2 }
            
            // MARK: -- when checking error catching
            context("when checking error catching") {
                // MARK: ---- it can catch size limit errors thrown when pushing
                it("can catch size limit errors thrown when pushing") {
                    var randomGenerator: ARC4RandomNumberGenerator = ARC4RandomNumberGenerator(seed: 1000)

                    try (0..<2500).forEach { index in
                        var member: config_group_member = try createMember(
                            for: index,
                            in: conf,
                            rand: &randomGenerator,
                            maxing: .allProperties
                        )
                        groups_members_set(conf, &member)
                    }

                    expect(groups_members_size(conf)).to(equal(2500))
                    expect(config_needs_push(conf)).to(beTrue())
                    expect(config_needs_dump(conf)).to(beTrue())

                    expect {
                        try CExceptionHelper.performSafely { config_push(conf).deallocate() }
                    }
                    .to(throwError(NSError(domain: "cpp_exception", code: -2, userInfo: ["NSLocalizedDescription": "Config data is too large"])))
                }
            }

            // MARK: -- when checking size limits
            context("when checking size limits") {
                // MARK: ---- has not changed the max empty records
                it("has not changed the max empty records") {
                    var randomGenerator: ARC4RandomNumberGenerator = ARC4RandomNumberGenerator(seed: 1000)

                    for index in (0..<2500) {
                        var member: config_group_member = try createMember(
                            for: index,
                            in: conf,
                            rand: &randomGenerator
                        )
                        groups_members_set(conf, &member)

                        do { try CExceptionHelper.performSafely { config_push(conf).deallocate() } }
                        catch { break }

                        // We successfully inserted a contact and didn't hit the limit so increment the counter
                        numRecords += 1
                    }

                    // Check that the record count matches the maximum when we last checked
                    expect(numRecords).to(equal(2369))
                }

                // MARK: ---- has not changed the max name only records
                it("has not changed the max name only records") {
                    var randomGenerator: ARC4RandomNumberGenerator = ARC4RandomNumberGenerator(seed: 1000)

                    for index in (0..<2500) {
                        var member: config_group_member = try createMember(
                            for: index,
                            in: conf,
                            rand: &randomGenerator,
                            maxing: [.name]
                        )
                        groups_members_set(conf, &member)

                        do { try CExceptionHelper.performSafely { config_push(conf).deallocate() } }
                        catch { break }

                        // We successfully inserted a contact and didn't hit the limit so increment the counter
                        numRecords += 1
                    }

                    // Check that the record count matches the maximum when we last checked
                    expect(numRecords).to(equal(795))
                }

                // MARK: ---- has not changed the max name and profile pic only records
                it("has not changed the max name and profile pic only records") {
                    var randomGenerator: ARC4RandomNumberGenerator = ARC4RandomNumberGenerator(seed: 1000)

                    for index in (0..<2500) {
                        var member: config_group_member = try createMember(
                            for: index,
                            in: conf,
                            rand: &randomGenerator,
                            maxing: [.name, .profile_pic]
                        )
                        groups_members_set(conf, &member)

                        do { try CExceptionHelper.performSafely { config_push(conf).deallocate() } }
                        catch { break }

                        // We successfully inserted a contact and didn't hit the limit so increment the counter
                        numRecords += 1
                    }

                    // Check that the record count matches the maximum when we last checked
                    expect(numRecords).to(equal(289))
                }

                // MARK: ---- has not changed the max filled records
                it("has not changed the max filled records") {
                    var randomGenerator: ARC4RandomNumberGenerator = ARC4RandomNumberGenerator(seed: 1000)

                    for index in (0..<2500) {
                        var member: config_group_member = try createMember(
                            for: index,
                            in: conf,
                            rand: &randomGenerator,
                            maxing: .allProperties
                        )
                        groups_members_set(conf, &member)

                        do { try CExceptionHelper.performSafely { config_push(conf).deallocate() } }
                        catch { break }

                        // We successfully inserted a contact and didn't hit the limit so increment the counter
                        numRecords += 1
                    }

                    // Check that the record count matches the maximum when we last checked
                    expect(numRecords).to(equal(289))
                }
            }
            
            // MARK: -- generates config correctly
            it("generates config correctly") {
                expect(membersInitResult).to(equal(0))
                expect(infoInitResult).to(equal(0))
                expect(keysInitResult).to(equal(0))
                
                // Create a second conf to test merging
                expect(membersInitResult2).to(equal(0))
                expect(keysInitResult2).to(equal(0))
                
                let postPrefixId: String = ("05aa" + (0..<31).map { _ in "00" }.joined())
                let sids: [String] = (0..<256).map {
                    (postPrefixId.prefix(postPrefixId.count - "\($0)".count) + "\($0)")
                }
                
                // 10 admins:
                (0..<10).forEach { index in
                    var member: config_group_member = config_group_member(
                        session_id: sids[index].toLibSession(),
                        name: "Admin \(index)".toLibSession(),
                        profile_pic: user_profile_pic(
                            url: "http://example.com/".toLibSession(),
                            key: Data(hex: "abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd")
                                .toLibSession()
                        ),
                        admin: true,
                        invited: 0,
                        promoted: 0,
                        removed: 0,
                        supplement: false
                    )
                    
                    groups_members_set(conf, &member)
                }
                
                // 10 members:
                (10..<20).forEach { index in
                    var member: config_group_member = config_group_member(
                        session_id: sids[index].toLibSession(),
                        name: "Member \(index)".toLibSession(),
                        profile_pic: user_profile_pic(
                            url: "http://example.com/".toLibSession(),
                            key: Data(hex: "abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd")
                                .toLibSession()
                        ),
                        admin: false,
                        invited: 0,
                        promoted: 0,
                        removed: 0,
                        supplement: false
                    )
                    
                    groups_members_set(conf, &member)
                }
                
                // 5 members with no attributes (not even a name):
                (20..<25).forEach { index in
                    var cSessionId: [CChar] = sids[index].cArray
                    var member: config_group_member = config_group_member()
                    expect(groups_members_get_or_construct(conf, &member, &cSessionId)).to(beTrue())
                    groups_members_set(conf, &member)
                }
                
                expect(config_needs_push(conf)).to(beTrue())
                
                let pushData1: UnsafeMutablePointer<config_push_data> = config_push(conf)
                expect(pushData1.pointee.seqno).to(equal(1))
                expect(pushData1.pointee.config_len).to(equal(512))
                expect(pushData1.pointee.obsolete_len).to(equal(0))
                
                let fakeHash1: String = "fakehash1"
                var cFakeHash1: [CChar] = fakeHash1.cArray.nullTerminated()
                config_confirm_pushed(conf, pushData1.pointee.seqno, &cFakeHash1)
                expect(config_needs_push(conf)).to(beFalse())
                expect(config_needs_dump(conf)).to(beTrue())
                
                var mergeHashes1: [UnsafePointer<CChar>?] = [cFakeHash1].unsafeCopy()
                var mergeData1: [UnsafePointer<UInt8>?] = [UnsafePointer(pushData1.pointee.config)]
                var mergeSize1: [Int] = [pushData1.pointee.config_len]
                let mergedHashes1: UnsafeMutablePointer<config_string_list>? = config_merge(conf2, &mergeHashes1, &mergeData1, &mergeSize1, 1)
                expect([String](pointer: mergedHashes1?.pointee.value, count: mergedHashes1?.pointee.len))
                    .to(equal(["fakehash1"]))
                expect(config_needs_push(conf2)).to(beFalse())
                mergeHashes1.forEach { $0?.deallocate() }
                mergedHashes1?.deallocate()
                pushData1.deallocate()
                
                expect(groups_members_size(conf2)).to(equal(25))
                
                (0..<25).forEach { index in
                    var cSessionId: [CChar] = sids[index].cArray
                    var member: config_group_member = config_group_member()
                    expect(groups_members_get(conf2, &member, &cSessionId)).to(beTrue())
                    expect(String(libSessionVal: member.session_id)).to(equal(sids[index]))
                    expect(member.invited).to(equal(0))
                    expect(member.promoted).to(equal(0))
                    expect(member.removed).to(equal(0))
                    
                    switch index {
                        case 0..<10:
                            expect(String(libSessionVal: member.name)).to(equal("Admin \(index)"))
                            expect(member.admin).to(beTrue())
                            expect(member.profile_pic).toNot(beNil())
                            expect(String(libSessionVal: member.profile_pic.url)).toNot(beEmpty())
                            expect(Data(libSessionVal: member.profile_pic.key, count: DisplayPictureManager.aes256KeyByteLength))
                                .to(equal(Data(
                                    hex: "abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd"
                                )))
                            
                        case 10..<20:
                            expect(String(libSessionVal: member.name)).to(equal("Member \(index)"))
                            expect(member.admin).to(beFalse())
                            expect(member.profile_pic).toNot(beNil())
                            expect(String(libSessionVal: member.profile_pic.url)).toNot(beEmpty())
                            expect(Data(libSessionVal: member.profile_pic.key, count: DisplayPictureManager.aes256KeyByteLength))
                                .to(equal(Data(
                                    hex: "abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd"
                                )))
                            
                        case 20..<25:
                            expect(String(libSessionVal: member.name)).to(beEmpty())
                            expect(member.admin).to(beFalse())
                            expect(member.profile_pic).toNot(beNil())
                            expect(String(libSessionVal: member.profile_pic.url)).to(beEmpty())
                            expect(String(libSessionVal: member.profile_pic.key)).to(beEmpty())
                            
                        default: expect(true).to(beFalse())  // All cases covered
                    }
                }
                
                (22..<50).forEach { index in
                    var cSessionId: [CChar] = sids[index].cArray
                    var member: config_group_member = config_group_member()
                    expect(groups_members_get_or_construct(conf2, &member, &cSessionId)).to(beTrue())
                    member.name = "Member \(index)".toLibSession()
                    groups_members_set(conf2, &member)
                }
                (50..<55).forEach { index in
                    var cSessionId: [CChar] = sids[index].cArray
                    var member: config_group_member = config_group_member()
                    expect(groups_members_get_or_construct(conf2, &member, &cSessionId)).to(beTrue())
                    member.invited = 1  // Invite Sent
                    groups_members_set(conf2, &member)
                }
                (55..<58).forEach { index in
                    var cSessionId: [CChar] = sids[index].cArray
                    var member: config_group_member = config_group_member()
                    expect(groups_members_get_or_construct(conf2, &member, &cSessionId)).to(beTrue())
                    member.invited = 2 // Invite Failed
                    groups_members_set(conf2, &member)
                }
                (58..<62).forEach { index in
                    var cSessionId: [CChar] = sids[index].cArray
                    var member: config_group_member = config_group_member()
                    expect(groups_members_get_or_construct(conf2, &member, &cSessionId)).to(beTrue())
                    member.promoted = (index < 60 ? 1 : 2) // Promotion Sent/Failed
                    groups_members_set(conf2, &member)
                }
                (62..<66).forEach { index in
                    var cSessionId: [CChar] = sids[index].cArray
                    var member: config_group_member = config_group_member()
                    expect(groups_members_get_or_construct(conf2, &member, &cSessionId)).to(beTrue())
                    member.removed = (index < 64 ? 1 : 2)
                    groups_members_set(conf2, &member)
                }
                
                var cSessionId1: [CChar] = sids[23].cArray
                var member1: config_group_member = config_group_member()
                expect(groups_members_get(conf2, &member1, &cSessionId1)).to(beTrue())
                member1.name = "Member 23".toLibSession()
                groups_members_set(conf2, &member1)
                
                let pushData2: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                let obsoleteHashes: [String] = [String](
                    pointer: pushData2.pointee.obsolete,
                    count: pushData2.pointee.obsolete_len,
                    defaultValue: []
                )
                expect(pushData2.pointee.seqno).to(equal(2))
                expect(pushData2.pointee.config_len).to(equal(1024))
                expect(obsoleteHashes).to(equal(["fakehash1"]))
                
                let fakeHash2: String = "fakehash2"
                var cFakeHash2: [CChar] = fakeHash2.cArray.nullTerminated()
                config_confirm_pushed(conf2, pushData2.pointee.seqno, &cFakeHash2)
                
                var mergeHashes2: [UnsafePointer<CChar>?] = [cFakeHash2].unsafeCopy()
                var mergeData2: [UnsafePointer<UInt8>?] = [UnsafePointer(pushData2.pointee.config)]
                var mergeSize2: [Int] = [pushData2.pointee.config_len]
                let mergedHashes2: UnsafeMutablePointer<config_string_list>? = config_merge(conf, &mergeHashes2, &mergeData2, &mergeSize2, 1)
                expect([String](pointer: mergedHashes2?.pointee.value, count: mergedHashes2?.pointee.len))
                    .to(equal(["fakehash2"]))
                mergeHashes2.forEach { $0?.deallocate() }
                mergedHashes2?.deallocate()
                
                var cSessionId2: [CChar] = sids[23].cArray
                var member2: config_group_member = config_group_member()
                expect(groups_members_get(conf, &member2, &cSessionId2)).to(beTrue())
                expect(String(libSessionVal: member2.name)).to(equal("Member 23"))
                
                expect(groups_members_size(conf)).to(equal(66))
                
                (0..<62).forEach { index in
                    var cSessionId: [CChar] = sids[index].cArray
                    var member: config_group_member = config_group_member()
                    expect(groups_members_get(conf, &member, &cSessionId)).to(beTrue())
                    expect(String(libSessionVal: member.session_id)).to(equal(sids[index]))
                    
                    switch index {
                        case 0..<10:
                            expect(String(libSessionVal: member.name)).to(equal("Admin \(index)"))
                            expect(member.admin).to(beTrue())
                            expect(member.invited).to(equal(0))
                            expect(member.promoted).to(equal(0))
                            expect(member.removed).to(equal(0))
                            expect(member.profile_pic).toNot(beNil())
                            expect(String(libSessionVal: member.profile_pic.url)).toNot(beEmpty())
                            expect(Data(libSessionVal: member.profile_pic.key, count: DisplayPictureManager.aes256KeyByteLength))
                                .to(equal(Data(
                                    hex: "abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd"
                                )))
                            
                        case 10..<20:
                            expect(String(libSessionVal: member.name)).to(equal("Member \(index)"))
                            expect(member.admin).to(beFalse())
                            expect(member.invited).to(equal(0))
                            expect(member.promoted).to(equal(0))
                            expect(member.removed).to(equal(0))
                            expect(member.profile_pic).toNot(beNil())
                            expect(String(libSessionVal: member.profile_pic.url)).toNot(beEmpty())
                            expect(Data(libSessionVal: member.profile_pic.key, count: DisplayPictureManager.aes256KeyByteLength))
                                .to(equal(Data(
                                    hex: "abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd"
                                )))
                            
                        case 22..<50:
                            expect(String(libSessionVal: member.name)).to(equal("Member \(index)"))
                            expect(member.admin).to(beFalse())
                            expect(member.invited).to(equal(0))
                            expect(member.promoted).to(equal(0))
                            expect(member.removed).to(equal(0))
                            expect(member.profile_pic).toNot(beNil())
                            expect(String(libSessionVal: member.profile_pic.url)).to(beEmpty())
                            expect(String(libSessionVal: member.profile_pic.key)).to(beEmpty())
                            
                        case 50..<55:
                            expect(String(libSessionVal: member.name)).to(beEmpty())
                            expect(member.admin).to(beFalse())
                            expect(member.invited).to(equal(1))
                            expect(member.promoted).to(equal(0))
                            expect(member.removed).to(equal(0))
                            expect(member.profile_pic).toNot(beNil())
                            expect(String(libSessionVal: member.profile_pic.url)).to(beEmpty())
                            expect(String(libSessionVal: member.profile_pic.key)).to(beEmpty())
                            
                        case 55..<58:
                            expect(String(libSessionVal: member.name)).to(beEmpty())
                            expect(member.admin).to(beFalse())
                            expect(member.invited).to(equal(2))
                            expect(member.promoted).to(equal(0))
                            expect(member.removed).to(equal(0))
                            expect(member.profile_pic).toNot(beNil())
                            expect(String(libSessionVal: member.profile_pic.url)).to(beEmpty())
                            expect(String(libSessionVal: member.profile_pic.key)).to(beEmpty())
                            
                        case 58..<60:
                            expect(String(libSessionVal: member.name)).to(beEmpty())
                            expect(member.admin).to(beFalse())
                            expect(member.invited).to(equal(0))
                            expect(member.promoted).to(equal(1))
                            expect(member.removed).to(equal(0))
                            expect(member.profile_pic).toNot(beNil())
                            expect(String(libSessionVal: member.profile_pic.url)).to(beEmpty())
                            expect(String(libSessionVal: member.profile_pic.key)).to(beEmpty())
                        
                        case 20, 21:
                            expect(String(libSessionVal: member.name)).to(beEmpty())
                            expect(member.admin).to(beFalse())
                            expect(member.invited).to(equal(0))
                            expect(member.promoted).to(equal(0))
                            expect(member.removed).to(equal(0))
                            expect(member.profile_pic).toNot(beNil())
                            expect(String(libSessionVal: member.profile_pic.url)).to(beEmpty())
                            expect(String(libSessionVal: member.profile_pic.key)).to(beEmpty())
                            
                        case 60..<62:
                            expect(String(libSessionVal: member.name)).to(beEmpty())
                            expect(member.admin).to(beFalse())
                            expect(member.invited).to(equal(0))
                            expect(member.promoted).to(equal(2))
                            expect(member.removed).to(equal(0))
                            expect(member.profile_pic).toNot(beNil())
                            expect(String(libSessionVal: member.profile_pic.url)).to(beEmpty())
                            expect(String(libSessionVal: member.profile_pic.key)).to(beEmpty())
                            
                        case 62..<64:
                            expect(String(libSessionVal: member.name)).to(beEmpty())
                            expect(member.admin).to(beFalse())
                            expect(member.invited).to(equal(0))
                            expect(member.promoted).to(equal(0))
                            expect(member.removed).to(equal(1))
                            expect(member.profile_pic).toNot(beNil())
                            expect(String(libSessionVal: member.profile_pic.url)).to(beEmpty())
                            expect(String(libSessionVal: member.profile_pic.key)).to(beEmpty())
                            
                        case 64..<66:
                            expect(String(libSessionVal: member.name)).to(beEmpty())
                            expect(member.admin).to(beFalse())
                            expect(member.invited).to(equal(0))
                            expect(member.promoted).to(equal(0))
                            expect(member.removed).to(equal(2))
                            expect(member.profile_pic).toNot(beNil())
                            expect(String(libSessionVal: member.profile_pic.url)).to(beEmpty())
                            expect(String(libSessionVal: member.profile_pic.key)).to(beEmpty())
                            
                        default: expect(index).to(equal(-1))  // All cases covered
                    }
                }
                
                var cSessionId: [CChar] = []
                var member: config_group_member = config_group_member()
                
                (0..<66).forEach { index in
                    cSessionId = sids[index].cArray
                    member = config_group_member()
                    
                    switch index {
                        // Prime numbers (rather than writing an 'isPrime' function)
                        case 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61:
                            _ = groups_members_erase(conf, &cSessionId)
                        
                        case 50..<55:
                            expect(groups_members_get(conf, &member, &cSessionId)).to(beTrue())
                            member.invited = 0
                            groups_members_set(conf, &member)
                            
                        case 55, 56:
                            expect(groups_members_get(conf, &member, &cSessionId)).to(beTrue())
                            member.invited = 1
                            groups_members_set(conf, &member)
                            
                        case 58:
                            expect(groups_members_get(conf, &member, &cSessionId)).to(beTrue())
                            member.admin = true
                            groups_members_set(conf, &member)
                            
                        default: break
                    }
                }
                
                let pushData3: UnsafeMutablePointer<config_push_data> = config_push(conf)
                let obsoleteHashes3: [String] = [String](
                    pointer: pushData3.pointee.obsolete,
                    count: pushData3.pointee.obsolete_len,
                    defaultValue: []
                )
                expect(pushData3.pointee.seqno).to(equal(3))
                expect(pushData3.pointee.config_len).to(equal(1024))
                expect(obsoleteHashes3).to(equal(["fakehash2", "fakehash1"]))
                
                let fakeHash3: String = "fakehash3"
                var cFakeHash3: [CChar] = fakeHash3.cArray.nullTerminated()
                config_confirm_pushed(conf, pushData3.pointee.seqno, &cFakeHash3)
                
                var mergeHashes3: [UnsafePointer<CChar>?] = [cFakeHash3].unsafeCopy()
                var mergeData3: [UnsafePointer<UInt8>?] = [UnsafePointer(pushData3.pointee.config)]
                var mergeSize3: [Int] = [pushData3.pointee.config_len]
                let mergedHashes3: UnsafeMutablePointer<config_string_list>? = config_merge(conf2, &mergeHashes3, &mergeData3, &mergeSize3, 1)
                expect([String](pointer: mergedHashes3?.pointee.value, count: mergedHashes3?.pointee.len))
                    .to(equal(["fakehash3"]))
                mergeHashes3.forEach { $0?.deallocate() }
                mergedHashes3?.deallocate()

                expect(groups_members_size(conf2)).to(equal(48))    // 18 deleted earlier
                
                (0..<66).forEach { index in
                    var cSessionId: [CChar] = sids[index].cArray
                    var member: config_group_member = config_group_member()
                    
                    // Existence
                    switch index {
                        case 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41,
                            43, 47, 53, 59, 61, 67, 71, 73, 79, 83, 89, 97:
                            expect(groups_members_get(conf2, &member, &cSessionId)).to(beFalse())
                            return
                            
                        default:
                            expect(groups_members_get(conf2, &member, &cSessionId)).to(beTrue())
                            expect(String(libSessionVal: member.session_id)).to(equal(sids[index]))
                            expect(member.profile_pic).toNot(beNil())
                    }
                    
                    // Name & Profile
                    switch index {
                        case 0..<10:
                            expect(String(libSessionVal: member.name)).to(equal("Admin \(index)"))
                            expect(String(libSessionVal: member.profile_pic.url)).toNot(beEmpty())
                            expect(Data(libSessionVal: member.profile_pic.key, count: DisplayPictureManager.aes256KeyByteLength))
                                .to(equal(Data(
                                    hex: "abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd"
                                )))
                            
                        case 10..<20:
                            expect(String(libSessionVal: member.name)).to(equal("Member \(index)"))
                            expect(String(libSessionVal: member.profile_pic.url)).toNot(beEmpty())
                            expect(Data(libSessionVal: member.profile_pic.key, count: DisplayPictureManager.aes256KeyByteLength))
                                .to(equal(Data(
                                    hex: "abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd"
                                )))
                            
                        case 22..<50:
                            expect(String(libSessionVal: member.name)).to(equal("Member \(index)"))
                            expect(String(libSessionVal: member.profile_pic.url)).to(beEmpty())
                            expect(String(libSessionVal: member.profile_pic.key)).to(beEmpty())
                            
                        default:
                            expect(String(libSessionVal: member.name)).to(beEmpty())
                            expect(String(libSessionVal: member.profile_pic.url)).to(beEmpty())
                            expect(String(libSessionVal: member.profile_pic.key)).to(beEmpty())
                    }
                    
                    // Admin
                    switch index {
                        case 0..<10, 58: expect(member.admin).to(beTrue())
                        default: expect(member.admin).to(beFalse())
                    }
                    
                    // Invited
                    switch index {
                        case 55, 56: expect(member.invited).to(equal(1))
                        case 57: expect(member.invited).to(equal(2))
                        default: expect(member.invited).to(equal(0))
                    }
                    
                    // Promoted
                    switch index {
                        case 58: expect(member.promoted).to(equal(0))    // Reset by setting `admin = true`
                        case 60, 61: expect(member.promoted).to(equal(2))
                        default: expect(member.promoted).to(equal(0))
                    }
                    
                    // Removed
                    switch index {
                        case 62, 63: expect(member.removed).to(equal(1))
                        case 64, 65: expect(member.removed).to(equal(2))
                        default: expect(member.removed).to(equal(0))
                    }
                }
            }
        }
    }
    
    // MARK: - Convenience
    
    private static func createMember(
        for index: Int,
        in conf: UnsafeMutablePointer<config_object>?,
        rand: inout ARC4RandomNumberGenerator,
        maxing properties: [GroupMemberProperty] = []
    ) throws -> config_group_member {
        let postPrefixId: String = "05\(rand.nextBytes(count: 32).toHexString())"
        let sessionId: String = ("05\(index)a" + postPrefixId.suffix(postPrefixId.count - "05\(index)a".count))
        var cSessionId: [CChar] = sessionId.cArray.nullTerminated()
        var member: config_group_member = config_group_member()
        
        guard groups_members_get_or_construct(conf, &member, &cSessionId) else {
            throw LibSessionError.getOrConstructFailedUnexpectedly
        }
        
        // Set the values to the maximum data that can fit
        properties.forEach { property in
            switch property {
                case .admin: member.admin = true
                case .invited: member.invited = true
                case .promoted: member.promoted = true
                
                case .name:
                    member.name = rand.nextBytes(count: LibSession.sizeMaxNameBytes)
                        .toHexString()
                        .toLibSession()
                
                case .profile_pic:
                    member.profile_pic = user_profile_pic(
                        url: rand.nextBytes(count: LibSession.sizeMaxProfileUrlBytes)
                            .toHexString()
                            .toLibSession(),
                        key: Data(rand.nextBytes(count: 32))
                            .toLibSession()
                    )
            }
        }
        
        return member
    }
}

fileprivate extension Array where Element == LibSessionUtilSpec.GroupMemberProperty {
    static var allProperties: [LibSessionUtilSpec.GroupMemberProperty] = LibSessionUtilSpec.GroupMemberProperty.allCases
}

// MARK: - GROUP_KEYS

fileprivate extension LibSessionUtilSpec {
    static func initKeysConf(
        _ keysConf: inout UnsafeMutablePointer<config_group_keys>?,
        _ infoConf: inout UnsafeMutablePointer<config_object>?,
        _ membersConf: inout UnsafeMutablePointer<config_object>?
    ) -> Int32 {
        var error: [CChar] = [CChar](repeating: 0, count: 256)
        var userEdSK: [UInt8] = LibSessionUtilSpec.userEdSK
        var edPK: [UInt8] = LibSessionUtilSpec.edPK
        var edSK: [UInt8] = LibSessionUtilSpec.edSK
        let cachedKeysDump: (data: UnsafePointer<UInt8>, length: Int)? = LibSessionUtilSpec.groupKeysDump.withUnsafeBytes { unsafeBytes in
            return unsafeBytes.baseAddress.map {
                (
                    $0.assumingMemoryBound(to: UInt8.self),
                    unsafeBytes.count
                )
            }
        }
        
        return groups_keys_init(&keysConf, &userEdSK, &edPK, &edSK, infoConf, membersConf, cachedKeysDump?.data, (cachedKeysDump?.length ?? 0), &error)
    }
    
    /// This function can be used to regenerate the hard-coded `keysDump` value if needed due to `libSession` changes
    /// resulting in the dump changing
    static func generateKeysDump(for keysConf: UnsafeMutablePointer<config_group_keys>?) throws -> String {
        var dumpResult: UnsafeMutablePointer<UInt8>? = nil
        var dumpResultLen: Int = 0
        try CExceptionHelper.performSafely {
            groups_keys_dump(keysConf, &dumpResult, &dumpResultLen)
        }

        let dumpData: Data = Data(bytes: dumpResult!, count: dumpResultLen)
        dumpResult?.deallocate()
        return dumpData.toHexString()
    }
    
    class func groupKeysSpec() {
        context("GROUP_KEYS") {
            @TestState var userEdSK: [UInt8]! = LibSessionUtilSpec.userEdSK
            @TestState var edPK: [UInt8]! = LibSessionUtilSpec.edPK
            @TestState var edSK: [UInt8]! = LibSessionUtilSpec.edSK
            @TestState var error: [CChar]! = [CChar](repeating: 0, count: 256)
            @TestState var infoConf: UnsafeMutablePointer<config_object>?
            @TestState var membersConf: UnsafeMutablePointer<config_object>?
            @TestState var keysConf: UnsafeMutablePointer<config_group_keys>?
            @TestState var infoInitResult: Int32! = {
                groups_info_init(&infoConf, &edPK, &edSK, nil, 0, &error)
            }()
            @TestState var membersInitResult: Int32! = {
                groups_members_init(&membersConf, &edPK, &edSK, nil, 0, &error)
            }()
            @TestState var keysInitResult: Int32! = {
                LibSessionUtilSpec.initKeysConf(&keysConf, &infoConf, &membersConf)
            }()
            
            @TestState var membersConf2: UnsafeMutablePointer<config_object>?
            @TestState var keysConf2: UnsafeMutablePointer<config_group_keys>?
            @TestState var membersInitResult2: Int32! = {
                groups_members_init(&membersConf2, &edPK, &edSK, nil, 0, &error)
            }()
            @TestState var keysInitResult2: Int32! = {
                LibSessionUtilSpec.initKeysConf(&keysConf2, &infoConf, &membersConf2)
            }()
            @TestState var numRecords: Int! = 0
            
            // Convenience
            var conf: UnsafeMutablePointer<config_group_keys>? { keysConf }
            var conf2: UnsafeMutablePointer<config_group_keys>? { keysConf2 }
            
            // MARK: - when checking error catching
            context("when checking error catching") {
                // MARK: -- does not throw size exceptions when generating
                it("does not throw size exceptions when generating") {
                    var randomGenerator: ARC4RandomNumberGenerator = ARC4RandomNumberGenerator(seed: 1000)
                    var pushResultLen: Int = 0
                    
                    // It's actually the number of members which can cause the keys message to get too large so
                    // start by generating too many members
                    try (0..<1750).forEach { index in
                        var member: config_group_member = try createMember(
                            for: index,
                            in: membersConf,
                            rand: &randomGenerator,
                            maxing: .allProperties
                        )
                        groups_members_set(membersConf, &member)
                    }
                    
                    expect {
                        try CExceptionHelper.performSafely {
                            var pushResult: UnsafePointer<UInt8>? = nil
                            expect(groups_keys_rekey(
                                conf,
                                infoConf,
                                membersConf,
                                &pushResult,
                                &pushResultLen
                            )).to(beTrue())
                        }
                    }
                    .toNot(throwError(NSError(domain: "cpp_exception", code: -2, userInfo: ["NSLocalizedDescription": "Config data is too large"])))
                    
                    expect(pushResultLen).to(beGreaterThan(LibSessionUtilSpec.maxMessageSizeBytes))
                    expect(groups_keys_needs_dump(conf)).to(beTrue())
                }
            }
            
            // MARK: -- generates config correctly
            it("generates config correctly") {
                var edPK: [UInt8] = LibSessionUtilSpec.keyPair.publicKey
                var edSK: [UInt8] = LibSessionUtilSpec.keyPair.secretKey
                
                expect(userEdSK.toHexString().suffix(64))
                    .to(equal("4cb76fdc6d32278e3f83dbf608360ecc6b65727934b85d2fb86862ff98c46ab7"))
                expect(edPK.toHexString())
                    .to(equal("cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"))
                expect(String(Data(edSK.prefix(32)).toHexString())).to(equal(LibSessionUtilSpec.seed.toHexString()))
                
                // Initialize a brand new, empty config because we have no dump data to deal with.
                var error: [CChar] = [CChar](repeating: 0, count: 256)
                var infoConf: UnsafeMutablePointer<config_object>? = nil
                expect(groups_info_init(&infoConf, &edPK, &edSK, nil, 0, &error)).to(equal(0))
                
                var membersConf: UnsafeMutablePointer<config_object>? = nil
                expect(groups_members_init(&membersConf, &edPK, &edSK, nil, 0, &error)).to(equal(0))
                
                expect(groups_keys_size(conf)).to(equal(1))
            }
        }
    }
}
