// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionSnodeKit

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
        super.init(frame: CGRect.zero)
        
        self.addSubview(iconImageView)
        iconImageView.pin(to: self, withInset: 1)
    }
    
    override init(frame: CGRect) {
        preconditionFailure("Use init(viewItem:textColor:) instead.")
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(viewItem:textColor:) instead.")
    }
    
    public func configure(expirationTimestampMs: Double, initialDurationSeconds: Double) {
        self.expirationTimestampMs = expirationTimestampMs
        self.initialDurationSeconds = initialDurationSeconds
        
        self.updateProgress()
        self.startAnimation()
    }
    
    @objc private func updateProgress() {
        guard self.expirationTimestampMs > 0 else {
            self.progress = 12
            return
        }
        
        let timestampMs: Double = Double(SnodeAPI.currentOffsetTimestampMs())
        let secondsLeft: Double = max((self.expirationTimestampMs - timestampMs) / 1000, 0)
        let progressRatio: Double = self.initialDurationSeconds > 0 ? secondsLeft / self.initialDurationSeconds : 0
        
        self.progress = Int(round(min(progressRatio, 1) * 12))
        self.updateIcon()
    }
    
    private func updateIcon() {
        let imageName: String = "disappearing_message_\(String(format: "%02d", 5 * self.progress))"
        self.iconImageView.image = UIImage(named: imageName)?.withRenderingMode(.alwaysTemplate)
    }
    
    private func startAnimation() {
        self.clearAnimation()
        self.animationTimer = Timer.scheduledTimerOnMainThread(
            withTimeInterval: 0.1,
            repeats: true
        ) { [weak self] _ in self?.updateProgress() }
    }
    
    private func clearAnimation() {
        self.animationTimer?.invalidate()
        self.animationTimer = nil
    }
    
    public func prepareForReuse() {
        self.clearAnimation()
    }
}
