// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import PushKit
import GRDB
import SessionMessagingKit
import SignalUtilitiesKit
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let pushRegistrationManager: SingletonConfig<PushRegistrationManager> = Dependencies.create(
        identifier: "pushRegistrationManager",
        createInstance: { dependencies in PushRegistrationManager(using: dependencies) }
    )
}

// MARK: - PushRegistrationManager

public class PushRegistrationManager: NSObject, PKPushRegistryDelegate {
    private let dependencies: Dependencies
    
    private var vanillaTokenPublisher: AnyPublisher<Data, Error>?
    private var vanillaTokenResolver: ((Result<Data, Error>) -> ())?

    private var voipRegistry: PKPushRegistry?
    private var voipTokenPublisher: AnyPublisher<Data?, Error>?
    private var voipTokenResolver: ((Result<Data?, Error>) -> ())?

    // MARK: - Initialization

    fileprivate init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        super.init()
    }

    // MARK: - Public interface

    public func requestPushTokens() -> AnyPublisher<(pushToken: String, voipToken: String), Error> {
        return registerUserNotificationSettings()
            .setFailureType(to: Error.self)
            .tryFlatMap { _ -> AnyPublisher<(pushToken: String, voipToken: String), Error> in
                #if targetEnvironment(simulator)
                throw PushRegistrationError.pushNotSupported(description: "Push not supported on simulators")
                #else
                return self.registerForVanillaPushToken()
                    .flatMap { vanillaPushToken -> AnyPublisher<(pushToken: String, voipToken: String), Error> in
                        self.registerForVoipPushToken()
                            .map { voipPushToken in (vanillaPushToken, (voipPushToken ?? "")) }
                            .eraseToAnyPublisher()
                    }
                    .eraseToAnyPublisher()
                #endif
            }
            .eraseToAnyPublisher()
    }

    // MARK: Vanilla push token

    /// Vanilla push token is obtained from the system via AppDelegate
    public func didReceiveVanillaPushToken(_ tokenData: Data) {
        guard let vanillaTokenResolver = self.vanillaTokenResolver else {
            Log.error("[PushRegistrationManager] Publisher completion in \(#function) unexpectedly nil")
            return
        }

        DispatchQueue.global(qos: .default).async(using: dependencies) {
            vanillaTokenResolver(Result.success(tokenData))
        }
    }

    /// Vanilla push token is obtained from the system via AppDelegate
    public func didFailToReceiveVanillaPushToken(error: Error) {
        guard let vanillaTokenResolver = self.vanillaTokenResolver else {
            Log.error("[PushRegistrationManager] Publisher completion in \(#function) unexpectedly nil")
            return
        }

        DispatchQueue.global(qos: .default).async(using: dependencies) {
            vanillaTokenResolver(Result.failure(error))
        }
    }

    // MARK: helpers

    /// User notification settings must be registered *before* AppDelegate will return any requested push tokens.
    public func registerUserNotificationSettings() -> AnyPublisher<Void, Never> {
        return dependencies[singleton: .notificationsManager].registerNotificationSettings()
    }

    /**
     * When users have disabled notifications and background fetch, the system hangs when returning a push token.
     * More specifically, after registering for remote notification, the app delegate calls neither
     * `didFailToRegisterForRemoteNotificationsWithError` nor `didRegisterForRemoteNotificationsWithDeviceToken`
     * This behavior is identical to what you'd see if we hadn't previously registered for user notification settings, though
     * in this case we've verified that we *have* properly registered notification settings.
     */
    private var isSusceptibleToFailedPushRegistration: Bool {
        // Only affects users who have disabled both: background refresh *and* notifications
        guard
            let notificationSettings: UIUserNotificationSettings = DispatchQueue.main.sync(execute: {
                guard UIApplication.shared.backgroundRefreshStatus == .denied else { return nil }
                
                return UIApplication.shared.currentUserNotificationSettings
            })
        else { return false }

        guard notificationSettings.types == [] else {
            return false
        }

        return true
    }

    private func registerForVanillaPushToken() -> AnyPublisher<String, Error> {
        // Use the existing publisher if it exists
        if let vanillaTokenPublisher: AnyPublisher<Data, Error> = self.vanillaTokenPublisher {
            return vanillaTokenPublisher
                .map { $0.toHexString() }
                .eraseToAnyPublisher()
        }
        
        // No pending vanilla token yet; create a new publisher
        let publisher: AnyPublisher<Data, Error> = Deferred {
            Future<Data, Error> {
                self.vanillaTokenResolver = $0
                
                // Tell the device to register for remote notifications
                DispatchQueue.main.sync { UIApplication.shared.registerForRemoteNotifications() }
            }
        }
        .shareReplay(1)
        .eraseToAnyPublisher()
        self.vanillaTokenPublisher = publisher
        
        return publisher
            .timeout(
                .seconds(10),
                scheduler: DispatchQueue.global(qos: .default),
                customError: { PushRegistrationError.timeout }
            )
            .catch { error -> AnyPublisher<Data, Error> in
                switch error {
                    case PushRegistrationError.timeout:
                        guard self.isSusceptibleToFailedPushRegistration else {
                            // Sometimes registration can just take a while.
                            // If we're not on a device known to be susceptible to push registration failure,
                            // just return the original publisher.
                            guard let originalPublisher: AnyPublisher<Data, Error> = self.vanillaTokenPublisher else {
                                return Fail(error: PushRegistrationError.publisherNoLongerExists)
                                    .eraseToAnyPublisher()
                            }
                            
                            // Give the original publisher another 10 seconds to complete before we timeout (we
                            // don't want this to run forever as it could block other jobs)
                            return originalPublisher
                                .timeout(
                                    .seconds(10),
                                    scheduler: DispatchQueue.global(qos: .default),
                                    customError: { PushRegistrationError.timeout }
                                )
                                .eraseToAnyPublisher()
                        }
                        
                        // If we've timed out on a device known to be susceptible to failures, quit trying
                        // so the user doesn't remain indefinitely hung for no good reason.
                        return Fail(
                            error: PushRegistrationError.pushNotSupported(
                                description: "Device configuration disallows push notifications" // stringlint:ignore
                            )
                        ).eraseToAnyPublisher()
                        
                    default:
                        return Fail(error: error)
                            .eraseToAnyPublisher()
                }
            }
            .map { tokenData -> String in
                if self.isSusceptibleToFailedPushRegistration {
                    // Sentinal in case this bug is fixed
                    Log.debug("Device was unexpectedly able to complete push registration even though it was susceptible to failure.")
                }
                
                return tokenData.toHexString()
            }
            .handleEvents(
                receiveCompletion: { _ in
                    self.vanillaTokenPublisher = nil
                    self.vanillaTokenResolver = nil
                }
            )
            .eraseToAnyPublisher()
    }
    
    public func createVoipRegistryIfNecessary() {
        guard voipRegistry == nil else { return }
        
        let voipRegistry = PKPushRegistry(queue: nil)
        self.voipRegistry = voipRegistry
        voipRegistry.desiredPushTypes = [.voIP]
        voipRegistry.delegate = self
    }
    
    private func registerForVoipPushToken() -> AnyPublisher<String?, Error> {
        // Use the existing publisher if it exists
        if let voipTokenPublisher: AnyPublisher<Data?, Error> = self.voipTokenPublisher {
            return voipTokenPublisher
                .map { $0?.toHexString() }
                .eraseToAnyPublisher()
        }
        
        // We don't create the voip registry in init, because it immediately requests the voip token,
        // potentially before we're ready to handle it.
        createVoipRegistryIfNecessary()
        
        guard let voipRegistry: PKPushRegistry = self.voipRegistry else {
            Log.error("[PushRegistrationManager] Failed to initialize voipRegistry")
            return Fail(
                error: PushRegistrationError.assertionError(description: "failed to initialize voipRegistry")
            ).eraseToAnyPublisher()
        }
        
        // If we've already completed registering for a voip token, resolve it immediately,
        // rather than waiting for the delegate method to be called.
        if let voipTokenData: Data = voipRegistry.pushToken(for: .voIP) {
            Log.info("[PushRegistrationManager] Using pre-registered voIP token")
            return Just(voipTokenData.toHexString())
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        // No pending voip token yet. Create a new publisher
        let publisher: AnyPublisher<Data?, Error> = Deferred {
            Future<Data?, Error> { self.voipTokenResolver = $0 }
        }
        .eraseToAnyPublisher()
        self.voipTokenPublisher = publisher
        
        return publisher
            .map { voipTokenData -> String? in
                Log.info("[PushRegistrationManager] Successfully registered for voip push notifications")
                return voipTokenData?.toHexString()
            }
            .handleEvents(
                receiveCompletion: { _ in
                    self.voipTokenPublisher = nil
                    self.voipTokenResolver = nil
                }
            )
            .eraseToAnyPublisher()
    }
    
    // MARK: - PKPushRegistryDelegate
    
    public func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        Log.assert(type == .voIP)
        Log.assert(pushCredentials.type == .voIP)

        voipTokenResolver?(Result.success(pushCredentials.token))
    }
    
    // NOTE: This function MUST report an incoming call.
    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType) {
        Log.info("[PushRegistrationManager] Receive new voip notification.")
        Log.assert(dependencies[singleton: .appContext].isMainApp)
        Log.assert(type == .voIP)
        let payload = payload.dictionaryPayload
        
        guard
            let uuid: String = payload["uuid"] as? String,
            let caller: String = payload["caller"] as? String,
            let timestampMs: UInt64 = payload["timestamp"] as? UInt64,
            TimestampUtils.isWithinOneMinute(timestampMs: timestampMs)
        else {
            dependencies[singleton: .callManager].reportFakeCall(info: "Missing payload data") // stringlint:ignore
            return
        }
        
        dependencies[singleton: .storage].resumeDatabaseAccess()
        dependencies.mutate(cache: .libSessionNetwork) { $0.resumeNetworkAccess() }
        
        let maybeCall: SessionCall? = dependencies[singleton: .storage].write { [dependencies] db in
            var call: SessionCall? = nil
            
            do {
                call = SessionCall(
                    db,
                    for: caller,
                    uuid: uuid,
                    mode: .answer,
                    using: dependencies
                )
                
                let interaction: Interaction? = try Interaction
                    .filter(Interaction.Columns.threadId == caller)
                    .filter(Interaction.Columns.messageUuid == uuid)
                    .fetchOne(db)
                
                call?.callInteractionId = interaction?.id
            }
            catch {
                Log.error(.calls, "Failed to create call due to error: \(error)")
            }
            
            return call
        }
        
        guard let call: SessionCall = maybeCall else {
            dependencies[singleton: .callManager].reportFakeCall(info: "Could not retrieve call from database") // stringlint:ignore
            return
        }
        
        dependencies[singleton: .jobRunner].appDidBecomeActive()
        
        // NOTE: Just start 1-1 poller so that it won't wait for polling group messages
        (UIApplication.shared.delegate as? AppDelegate)?.startPollersIfNeeded(shouldStartGroupPollers: false)
        
        call.reportIncomingCallIfNeeded { error in
            if let error = error {
                Log.error(.calls, "Failed to report incoming call to CallKit due to error: \(error)")
            } else {
                Log.info(.calls, "Succeeded to report incoming call to CallKit")
            }
        }
    }
}

// MARK: - PushRegistrationError

public enum PushRegistrationError: Error {
    case assertionError(description: String)
    case pushNotSupported(description: String)
    case timeout
    case publisherNoLongerExists
}
