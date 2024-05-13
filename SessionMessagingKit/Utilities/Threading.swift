import Foundation

public enum Threading {
    public static let pollerQueue = DispatchQueue(label: "SessionMessagingKit.pollerQueue")
    public static let groupPollerQueue = DispatchQueue(label: "SessionMessagingKit.groupPollerQueue")
    public static let communityPollerQueue = DispatchQueue(label: "SessionMessagingKit.communityPollerQueue")
}
