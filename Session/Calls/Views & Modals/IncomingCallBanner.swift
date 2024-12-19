// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SignalUtilitiesKit
import SessionUtilitiesKit

final class IncomingCallBanner: UIView, UIGestureRecognizerDelegate {
    private static let swipeToOperateThreshold: CGFloat = 60
    private var previousY: CGFloat = 0
    
    private let dependencies: Dependencies
    let call: SessionCall
    
    // MARK: - UI Components
    
    private lazy var backgroundView: UIView = {
        let result: UIView = UIView()
        result.themeBackgroundColor = .black
        result.alpha = 0.8
        
        return result
    }()
    
    private lazy var profilePictureView: ProfilePictureView = ProfilePictureView(size: .list)
    
    private lazy var displayNameLabel: UILabel = {
        let result = UILabel()
        result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        result.themeTextColor = .white
        result.lineBreakMode = .byTruncatingTail
        
        return result
    }()
    
    private lazy var answerButton: UIButton = UIButton(primaryAction: UIAction { [weak self] _ in self?.answerCall() })
        .withConfiguration(
            UIButton.Configuration
                .plain()
                .withImage(UIImage(named: "AnswerCall")?.withRenderingMode(.alwaysTemplate))
                .withContentInsets(NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
        )
        .withConfigurationUpdateHandler { button in
            switch button.state {
                case .highlighted: button.imageView?.tintAdjustmentMode = .dimmed
                default: button.imageView?.tintAdjustmentMode = .normal
            }
        }
        .withImageViewContentMode(.scaleAspectFit)
        .withThemeTintColor(.white)
        .withThemeBackgroundColor(.callAccept_background)
        .withAccessibility(
            identifier: "Close button",
            label: "Close button"
        )
        .withCornerRadius(24)
        .with(.width, of: 48)
        .with(.height, of: 48)
    
    private lazy var hangUpButton: UIButton = UIButton(primaryAction: UIAction { [weak self] _ in self?.endCall() })
        .withConfiguration(
            UIButton.Configuration
                .plain()
                .withImage(UIImage(named: "EndCall")?.withRenderingMode(.alwaysTemplate))
                .withContentInsets(NSDirectionalEdgeInsets(top: 13, leading: 9, bottom: 13, trailing: 9))
        )
        .withConfigurationUpdateHandler { button in
            switch button.state {
                case .highlighted: button.imageView?.tintAdjustmentMode = .dimmed
                default: button.imageView?.tintAdjustmentMode = .normal
            }
        }
        .withImageViewContentMode(.scaleAspectFit)
        .withThemeTintColor(.white)
        .withThemeBackgroundColor(.callDecline_background)
        .withAccessibility(
            identifier: "Close button",
            label: "Close button"
        )
        .withCornerRadius(24)
        .with(.width, of: 48)
        .with(.height, of: 48)
    
    private lazy var panGestureRecognizer: UIPanGestureRecognizer = {
        let result = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        result.delegate = self
        
        return result
    }()
    
    // MARK: - Initialization
    
    public static var current: IncomingCallBanner?
    
    init(for call: SessionCall, using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.call = call
        
        super.init(frame: CGRect.zero)
        
        setUpViewHierarchy()
        setUpGestureRecognizers()
        
        if let incomingCallBanner = IncomingCallBanner.current {
            incomingCallBanner.dismiss()
        }
        
        IncomingCallBanner.current = self
    }
    
    override init(frame: CGRect) {
        preconditionFailure("Use init(message:) instead.")
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(coder:) instead.")
    }
    
    private func setUpViewHierarchy() {
        self.clipsToBounds = true
        self.layer.cornerRadius = Values.largeSpacing
        self.set(.height, to: 100)
        
        addSubview(backgroundView)
        backgroundView.pin(to: self)
        
        profilePictureView.update(
            publicKey: call.sessionId,
            threadVariant: .contact,
            displayPictureFilename: nil,
            profile: dependencies[singleton: .storage].read { [sessionId = call.sessionId] db in
                Profile.fetchOrCreate(db, id: sessionId)
            },
            additionalProfile: nil,
            using: dependencies
        )
        displayNameLabel.text = call.contactName
        
        let stackView = UIStackView(arrangedSubviews: [profilePictureView, displayNameLabel, hangUpButton, answerButton])
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = Values.largeSpacing
        self.addSubview(stackView)
        
        stackView.center(.vertical, in: self)
        stackView.pin(.leading, to: .leading, of: self, withInset: Values.mediumSpacing)
        stackView.pin(.trailing, to: .trailing, of: self, withInset: -Values.mediumSpacing)
    }
    
    private func setUpGestureRecognizers() {
        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tapGestureRecognizer.numberOfTapsRequired = 1
        addGestureRecognizer(tapGestureRecognizer)
        addGestureRecognizer(panGestureRecognizer)
    }
    
    // MARK: - Interaction
    
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer == panGestureRecognizer {
            let v = panGestureRecognizer.velocity(in: self)
            
            return abs(v.y) > abs(v.x) // It has to be more vertical than horizontal
        }
        
        return true
    }
    
