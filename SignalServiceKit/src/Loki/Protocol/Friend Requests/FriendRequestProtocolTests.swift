import CryptoSwift
import PromiseKit
@testable import SignalServiceKit
import XCTest
import Curve25519Kit

class FriendRequestProtocolTests : XCTestCase {

    private var storage: OWSPrimaryStorage { OWSPrimaryStorage.shared() }

    override func setUp() {
        super.setUp()
        // Activate the mock environment
        ClearCurrentAppContextForTests()
        SetCurrentAppContext(TestAppContext())
        MockSSKEnvironment.activate()
        // Register a mock user
        let identityManager = OWSIdentityManager.shared()
        let seed = Randomness.generateRandomBytes(16)!
        let keyPair = Curve25519.generateKeyPair(fromSeed: seed + seed)
        let databaseConnection = identityManager.value(forKey: "dbConnection") as! YapDatabaseConnection
        databaseConnection.setObject(keyPair, forKey: OWSPrimaryStorageIdentityKeyStoreIdentityKey, inCollection: OWSPrimaryStorageIdentityKeyStoreCollection)
        TSAccountManager.sharedInstance().phoneNumberAwaitingVerification = keyPair.hexEncodedPublicKey
        TSAccountManager.sharedInstance().didRegister()
    }

    // MARK: - Helpers

    func isFriendRequestStatus(_ values: [LKFriendRequestStatus], for hexEncodedPublicKey: String, transaction: YapDatabaseReadWriteTransaction) -> Bool {
        let status = storage.getFriendRequestStatus(forContact: hexEncodedPublicKey, transaction: transaction)
        return values.contains(status)
    }

    func isFriendRequestStatus(_ value: LKFriendRequestStatus, for hexEncodedPublicKey: String, transaction: YapDatabaseReadWriteTransaction) -> Bool {
        return isFriendRequestStatus([value], for: hexEncodedPublicKey, transaction: transaction)
    }

    func generateHexEncodedPublicKey() -> String {
        return Curve25519.generateKeyPair().hexEncodedPublicKey
    }

    func getDevice(for hexEncodedPublicKey: String) -> DeviceLink.Device? {
        guard let signature = Data.getSecureRandomData(ofSize: 64) else { return nil }
        return DeviceLink.Device(hexEncodedPublicKey: hexEncodedPublicKey, signature: signature)
    }

    func createContactThread(for hexEncodedPublicKey: String) -> TSContactThread {
        var result: TSContactThread!
        storage.dbReadWriteConnection.readWrite { transaction in
            result = TSContactThread.getOrCreateThread(withContactId: hexEncodedPublicKey, transaction: transaction)
        }
        return result
    }

    func createGroupThread(groupType: GroupType) -> TSGroupThread? {
        let stringId = Randomness.generateRandomBytes(kGroupIdLength)!.toHexString()
        let groupId: Data!
        switch groupType {
        case .closedGroup:
            groupId = LKGroupUtilities.getEncodedClosedGroupIDAsData(stringId)
            break
        case .openGroup:
            groupId = LKGroupUtilities.getEncodedOpenGroupIDAsData(stringId)
            break
        case .rssFeed:
            groupId = LKGroupUtilities.getEncodedRSSFeedIDAsData(stringId)
        default:
            return nil
        }

        return TSGroupThread.getOrCreateThread(withGroupId: groupId, groupType: groupType)
    }

    // MARK: - shouldInputBarBeEnabled

    func test_shouldInputBarBeEnabledReturnsTrueOnGroupThread() {
        let allGroupTypes: [GroupType] = [.closedGroup, .openGroup, .rssFeed]
        for groupType in allGroupTypes {
            guard let groupThread = createGroupThread(groupType: groupType) else { return XCTFail() }
            XCTAssertTrue(FriendRequestProtocol.shouldInputBarBeEnabled(for: groupThread))
        }
    }

    func test_shouldInputBarBeEnabledReturnsTrueOnNoteToSelf() {
        guard let master = OWSIdentityManager.shared().identityKeyPair()?.hexEncodedPublicKey else { return XCTFail() }
        let slave = generateHexEncodedPublicKey()

        guard let masterDevice = getDevice(for: master) else { return XCTFail() }
        guard let slaveDevice = getDevice(for: slave) else { return XCTFail() }

        let deviceLink = DeviceLink(between: masterDevice, and: slaveDevice)
        storage.dbReadWriteConnection.readWrite { transaction in
            self.storage.addDeviceLink(deviceLink, in: transaction)
            self.storage.setFriendRequestStatus(.requestSent, forContact: master, transaction: transaction)
            self.storage.setFriendRequestStatus(.requestSent, forContact: slave, transaction: transaction)
        }

        let masterThread = createContactThread(for: master)
        let slaveThread = createContactThread(for: slave)

        XCTAssertTrue(FriendRequestProtocol.shouldInputBarBeEnabled(for: masterThread))
        XCTAssertTrue(FriendRequestProtocol.shouldInputBarBeEnabled(for: slaveThread))
    }

