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
    
    private lazy var answerButton: UIButton = {
        let result = UIButton(type: .custom)
        result.setImage(
            UIImage(named: "AnswerCall")?
                .resized(to: CGSize(width: 24.8, height: 24.8))?
                .withRenderingMode(.alwaysTemplate),
            for: .normal
        )
        result.themeTintColor = .white
        result.themeBackgroundColor = .callAccept_background
        result.layer.cornerRadius = 24
        result.addTarget(self, action: #selector(answerCall), for: .touchUpInside)
        result.set(.width, to: 48)
        result.set(.height, to: 48)
        
        return result
    }()
    
    private lazy var hangUpButton: UIButton = {
        let result = UIButton(type: .custom)
        result.setImage(
            UIImage(named: "EndCall")?
                .resized(to: CGSize(width: 29.6, height: 11.2))?
                .withRenderingMode(.alwaysTemplate),
            for: .normal
        )
        result.themeTintColor = .white
        result.themeBackgroundColor = .callDecline_background
        result.layer.cornerRadius = 24
        result.addTarget(self, action: #selector(endCall), for: .touchUpInside)
        result.set(.width, to: 48)
        result.set(.height, to: 48)
        
        return result
    }()
    
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
            additionalProfile: nil
        )
        displayNameLabel.text = call.contactName
        
        let stackView = UIStackView(arrangedSubviews: [profilePictureView, displayNameLabel, hangUpButton, answerButton])
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = Values.largeSpacing
        self.addSubview(stackView)
        
        stackView.center(.vertical, in: self)
        stackView.set(.width, to: .width, of: self, withOffset: Values.mediumSpacing)
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
                        endCall()   // TODO: Or just put the call on hold?
                    }
                }
                else {
                    self.transform = .identity
                }
                
            default: break
        }
    }
    
    @objc private func answerCall() {
        showCallVC(answer: true)
    }
    
    @objc private func endCall() {
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
        
        guard
            dependencies.hasInitialised(singleton: .appContext),
            let presentingVC: UIViewController = dependencies[singleton: .appContext].frontmostViewController
        else { preconditionFailure() } // FIXME: Handle more gracefully
        
        let callVC = CallVC(for: self.call, using: dependencies)
        if let conversationVC = presentingVC as? ConversationVC {
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
        
        guard
            dependencies.hasInitialised(singleton: .appContext),
            let window: UIWindow = dependencies[singleton: .appContext].mainWindow
        else { return }
        
        window.addSubview(self)
        let topMargin = window.safeAreaInsets.top - Values.smallSpacing
        self.set(.width, to: .width, of: window, withOffset: Values.smallSpacing)
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
