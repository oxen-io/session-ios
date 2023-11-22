// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionSnodeKit

public enum GetExpirationJob: JobExecutor {
    public static var maxFailureCount: Int = -1
    public static var requiresThreadId: Bool = true
    public static var requiresInteractionId: Bool = false
    private static let minRunFrequency: TimeInterval = 5
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool, Dependencies) -> (),
        failure: @escaping (Job, Error?, Bool, Dependencies) -> (),
        deferred: @escaping (Job, Dependencies) -> (),
        using dependencies: Dependencies
    ) {
        guard
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData)
        else {
            SNLog("[GetExpirationJob] Failing due to missing details")
            failure(job, JobRunnerError.missingRequiredDetails, true, dependencies)
            return
        }
        
        let expirationInfo: [String: Double] = dependencies[singleton: .storage]
            .read(using: dependencies) { db -> [String: Double] in
                details
                    .expirationInfo
                    .filter { Interaction.filter(Interaction.Columns.serverHash == $0.key).isNotEmpty(db) }
            }
            .defaulting(to: details.expirationInfo)
        
        guard expirationInfo.count > 0 else {
            success(job, false, dependencies)
            return
        }
        
        let userSessionId: SessionId = getUserSessionId(using: dependencies)
        
        return dependencies[singleton: .storage]
            .readPublisher(using: dependencies) { db in
                try SnodeAPI
                    .preparedGetExpiries(
                        of: expirationInfo.map { $0.key },
                        authMethod: try Authentication.with(
                            db,
                            sessionIdHexString: userSessionId.hexString,
                            using: dependencies
                        ),
                        using: dependencies
                    )
            }
            .flatMap { $0.send(using: dependencies) }
            .subscribe(on: queue, using: dependencies)
            .receive(on: queue, using: dependencies)
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error): failure(job, error, true, dependencies)
                    }
                },
                receiveValue: { _, response in
                    let serverSpecifiedExpirationStartTimesMs: [String: Double] = response.expiries
                        .reduce(into: [:]) { result, next in
                            guard let expiresInSeconds: Double = expirationInfo[next.key] else { return }
                            
                            result[next.key] = Double(next.value - UInt64(expiresInSeconds * 1000))
                        }
                    let hashesToUseDefault: Set<String> = Set(expirationInfo.keys)
                        .subtracting(serverSpecifiedExpirationStartTimesMs.keys)
                    
                    dependencies[singleton: .storage].write(using: dependencies) { db in
                        try serverSpecifiedExpirationStartTimesMs.forEach { hash, expiresStartedAtMs in
                            try Interaction
                                .filter(Interaction.Columns.serverHash == hash)
                                .updateAll(
                                    db,
                                    Interaction.Columns.expiresStartedAtMs.set(to: expiresStartedAtMs)
                                )
                        }
                        
                        try Interaction
                            .filter(hashesToUseDefault.contains(Interaction.Columns.serverHash))
                            .filter(Interaction.Columns.expiresStartedAtMs == nil)
                            .updateAll(
                                db,
                                Interaction.Columns.expiresStartedAtMs.set(to: details.startedAtTimestampMs)
                            )
                        
                        dependencies[singleton: .jobRunner]
                            .upsert(
                                db,
                                job: DisappearingMessagesJob.updateNextRunIfNeeded(db),
                                canStartJob: true,
                                using: dependencies
                            )
                    }
                    
                    guard hashesToUseDefault.isEmpty else {
                        let updatedJob: Job? = dependencies[singleton: .storage].write(using: dependencies) { db in
                            try job
                                .with(nextRunTimestamp: dependencies.dateNow.timeIntervalSince1970 + minRunFrequency)
                                .upserted(db)
                        }
                        
                        return deferred(updatedJob ?? job, dependencies)
                    }
                        
                    success(job, false, dependencies)
                }
            )
    }
}

// MARK: - GetExpirationJob.Details

extension GetExpirationJob {
    public struct Details: Codable {
        private enum CodingKeys: String, CodingKey {
            case expirationInfo
            case startedAtTimestampMs
        }
        
        public let expirationInfo: [String: Double]
        public let startedAtTimestampMs: Double
        
        // MARK: - Initialization
        
        public init(
            expirationInfo: [String: Double],
            startedAtTimestampMs: Double
        ) {
            self.expirationInfo = expirationInfo
            self.startedAtTimestampMs = startedAtTimestampMs
        }
        
        // MARK: - Codable
        
        public init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            self = Details(
                expirationInfo: try container.decode([String: Double].self, forKey: .expirationInfo),
                startedAtTimestampMs: try container.decode(Double.self, forKey: .startedAtTimestampMs)
            )
        }
        
        public func encode(to encoder: Encoder) throws {
            var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)

            try container.encode(expirationInfo, forKey: .expirationInfo)
            try container.encode(startedAtTimestampMs, forKey: .startedAtTimestampMs)
        }
    }
}