    func test_shouldInputBarBeEnabledReturnsTrueWhenStatusIsNotPending() {
        let validStatuses: [LKFriendRequestStatus] = [.none, .requestExpired, .friends]
        let device = Curve25519.generateKeyPair().hexEncodedPublicKey
        let thread = createContactThread(for: device)

        for status in validStatuses {
            storage.dbReadWriteConnection.readWrite { transaction in
                self.storage.setFriendRequestStatus(status, forContact: device, transaction: transaction)
            }
            XCTAssertTrue(FriendRequestProtocol.shouldInputBarBeEnabled(for: thread))
        }
    }

    func test_shouldInputBarBeEnabledReturnsFalseWhenStatusIsPending() {
        let pendingStatuses: [LKFriendRequestStatus] = [.requestSending, .requestSent, .requestReceived]
        let device = Curve25519.generateKeyPair().hexEncodedPublicKey
        let thread = createContactThread(for: device)

        for status in pendingStatuses {
            storage.dbReadWriteConnection.readWrite { transaction in
                self.storage.setFriendRequestStatus(status, forContact: device, transaction: transaction)
            }
            XCTAssertFalse(FriendRequestProtocol.shouldInputBarBeEnabled(for: thread))
        }
    }

    func test_shouldInputBarBeEnabledReturnsTrueWhenFriendsWithOneLinkedDevice() {
        let master = generateHexEncodedPublicKey()
        let slave = generateHexEncodedPublicKey()

        guard let masterDevice = getDevice(for: master) else { return XCTFail() }
        guard let slaveDevice = getDevice(for: slave) else { return XCTFail() }

        let deviceLink = DeviceLink(between: masterDevice, and: slaveDevice)
        storage.dbReadWriteConnection.readWrite { transaction in
            self.storage.addDeviceLink(deviceLink, in: transaction)
            self.storage.setFriendRequestStatus(.friends, forContact: master, transaction: transaction)
            self.storage.setFriendRequestStatus(.requestSent, forContact: slave, transaction: transaction)
        }

        let masterThread = createContactThread(for: master)
        let slaveThread = createContactThread(for: slave)

        XCTAssertTrue(FriendRequestProtocol.shouldInputBarBeEnabled(for: masterThread))
        XCTAssertTrue(FriendRequestProtocol.shouldInputBarBeEnabled(for: slaveThread))
    }

    func test_shouldInputBarBeEnabledReturnsFalseWhenOneLinkedDeviceIsPending() {
        let master = generateHexEncodedPublicKey()
        let slave = generateHexEncodedPublicKey()

        guard let masterDevice = getDevice(for: master) else { return XCTFail() }
        guard let slaveDevice = getDevice(for: slave) else { return XCTFail() }

        let deviceLink = DeviceLink(between: masterDevice, and: slaveDevice)
        storage.dbReadWriteConnection.readWrite { transaction in
            self.storage.addDeviceLink(deviceLink, in: transaction)
            self.storage.setFriendRequestStatus(.none, forContact: master, transaction: transaction)
        }

        let masterThread = createContactThread(for: master)
        let slaveThread = createContactThread(for: slave)

        let pendingStatuses: [LKFriendRequestStatus] = [.requestSending, .requestSent, .requestReceived]
        for status in pendingStatuses {
            storage.dbReadWriteConnection.readWrite { transaction in
                self.storage.setFriendRequestStatus(status, forContact: slave, transaction: transaction)
            }
            XCTAssertFalse(FriendRequestProtocol.shouldInputBarBeEnabled(for: masterThread))
            XCTAssertFalse(FriendRequestProtocol.shouldInputBarBeEnabled(for: slaveThread))
        }
    }

    func test_shouldInputBarBeEnabledReturnsTrueWhenAllLinkedDevicesAreNotPendingAndNotFriends() {
        let master = generateHexEncodedPublicKey()
        let slave = generateHexEncodedPublicKey()

        guard let masterDevice = getDevice(for: master) else { return XCTFail() }
        guard let slaveDevice = getDevice(for: slave) else { return XCTFail() }

        let deviceLink = DeviceLink(between: masterDevice, and: slaveDevice)
        storage.dbReadWriteConnection.readWrite { transaction in
            self.storage.addDeviceLink(deviceLink, in: transaction)
            self.storage.setFriendRequestStatus(.none, forContact: master, transaction: transaction)
            self.storage.setFriendRequestStatus(.none, forContact: slave, transaction: transaction)
        }

        let masterThread = createContactThread(for: master)
        let slaveThread = createContactThread(for: slave)

        let safeStatuses: [LKFriendRequestStatus] = [.requestExpired, .none]
        for status in safeStatuses {
            storage.dbReadWriteConnection.readWrite { transaction in
                self.storage.setFriendRequestStatus(status, forContact: slave, transaction: transaction)
            }
            XCTAssertTrue(FriendRequestProtocol.shouldInputBarBeEnabled(for: masterThread))
            XCTAssertTrue(FriendRequestProtocol.shouldInputBarBeEnabled(for: slaveThread))
        }
    }

