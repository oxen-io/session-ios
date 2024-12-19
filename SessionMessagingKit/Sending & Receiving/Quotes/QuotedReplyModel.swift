// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public struct QuotedReplyModel {
    public let threadId: String
    public let authorId: String
    public let timestampMs: Int64
    public let body: String?
    public let attachment: Attachment?
    public let contentType: String?
    public let sourceFileName: String?
    public let thumbnailDownloadFailed: Bool
    public let currentUserSessionId: String?
    public let currentUserBlinded15SessionId: String?
    public let currentUserBlinded25SessionId: String?
    
    // MARK: - Initialization
    
    init(
        threadId: String,
        authorId: String,
        timestampMs: Int64,
        body: String?,
        attachment: Attachment?,
        contentType: String?,
        sourceFileName: String?,
        thumbnailDownloadFailed: Bool,
        currentUserSessionId: String?,
        currentUserBlinded15SessionId: String?,
        currentUserBlinded25SessionId: String?
    ) {
        self.attachment = attachment
        self.threadId = threadId
        self.authorId = authorId
        self.timestampMs = timestampMs
        self.body = body
        self.contentType = contentType
        self.sourceFileName = sourceFileName
        self.thumbnailDownloadFailed = thumbnailDownloadFailed
        self.currentUserSessionId = currentUserSessionId
        self.currentUserBlinded15SessionId = currentUserBlinded15SessionId
        self.currentUserBlinded25SessionId = currentUserBlinded25SessionId
    }
    
    public static func quotedReplyForSending(
        threadId: String,
        authorId: String,
        variant: Interaction.Variant,
        body: String?,
        timestampMs: Int64,
        attachments: [Attachment]?,
        linkPreviewAttachment: Attachment?,
        currentUserSessionId: String?,
        currentUserBlinded15SessionId: String?,
        currentUserBlinded25SessionId: String?
    ) -> QuotedReplyModel? {
        guard variant == .standardOutgoing || variant == .standardIncoming else { return nil }
        guard (body != nil && body?.isEmpty == false) || attachments?.isEmpty == false else { return nil }
        
        let targetAttachment: Attachment? = (attachments?.first ?? linkPreviewAttachment)
        
        return QuotedReplyModel(
            threadId: threadId,
            authorId: authorId,
            timestampMs: timestampMs,
            body: body,
            attachment: targetAttachment,
            contentType: targetAttachment?.contentType,
            sourceFileName: targetAttachment?.sourceFilename,
            thumbnailDownloadFailed: false,
            currentUserSessionId: currentUserSessionId,
            currentUserBlinded15SessionId: currentUserBlinded15SessionId,
            currentUserBlinded25SessionId: currentUserBlinded25SessionId
        )
    }
}
