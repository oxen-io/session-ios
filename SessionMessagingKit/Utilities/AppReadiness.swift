// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let appReadiness: SingletonConfig<AppReadiness> = Dependencies.create(
        identifier: "appReadiness",
        createInstance: { _ in AppReadiness() }
    )
}

// MARK: - AppReadiness

public class AppReadiness {
    public private(set) var isAppReady: Bool = false
    private var appWillBecomeReadyBlocks: Atomic<[() -> ()]> = Atomic([])
    private var appDidBecomeReadyBlocks: Atomic<[() -> ()]> = Atomic([])
    
    public func setAppReady() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.setAppReady() }
            return
        }
        
        // Update the flag
        isAppReady = true
        
        // Trigure the closures
        let willBecomeReadyClosures: [() -> ()] = appWillBecomeReadyBlocks.wrappedValue
        let didBecomeReadyClosures: [() -> ()] = appDidBecomeReadyBlocks.wrappedValue
        appWillBecomeReadyBlocks.mutate { $0 = [] }
        appDidBecomeReadyBlocks.mutate { $0 = [] }
        
        willBecomeReadyClosures.forEach { $0() }
        didBecomeReadyClosures.forEach { $0() }
    }
    
    public func invalidate() {
        isAppReady = false
    }
    
    public func runNowOrWhenAppWillBecomeReady(closure: @escaping () -> ()) {
        // We don't need to do any "on app ready" work in the tests.
        guard !SNUtilitiesKitConfiguration.isRunningTests else { return }
        guard !isAppReady else {
            guard Thread.isMainThread else {
                DispatchQueue.main.async { [weak self] in self?.runNowOrWhenAppWillBecomeReady(closure: closure) }
                return
            }
            
            return closure()
        }
        
        appWillBecomeReadyBlocks.mutate { $0.append(closure) }
    }
    
    public func runNowOrWhenAppDidBecomeReady(closure: @escaping () -> ()) {
        // We don't need to do any "on app ready" work in the tests.
        guard !SNUtilitiesKitConfiguration.isRunningTests else { return }
        guard !isAppReady else {
            guard Thread.isMainThread else {
                DispatchQueue.main.async { [weak self] in self?.runNowOrWhenAppDidBecomeReady(closure: closure) }
                return
            }
            
            return closure()
        }
        
        appDidBecomeReadyBlocks.mutate { $0.append(closure) }
    }
}