    // MARK: - shouldAttachmentButtonBeEnabled

    func test_shouldAttachmentButtonBeEnabledReturnsTrueOnGroupThread() {
        let allGroupTypes: [GroupType] = [.closedGroup, .openGroup, .rssFeed]
        for groupType in allGroupTypes {
            guard let groupThread = createGroupThread(groupType: groupType) else { return XCTFail() }
            XCTAssertTrue(FriendRequestProtocol.shouldAttachmentButtonBeEnabled(for: groupThread))
        }
    }

    func test_shouldAttachmentButtonBeEnabledReturnsTrueOnNoteToSelf() {
        guard let master = OWSIdentityManager.shared().identityKeyPair()?.hexEncodedPublicKey else { return XCTFail() }
        let slave = generateHexEncodedPublicKey()

        guard let masterDevice = getDevice(for: master) else { return XCTFail() }
        guard let slaveDevice = getDevice(for: slave) else { return XCTFail() }

        let deviceLink = DeviceLink(between: masterDevice, and: slaveDevice)
        storage.dbReadWriteConnection.readWrite { transaction in
            self.storage.addDeviceLink(deviceLink, in: transaction)
            self.storage.setFriendRequestStatus(.requestSent, forContact: master, transaction: transaction)
            self.storage.setFriendRequestStatus(.requestSent, forContact: slave, transaction: transaction)
        }

        let masterThread = createContactThread(for: master)
        let slaveThread = createContactThread(for: slave)

        XCTAssertTrue(FriendRequestProtocol.shouldAttachmentButtonBeEnabled(for: masterThread))
        XCTAssertTrue(FriendRequestProtocol.shouldAttachmentButtonBeEnabled(for: slaveThread))
    }

    func test_shouldAttachmentButtonBeEnabledReturnsTrueWhenFriends() {
        let device = Curve25519.generateKeyPair().hexEncodedPublicKey
        let thread = createContactThread(for: device)

        storage.dbReadWriteConnection.readWrite { transaction in
            self.storage.setFriendRequestStatus(.friends, forContact: device, transaction: transaction)
        }
        XCTAssertTrue(FriendRequestProtocol.shouldAttachmentButtonBeEnabled(for: thread))
    }

    func test_shouldAttachmentButtonBeEnabledReturnsFalseWhenNotFriends() {
        let nonFriendStatuses: [LKFriendRequestStatus] = [.requestSending, .requestSent, .requestReceived, .none, .requestExpired]
        let device = Curve25519.generateKeyPair().hexEncodedPublicKey
        let thread = createContactThread(for: device)

        for status in nonFriendStatuses {
            storage.dbReadWriteConnection.readWrite { transaction in
                self.storage.setFriendRequestStatus(status, forContact: device, transaction: transaction)
            }
            XCTAssertFalse(FriendRequestProtocol.shouldAttachmentButtonBeEnabled(for: thread))
        }
    }

    func test_shouldAttachmentButtonBeEnabledReturnsTrueWhenFriendsWithOneLinkedDevice() {
        let master = generateHexEncodedPublicKey()
        let slave = generateHexEncodedPublicKey()

        guard let masterDevice = getDevice(for: master) else { return XCTFail() }
        guard let slaveDevice = getDevice(for: slave) else { return XCTFail() }

        let deviceLink = DeviceLink(between: masterDevice, and: slaveDevice)
        storage.dbReadWriteConnection.readWrite { transaction in
            self.storage.addDeviceLink(deviceLink, in: transaction)
            self.storage.setFriendRequestStatus(.friends, forContact: master, transaction: transaction)
            self.storage.setFriendRequestStatus(.requestSent, forContact: slave, transaction: transaction)
        }

        let masterThread = createContactThread(for: master)
        let slaveThread = createContactThread(for: slave)

        XCTAssertTrue(FriendRequestProtocol.shouldAttachmentButtonBeEnabled(for: masterThread))
        XCTAssertTrue(FriendRequestProtocol.shouldAttachmentButtonBeEnabled(for: slaveThread))
    }

    // MARK: - acceptFriendRequest

