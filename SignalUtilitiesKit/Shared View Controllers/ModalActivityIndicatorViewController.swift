// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import MediaPlayer
import SessionUIKit
import NVActivityIndicatorView
import SessionUtilitiesKit

// A modal view that be used during blocking interactions (e.g. waiting on response from
// service or on the completion of a long-running local operation).
public class ModalActivityIndicatorViewController: OWSViewController {
    let canCancel: Bool
    let message: String?
    private let onAppear: (ModalActivityIndicatorViewController) -> Void

    private var hasAppeared: Bool = false
    public var wasCancelled: Bool = false
    
    lazy var dimmingView: UIView = {
        let result = UIVisualEffectView()
        
        ThemeManager.onThemeChange(observer: result) { [weak result] theme, _ in
            result?.effect = UIBlurEffect(
                style: (theme.interfaceStyle == .light ?
                    UIBlurEffect.Style.systemUltraThinMaterialLight :
                    UIBlurEffect.Style.systemUltraThinMaterial
                )
            )
        }
        
        return result
    }()
    
    private lazy var stackView: UIStackView = {
        let result: UIStackView = UIStackView()
        result.axis = .vertical
        result.spacing = Values.largeSpacing
        result.alignment = .center
        
        return result
    }()
    
    private lazy var messageLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .systemFont(ofSize: Values.mediumFontSize)
        result.text = message
        result.textAlignment = .center
        result.themeTextColor = .textPrimary
        result.lineBreakMode = .byWordWrapping
        result.numberOfLines = 0
        result.isHidden = (message == nil)
        
        return result
    }()
    
    private lazy var spinner: NVActivityIndicatorView = {
        let result: NVActivityIndicatorView = NVActivityIndicatorView(
            frame: CGRect.zero,
            type: .circleStrokeSpin,
            color: .white,
            padding: nil
        )
        result.set(.width, to: 64)
        result.set(.height, to: 64)
        
        result.accessibilityIdentifier = "Loading animation"
        
        ThemeManager.onThemeChange(observer: result) { [weak result] theme, _ in
            guard let textPrimary: UIColor = theme.color(for: .textPrimary) else { return }
            
            result?.color = textPrimary
        }
        
        return result
    }()

    var wasDimissed: Bool = false

    // MARK: - Initializers

    @available(*, unavailable, message:"use other constructor instead.")
    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public required init(
        canCancel: Bool = false,
        message: String? = nil,
        onAppear: @escaping (ModalActivityIndicatorViewController) -> Void
    ) {
        self.canCancel = canCancel
        self.message = message
        self.onAppear = onAppear
        
        super.init(nibName: nil, bundle: nil)
        
        // Present this modal _over_ the current view contents.
        self.modalPresentationStyle = .overFullScreen
        self.modalTransitionStyle = .crossDissolve
    }

    public class func present(
        fromViewController: UIViewController?,
        canCancel: Bool = false,
        message: String? = nil,
        onAppear: @escaping (ModalActivityIndicatorViewController) -> Void
    ) {
        guard let fromViewController: UIViewController = fromViewController else { return }
        
        Log.assertOnMainThread()
        
        fromViewController.present(
            ModalActivityIndicatorViewController(canCancel: canCancel, message: message, onAppear: onAppear),
            animated: false
        )
    }

    public func dismiss(completion: @escaping () -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.dismiss(completion: completion)
            }
            return
        }

        if !wasDimissed {
            // Only dismiss once.
            self.dismiss(animated: false, completion: completion)
            wasDimissed = true
        }
        else {
            // If already dismissed, wait a beat then call completion.
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    public override func loadView() {
        super.loadView()

        self.view.themeBackgroundColor = .clear
        
        self.view.addSubview(dimmingView)
        self.view.addSubview(stackView)
        dimmingView.pin(to: self.view)
        stackView.center(in: self.view)
        
        stackView.addArrangedSubview(spinner)
        stackView.addArrangedSubview(messageLabel)
        
        messageLabel.set(.width, to: .width, of: stackView, withOffset: -(2 * Values.mediumSpacing))
        
        if canCancel {
            let cancelButton: SessionButton = SessionButton(style: .destructive, size: .large)
            cancelButton.setTitle("cancel".localized(), for: .normal)
            cancelButton.addTarget(self, action: #selector(cancelPressed), for: .touchUpInside)
            self.view.addSubview(cancelButton)
            
            cancelButton.center(.horizontal, in: self.view)
            cancelButton.pin(.bottom, to: .bottom, of: self.view, withInset: -50)
            cancelButton.set(.width, to: Values.iPadButtonWidth)
        }

        // Hide the modal until the presentation animation completes.
        self.view.layer.opacity = 0.0
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        self.spinner.startAnimating()

        // Fade in the modal
        UIView.animate(withDuration: 0.35) {
            self.view.layer.opacity = 1.0
        }
    }
    
    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        if !self.hasAppeared {
            self.hasAppeared = true
            
            DispatchQueue.global().async {
                self.onAppear(self)
            }
        }
    }

    @objc func cancelPressed() {
        Log.assertOnMainThread()

        wasCancelled = true

        dismiss { }
    }
    
    public func setMessage(_ message: String?) {
        messageLabel.text = message
        messageLabel.isHidden = (message == nil)
    }
}
