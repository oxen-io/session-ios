// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit

open class OWSViewController: UIViewController {
    public var shouldUseTheme: Bool = true
    public var shouldIgnoreKeyboardChanges: Bool = false
    public var shouldAnimateBottomLayout: Bool = false
    
    /// If `true`, the bottom view never "reclaims" layout space if the keyboard is dismissed.
    /// Defaults to `false`.
    public var shouldBottomViewReserveSpaceForKeyboard: Bool = false
    
    private weak var bottomLayoutView: UIView?
    private var bottomLayoutConstraint: NSLayoutConstraint?
    
    open override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return (UIDevice.current.isIPad ? .all : .portrait)
    }
    
    // MARK: - Initialization
    
    public override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nil, bundle: nil)
        
        self.observeActivation()
    }
    
    required public init?(coder: NSCoder) {
        super.init(coder: coder)
        
        self.observeActivation()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Lifecycle
    
    open override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        self.shouldAnimateBottomLayout = true
    }
    
    open override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        self.shouldAnimateBottomLayout = false
    }
    
    // MARK: - Functions
    
    public func pinViewToBottomOfViewControllerOrKeyboard(_ view: UIView, avoidNotch: Bool) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidShow(_:)),
            name: UIResponder.keyboardDidShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidHide(_:)),
            name: UIResponder.keyboardDidHideNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidChangeFrame(_:)),
            name: UIResponder.keyboardDidChangeFrameNotification,
            object: nil
        )

        self.bottomLayoutView = view
        self.bottomLayoutConstraint = view.pin(
            .bottom,
            to: .bottom,
            of: (avoidNotch ? view.safeAreaLayoutGuide : view)
        )
    }
    
    // MARK: - Observations
    
    private func observeActivation() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive(_:)),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }
    
    @objc private func appDidBecomeActive(_ notification: NSNotification) {
        self.setNeedsStatusBarAppearanceUpdate()
    }
    
    @objc private func keyboardWillShow(_ notification: NSNotification) {
        self.handleKeyboardNotificationBase(notification)
    }
    
    @objc private func keyboardDidShow(_ notification: NSNotification) {
        self.handleKeyboardNotificationBase(notification)
    }
    
    @objc private func keyboardWillHide(_ notification: NSNotification) {
        self.handleKeyboardNotificationBase(notification)
    }
    
    @objc private func keyboardDidHide(_ notification: NSNotification) {
        self.handleKeyboardNotificationBase(notification)
    }
    
    @objc private func keyboardWillChangeFrame(_ notification: NSNotification) {
        self.handleKeyboardNotificationBase(notification)
    }
    
    @objc private func keyboardDidChangeFrame(_ notification: NSNotification) {
        self.handleKeyboardNotificationBase(notification)
    }

    // We use the name `handleKeyboardNotificationBase` instead of
    // `handleKeyboardNotification` to avoid accidentally
    // calling similarly methods with that name in subclasses,
    // e.g. ConversationViewController.
    private func handleKeyboardNotificationBase(_ notification: NSNotification) {
        guard !shouldIgnoreKeyboardChanges else { return }
        
        let userInfo: [AnyHashable: Any] = (notification.userInfo ?? [:])
        let keyboardRect: CGRect = ((userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? CGRect.zero)
        let convertedKeyboardRect: CGRect = view.convert(keyboardRect, from: nil)
        
        /// Adjust the position of the bottom view to account for the keyboard's intrusion into the view.
        ///
        /// On iPhoneX, when no keyboard is present, we include a buffer at the bottom of the screen so the bottom view clears the
        /// floating "home button". But because the keyboard includes it's own buffer, we subtract the length (height) of the bottomLayoutGuide,
        /// else we'd have an unnecessary buffer between the popped keyboard and the input bar.
        let offset: CGFloat = -max(0, (self.view.bounds.height - (self.view.window?.safeAreaInsets.bottom ?? 0) - convertedKeyboardRect.minY))
        let updateLayout: () -> () = { [weak self] in
            guard self?.shouldBottomViewReserveSpaceForKeyboard == false || offset < 0 else {
                /// To avoid unnecessary animations / layout jitter, some views never reclaim layout space when the keyboard is dismissed.
                ///
                /// They _do_ need to relayout if the user switches keyboards.
                return
            }
            
            self?.bottomLayoutConstraint?.constant = offset
            self?.bottomLayoutView?.superview?.layoutIfNeeded()
        }
        
        /// UIKit by default animates all changes in response to keyboard events.
        /// We want to suppress those animations if the view isn't visible, otherwise presentation animations don't work properly.
        guard shouldAnimateBottomLayout else {
            return UIView.performWithoutAnimation {
                updateLayout()
            }
        }
        
        updateLayout()
    }
}