    @objc private func handleTap(_ gestureRecognizer: UITapGestureRecognizer) {
        showCallVC(answer: false)
    }
    
    @objc private func handlePan(_ gestureRecognizer: UIPanGestureRecognizer) {
        let translationY = gestureRecognizer.translation(in: self).y
        switch gestureRecognizer.state {
            case .changed:
                self.transform = CGAffineTransform(translationX: 0, y: min(translationY, IncomingCallBanner.swipeToOperateThreshold))
                if abs(translationY) > IncomingCallBanner.swipeToOperateThreshold && abs(previousY) < IncomingCallBanner.swipeToOperateThreshold {
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred() // Let the user know when they've hit the swipe to reply threshold
                }
                previousY = translationY
                
            case .ended, .cancelled:
                if abs(translationY) > IncomingCallBanner.swipeToOperateThreshold {
                    if translationY > 0 {
                        showCallVC(answer: false)
                    }
                    else {
                        endCall()   // TODO: [CALLS] Or just put the call on hold?
                    }
                }
                else {
                    self.transform = .identity
                }
                
            default: break
        }
    }
    
    private func answerCall() {
        showCallVC(answer: true)
    }
    
    private func endCall() {
        dependencies[singleton: .callManager].endCall(call) { [weak self, dependencies] error in
            if let _ = error {
                self?.call.endSessionCall()
                dependencies[singleton: .callManager].reportCurrentCallEnded(reason: nil)
            }
            
            self?.dismiss()
        }
    }
    
    public func showCallVC(answer: Bool) {
        dismiss()
        guard let presentingVC: UIViewController = dependencies[singleton: .appContext].frontMostViewController else {
            Log.critical(.calls, "Failed to retrieve front view controller when showing the call UI")
            return endCall()
        }
        
        let callVC = CallVC(for: self.call, using: dependencies)
        if let conversationVC = (presentingVC as? TopBannerController)?.wrappedViewController() as? ConversationVC {
            callVC.conversationVC = conversationVC
            conversationVC.inputAccessoryView?.isHidden = true
            conversationVC.inputAccessoryView?.alpha = 0
        }
        
        presentingVC.present(callVC, animated: true) { [weak self] in
            guard answer else { return }
            
            self?.call.answerSessionCall()
        }
    }
    
    public func show() {
        self.alpha = 0.0
        
        guard let window: UIWindow = dependencies[singleton: .appContext].mainWindow else { return }

        window.addSubview(self)
        
        let topMargin = window.safeAreaInsets.top - Values.smallSpacing
        self.set(.width, to: .width, of: window, withOffset: -Values.smallSpacing)
        self.pin(.top, to: .top, of: window, withInset: topMargin)
        
        UIView.animate(withDuration: 0.5, delay: 0, options: [], animations: {
            self.alpha = 1.0
        }, completion: nil)
        
        CallRingTonePlayer.shared.startVibration()
        CallRingTonePlayer.shared.startPlayingRingTone()
    }
    
    public func dismiss() {
        CallRingTonePlayer.shared.stopVibrationIfPossible()
        CallRingTonePlayer.shared.stopPlayingRingTone()
        
        UIView.animate(withDuration: 0.5, delay: 0, options: [], animations: {
            self.alpha = 0.0
        }, completion: { _ in
            IncomingCallBanner.current = nil
            self.removeFromSuperview()
        })
    }
}
