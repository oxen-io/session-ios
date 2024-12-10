// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("MessageReceiveJob", defaultLevel: .info)
}

// MARK: - MessageReceiveJob

public enum MessageReceiveJob: JobExecutor {
    public static var maxFailureCount: Int = 10
    public static var requiresThreadId: Bool = true
    public static let requiresInteractionId: Bool = false
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool) -> Void,
        failure: @escaping (Job, Error, Bool) -> Void,
        deferred: @escaping (Job) -> Void,
        using dependencies: Dependencies
    ) {
        guard
            let threadId: String = job.threadId,
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData)
        else { return failure(job, JobRunnerError.missingRequiredDetails, true) }
        
        var updatedJob: Job = job
        var lastError: Error?
        var remainingMessagesToProcess: [Details.MessageInfo] = []
        let messageData: [(info: Details.MessageInfo, proto: SNProtoContent)] = details.messages
            .compactMap { messageInfo -> (info: Details.MessageInfo, proto: SNProtoContent)? in
                do {
                    return (messageInfo, try SNProtoContent.parseData(messageInfo.serializedProtoData))
                }
                catch {
                    Log.error(.cat, "Couldn't receive message due to error: \(error)")
                    lastError = error
                    
                    // We failed to process this message but it is a retryable error
                    // so add it to the list to re-process
                    remainingMessagesToProcess.append(messageInfo)
                    return nil
                }
            }
        
        dependencies[singleton: .storage].write { db in
            for (messageInfo, protoContent) in messageData {
                do {
                    try MessageReceiver.handle(
                        db,
                        threadId: threadId,
                        threadVariant: messageInfo.threadVariant,
                        message: messageInfo.message,
                        serverExpirationTimestamp: messageInfo.serverExpirationTimestamp,
                        associatedWithProto: protoContent,
                        using: dependencies
                    )
                }
                catch {
                    // If the current message is a permanent failure then override it with the
                    // new error (we want to retry if there is a single non-permanent error)
                    switch error {
                        // Ignore duplicate and self-send errors (these will usually be caught during
                        // parsing but sometimes can get past and conflict at database insertion - eg.
                        // for open group messages) we also don't bother logging as it results in
                        // excessive logging which isn't useful)
                        case DatabaseError.SQLITE_CONSTRAINT_UNIQUE,
                            DatabaseError.SQLITE_CONSTRAINT,    // Sometimes thrown for UNIQUE
                            MessageReceiverError.duplicateMessage,
                            MessageReceiverError.duplicateControlMessage,
                            MessageReceiverError.selfSend:
                            break
                        
                        case let receiverError as MessageReceiverError where !receiverError.isRetryable:
                            Log.error(.cat, "Permanently failed message due to error: \(error)")
                            continue
                        
                        default:
                            Log.error(.cat, "Couldn't receive message due to error: \(error)")
                            lastError = error
                            
                            // We failed to process this message but it is a retryable error
                            // so add it to the list to re-process
                            remainingMessagesToProcess.append(messageInfo)
                    }
                }
            }
            
            // If any messages failed to process then we want to update the job to only include
            // those failed messages
            guard !remainingMessagesToProcess.isEmpty else { return }
            
            updatedJob = try job
                .with(details: Details(messages: remainingMessagesToProcess))
                .defaulting(to: job)
                .upserted(db)
        }
        
        // Handle the result
        switch lastError {
            case let error as MessageReceiverError where !error.isRetryable: failure(updatedJob, error, true)
            case .some(let error): failure(updatedJob, error, false)
            case .none: success(updatedJob, false)
        }
    }
}

// MARK: - MessageReceiveJob.Details

extension MessageReceiveJob {
    public struct Details: Codable {
        public struct MessageInfo: Codable {
            private enum CodingKeys: String, CodingKey {
                case message
                case variant
                case threadVariant
                case serverExpirationTimestamp
                case serializedProtoData
            }
            
            public let message: Message
            public let variant: Message.Variant
            public let threadVariant: SessionThread.Variant
            public let serverExpirationTimestamp: TimeInterval?
            public let serializedProtoData: Data
            
            public init(
                message: Message,
                variant: Message.Variant,
                threadVariant: SessionThread.Variant,
                serverExpirationTimestamp: TimeInterval?,
                proto: SNProtoContent
            ) throws {
                self.message = message
                self.variant = variant
                self.threadVariant = threadVariant
                self.serverExpirationTimestamp = serverExpirationTimestamp
                self.serializedProtoData = try proto.serializedData()
            }
            
            private init(
                message: Message,
                variant: Message.Variant,
                threadVariant: SessionThread.Variant,
                serverExpirationTimestamp: TimeInterval?,
                serializedProtoData: Data
            ) {
                self.message = message
                self.variant = variant
                self.threadVariant = threadVariant
                self.serverExpirationTimestamp = serverExpirationTimestamp
                self.serializedProtoData = serializedProtoData
            }
            
            // MARK: - Codable
            
            public init(from decoder: Decoder) throws {
                let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
                
                guard let variant: Message.Variant = try? container.decode(Message.Variant.self, forKey: .variant) else {
                    Log.error(.cat, "Unable to decode messageReceive job due to missing variant")
                    throw StorageError.decodingFailed
                }
                
                self = MessageInfo(
                    message: try variant.decode(from: container, forKey: .message),
                    variant: variant,
                    threadVariant: try container.decode(SessionThread.Variant.self, forKey: .threadVariant),
                    serverExpirationTimestamp: try? container.decode(TimeInterval.self, forKey: .serverExpirationTimestamp),
                    serializedProtoData: try container.decode(Data.self, forKey: .serializedProtoData)
                )
            }
            
            public func encode(to encoder: Encoder) throws {
                var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
                
                guard let variant: Message.Variant = Message.Variant(from: message) else {
                    Log.error(.cat, "Unable to encode messageReceive job due to unsupported variant")
                    throw StorageError.objectNotFound
                }

                try container.encode(message, forKey: .message)
                try container.encode(variant, forKey: .variant)
                try container.encode(threadVariant, forKey: .threadVariant)
                try container.encodeIfPresent(serverExpirationTimestamp, forKey: .serverExpirationTimestamp)
                try container.encode(serializedProtoData, forKey: .serializedProtoData)
            }
        }
        
        public let messages: [MessageInfo]
        
        public init(messages: [ProcessedMessage]) {
            self.messages = messages.compactMap { processedMessage in
                switch processedMessage {
                    case .config: return nil
                    case .standard(_, _, _, let messageInfo): return messageInfo
                }
            }
        }
        
        public init(messages: [MessageInfo]) {
            self.messages = messages
        }
    }
}
