import Foundation
import SessionUtilitiesKit

public extension Threading {
    static let pollerQueue = DispatchQueue(label: "SessionMessagingKit.pollerQueue")
    static let groupPollerQueue = DispatchQueue(label: "SessionMessagingKit.groupPollerQueue")
    static let communityPollerQueue = DispatchQueue(label: "SessionMessagingKit.communityPollerQueue")
}
