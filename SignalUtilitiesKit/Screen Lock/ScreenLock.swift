// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import LocalAuthentication
import SessionMessagingKit
import SessionUtilitiesKit

// MARK: - Log.Category

public extension Log.Category {
    static let screenLock: Log.Category = .create("ScreenLock", defaultLevel: .info)
}

// MARK: - ScreenLock

public class ScreenLock {
    public enum ScreenLockError: Error {
        case general(description: String)
    }
    
    public enum Outcome {
        case success
        case cancel
        case failure(error: String)
        case unexpectedFailure(error: String)
    }

    public let screenLockTimeoutDefault = (15 * 60)
    public let screenLockTimeouts = [
        1 * 60,
        5 * 60,
        15 * 60,
        30 * 60,
        1 * 60 * 60,
        0
    ]
    
    public static let shared: ScreenLock = ScreenLock()

    // MARK: - Methods

    /// This method should only be called:
    ///
    /// * On the main thread.
    ///
    /// Exactly one of these completions will be performed:
    ///
    /// * Asynchronously.
    /// * On the main thread.
    public func tryToUnlockScreenLock(
        success: @escaping (() -> Void),
        failure: @escaping ((Error) -> Void),
        unexpectedFailure: @escaping ((Error) -> Void),
        cancel: @escaping (() -> Void)
    ) {
        Log.assertOnMainThread()

        tryToVerifyLocalAuthentication(
            // Description of how and why Signal iOS uses Touch ID/Face ID/Phone Passcode to
            // unlock 'screen lock'.
            localizedReason: "authenticateToOpen"
                .put(key: "app_name", value:  Constants.app_name)
                .localized()
        ) { outcome in
            Log.assertOnMainThread()
            
            switch outcome {
                case .failure(let error):
                    Log.error(.screenLock, "Local authentication failed with error: \(error)")
                    failure(ScreenLockError.general(description: error))
                
                case .unexpectedFailure(let error):
                    Log.error(.screenLock, "Local authentication failed with unexpected error: \(error)")
                    unexpectedFailure(ScreenLockError.general(description: error))
                
                case .success:
                    Log.verbose(.screenLock, "Local authentication succeeded.")
                    success()
                
                case .cancel:
                    Log.verbose(.screenLock, "Local authentication cancelled.")
                    cancel()
            }
        }
    }

    /// This method should only be called:
    ///
    /// * On the main thread.
    ///
    /// completionParam will be performed:
    ///
    /// * Asynchronously.
    /// * On the main thread.
    private func tryToVerifyLocalAuthentication(
        localizedReason: String,
        completion completionParam: @escaping ((Outcome) -> Void)
    ) {
        Log.assertOnMainThread()

        let defaultErrorDescription = "authenticateNotAccessed".localized()

        // Ensure completion is always called on the main thread.
        let completion = { outcome in
            DispatchQueue.main.async {
                completionParam(outcome)
            }
        }

        let context = screenLockContext()

        var authError: NSError?
        let canEvaluatePolicy = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError)
        
        if !canEvaluatePolicy || authError != nil {
            Log.error(.screenLock, "Could not determine if local authentication is supported: \(String(describing: authError))")

            let outcome = self.outcomeForLAError(errorParam: authError,
                                                 defaultErrorDescription: defaultErrorDescription)
            switch outcome {
                case .success:
                    Log.error(.screenLock, "Local authentication unexpected success")
                    completion(.failure(error: defaultErrorDescription))
                    
                case .cancel, .failure, .unexpectedFailure:
                    completion(outcome)
                }
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: localizedReason) { success, evaluateError in

            if success {
                Log.info(.screenLock, "Local authentication succeeded.")
                completion(.success)
                return
            }
            
            let outcome = self.outcomeForLAError(
                errorParam: evaluateError,
                defaultErrorDescription: defaultErrorDescription
            )
            
            switch outcome {
                case .success:
                    Log.error(.screenLock, "Local authentication unexpected success")
                    completion(.failure(error: defaultErrorDescription))
                    
                case .cancel, .failure, .unexpectedFailure:
                    completion(outcome)
            }
        }
    }

    // MARK: - Outcome

    private func outcomeForLAError(errorParam: Error?, defaultErrorDescription: String) -> Outcome {
        if let error = errorParam {
            guard let laError = error as? LAError else {
                return .failure(error: defaultErrorDescription)
            }

            switch laError.code {
                case .biometryNotAvailable:
                    Log.error(.screenLock, "Local authentication error: biometryNotAvailable.")
                    return .failure(error: "lockAppEnablePasscode".localized())
                    
                case .biometryNotEnrolled:
                    Log.error(.screenLock, "Local authentication error: biometryNotEnrolled.")
                    return .failure(error: "lockAppEnablePasscode".localized())
                    
                case .biometryLockout:
                    Log.error(.screenLock, "Local authentication error: biometryLockout.")
                    return .failure(error: "authenticateFailedTooManyAttempts".localized())
                    
                default:
                    // Fall through to second switch
                    break
            }

            switch laError.code {
                case .authenticationFailed:
                    Log.error(.screenLock, "Local authentication error: authenticationFailed.")
                    return .failure(error: "authenticateFailed".localized())
                    
                case .userCancel, .userFallback, .systemCancel, .appCancel:
                    Log.info(.screenLock, "Local authentication cancelled.")
                    return .cancel
                    
                case .passcodeNotSet:
                    Log.error(.screenLock, "Local authentication error: passcodeNotSet.")
                    return .failure(error: "lockAppEnablePasscode".localized())
                    
                case .touchIDNotAvailable:
                    Log.error(.screenLock, "Local authentication error: touchIDNotAvailable.")
                    return .failure(error: "lockAppEnablePasscode".localized())
                    
                case .touchIDNotEnrolled:
                    Log.error(.screenLock, "Local authentication error: touchIDNotEnrolled.")
                    return .failure(error: "lockAppEnablePasscode".localized())
                    
                case .touchIDLockout:
                    Log.error(.screenLock, "Local authentication error: touchIDLockout.")
                    return .failure(error: "authenticateFailedTooManyAttempts".localized())
                    
                case .invalidContext:
                    Log.error(.screenLock, "Context not valid.")
                    return .unexpectedFailure(error: defaultErrorDescription)
                    
                case .notInteractive:
                    Log.error(.screenLock, "Context not interactive.")
                    return .unexpectedFailure(error: defaultErrorDescription)
                
                @unknown default:
                    return .failure(error: defaultErrorDescription)
            }
        }
        
        return .failure(error: defaultErrorDescription)
    }

    // MARK: - Context

    private func screenLockContext() -> LAContext {
        let context = LAContext()

        // Never recycle biometric auth.
        context.touchIDAuthenticationAllowableReuseDuration = TimeInterval(0)
        assert(!context.interactionNotAllowed)

        return context
    }
}