    func test_acceptFriendRequestShouldSetStatusToFriendsIfWeReceivedAFriendRequest() {
        // Case: Bob sent us a friend request, we should become friends with him on accepting
        let bob = Curve25519.generateKeyPair().hexEncodedPublicKey
        storage.dbReadWriteConnection.readWrite { transaction in
            self.storage.setFriendRequestStatus(.requestReceived, forContact: bob, transaction: transaction)

        }

        storage.dbReadWriteConnection.readWrite { transaction in
            FriendRequestProtocol.acceptFriendRequest(from: bob, using: transaction)
            XCTAssertTrue(self.storage.getFriendRequestStatus(forContact: bob, transaction: transaction) == .friends)
        }
    }

    func test_acceptFriendRequestShouldSendAMessageIfStatusIsNoneOrExpired() {
        // Case: Somehow our friend request status doesn't match the UI
        // Since user accepted then we should send a friend request message
        let statuses: [LKFriendRequestStatus] = [.none, .requestExpired]
        for status in statuses {
            let bob = Curve25519.generateKeyPair().hexEncodedPublicKey
            storage.dbReadWriteConnection.readWrite { transaction in
                self.storage.setFriendRequestStatus(status, forContact: bob, transaction: transaction)
            }

            storage.dbReadWriteConnection.readWrite { transaction in
                FriendRequestProtocol.acceptFriendRequest(from: bob, using: transaction)
                XCTAssertTrue(self.isFriendRequestStatus([.requestSending, .requestSent], for: bob, transaction: transaction))
            }
        }
    }

    func test_acceptFriendRequestShouldNotDoAnythingIfRequestHasBeenSent() {
        // Case: We sent Bob a friend request.
        // We can't accept because we don't have keys to communicate with Bob.
        let bob = Curve25519.generateKeyPair().hexEncodedPublicKey
        storage.dbReadWriteConnection.readWrite { transaction in
            self.storage.setFriendRequestStatus(.requestSent, forContact: bob, transaction: transaction)

        }

        storage.dbReadWriteConnection.readWrite { transaction in
            FriendRequestProtocol.acceptFriendRequest(from: bob, using: transaction)
            XCTAssertTrue(self.isFriendRequestStatus(.requestSent, for: bob, transaction: transaction))
        }
    }

    func test_acceptFriendRequestShouldWorkWithMultiDevice() {
        // Case: Bob sent a friend request from his slave device.
        // Accepting the friend request should set it to friends.
        // We should also send out a friend request to Bob's other devices if possible.
        let master = generateHexEncodedPublicKey()
        let slave = generateHexEncodedPublicKey()
        let otherSlave = generateHexEncodedPublicKey()

        guard let masterDevice = getDevice(for: master) else { return XCTFail() }
        guard let slaveDevice = getDevice(for: slave) else { return XCTFail() }
        guard let otherSlaveDevice = getDevice(for: otherSlave) else { return XCTFail() }

        storage.dbReadWriteConnection.readWrite { transaction in
            self.storage.addDeviceLink(DeviceLink(between: masterDevice, and: slaveDevice), in: transaction)
            self.storage.addDeviceLink(DeviceLink(between: masterDevice, and: otherSlaveDevice), in: transaction)
            self.storage.setFriendRequestStatus(.none, forContact: master, transaction: transaction)
            self.storage.setFriendRequestStatus(.requestReceived, forContact: slave, transaction: transaction)
            self.storage.setFriendRequestStatus(.requestSent, forContact: otherSlave, transaction: transaction)
        }

        storage.dbReadWriteConnection.readWrite { transaction in
            FriendRequestProtocol.acceptFriendRequest(from: master, using: transaction)
            XCTAssertTrue(self.isFriendRequestStatus([.requestSending, .requestSent], for: master, transaction: transaction))
            XCTAssertTrue(self.isFriendRequestStatus(.friends, for: slave, transaction: transaction))
            XCTAssertTrue(self.isFriendRequestStatus(.requestSent, for: otherSlave, transaction: transaction))
        }
    }

    func test_acceptFriendRequestShouldNotChangeStatusIfDevicesAreNotLinked() {
        let alice = generateHexEncodedPublicKey()
        let bob = generateHexEncodedPublicKey()

        storage.dbReadWriteConnection.readWrite { transaction in
            self.storage.setFriendRequestStatus(.requestReceived, forContact: alice, transaction: transaction)
            self.storage.setFriendRequestStatus(.requestReceived, forContact: bob, transaction: transaction)
        }

        storage.dbReadWriteConnection.readWrite { transaction in
            FriendRequestProtocol.acceptFriendRequest(from: alice, using: transaction)
            XCTAssertTrue(self.isFriendRequestStatus(.friends, for: alice, transaction: transaction))
            XCTAssertTrue(self.isFriendRequestStatus(.requestReceived, for: bob, transaction: transaction))
        }
    }
}
