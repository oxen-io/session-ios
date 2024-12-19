// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionSnodeKit
import SessionUtilitiesKit

class DisappearingMessageTimerView: UIView {
    private var initialDurationSeconds: Double = 0
    private var expirationTimestampMs: Double = 0
    
    // MARK: - Animation
    private var animationTimer: Timer?
    private var progress: Int = 12 // 0 == about to expire, 12 == just started countdown.
    
    // MARK: - UI
    private var iconImageView = UIImageView()
    
    // MARK: - Lifecycle
    
    init() {
        super.init(frame: .zero)
        
        self.addSubview(iconImageView)
        iconImageView.pin(to: self, withInset: 1)
    }
    
    override init(frame: CGRect) {
        preconditionFailure("Use init() instead.")
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init() instead.")
    }
    
    public func configure(expirationTimestampMs: Double, initialDurationSeconds: Double, using dependencies: Dependencies) {
        self.expirationTimestampMs = expirationTimestampMs
        self.initialDurationSeconds = initialDurationSeconds
        
        self.updateProgress(using: dependencies)
        self.startAnimation(using: dependencies)
    }
    
    private func updateProgress(using dependencies: Dependencies) {
        guard self.expirationTimestampMs > 0 else {
            self.progress = 12
            return
        }
        
        let timestampMs: Double = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        let secondsLeft: Double = max((self.expirationTimestampMs - timestampMs) / 1000, 0)
        let progressRatio: Double = self.initialDurationSeconds > 0 ? secondsLeft / self.initialDurationSeconds : 0
        
        self.progress = Int(round(min(progressRatio, 1) * 12))
        self.updateIcon()
    }
    
    // stringlint:ignore_contents
    private func updateIcon() {
        let imageName: String = "disappearing_message_\(String(format: "%02d", 5 * self.progress))"
        self.iconImageView.image = UIImage(named: imageName)?.withRenderingMode(.alwaysTemplate)
    }
    
    private func startAnimation(using dependencies: Dependencies) {
        self.clearAnimation()
        self.animationTimer = Timer.scheduledTimerOnMainThread(
            withTimeInterval: 0.1,
            repeats: true,
            using: dependencies
        ) { [weak self] _ in self?.updateProgress(using: dependencies) }
    }
    
    private func clearAnimation() {
        self.animationTimer?.invalidate()
        self.animationTimer = nil
    }
    
    public func prepareForReuse() {
        self.clearAnimation()
    }
}
