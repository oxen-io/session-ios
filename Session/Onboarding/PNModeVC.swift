// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import SessionUIKit
import SessionMessagingKit
import SessionSnodeKit
import SignalUtilitiesKit
import SessionUtilitiesKit

final class PNModeVC: BaseVC, OptionViewDelegate {
    private let dependencies: Dependencies
    private var profileRetrievalCancellable: AnyCancellable?
    
    private var optionViews: [OptionView] {
        [ apnsOptionView, backgroundPollingOptionView ]
    }

    private var selectedOptionView: OptionView? {
        return optionViews.first { $0.isSelected }
    }
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        profileRetrievalCancellable?.cancel()
    }
    
    // MARK: - Components
    
    private lazy var apnsOptionView: OptionView = {
        let result: OptionView = OptionView(
            title: "fast_mode".localized(),
            explanation: "fast_mode_explanation".localized(),
            delegate: self,
            isRecommended: true
        )
        result.accessibilityLabel = "Fast mode option"
        
        return result
    }()
    
    private lazy var backgroundPollingOptionView: OptionView = {
        let result: OptionView = OptionView(
            title: "slow_mode".localized(),
            explanation: "slow_mode_explanation".localized(),
            delegate: self
        )
        result.accessibilityLabel = "Slow mode option"
        
        return result
    }()

    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setUpNavBarSessionIcon()
        
        let learnMoreButton = UIBarButtonItem(image: #imageLiteral(resourceName: "ic_info"), style: .plain, target: self, action: #selector(learnMore))
        learnMoreButton.themeTintColor = .textPrimary
        navigationItem.rightBarButtonItem = learnMoreButton
        
        // Set up title label
        let titleLabel = UILabel()
        titleLabel.font = .boldSystemFont(ofSize: isIPhone5OrSmaller ? Values.largeFontSize : Values.veryLargeFontSize)
        titleLabel.text = "vc_pn_mode_title".localized()
        titleLabel.themeTextColor = .textPrimary
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.numberOfLines = 0
        
        // Set up spacers
        let topSpacer = UIView.vStretchingSpacer()
        let bottomSpacer = UIView.vStretchingSpacer()
        let registerButtonBottomOffsetSpacer = UIView()
        registerButtonBottomOffsetSpacer.set(.height, to: Values.onboardingButtonBottomOffset)
        
        // Set up register button
        let registerButton = SessionButton(style: .filled, size: .large)
        registerButton.accessibilityLabel = "Continue with settings"
        registerButton.setTitle("continue_2".localized(), for: .normal)
        registerButton.addTarget(self, action: #selector(registerTapped), for: UIControl.Event.touchUpInside)
        
        // Set up register button container
        let registerButtonContainer = UIView(wrapping: registerButton, withInsets: UIEdgeInsets(top: 0, leading: Values.massiveSpacing, bottom: 0, trailing: Values.massiveSpacing), shouldAdaptForIPadWithWidth: Values.iPadButtonWidth)
        
        // Set up options stack view
        let optionsStackView = UIStackView(arrangedSubviews: optionViews)
        optionsStackView.axis = .vertical
        optionsStackView.spacing = Values.smallSpacing
        optionsStackView.alignment = .fill
        
        // Set up top stack view
        let topStackView = UIStackView(arrangedSubviews: [ titleLabel, UIView.spacer(withHeight: isIPhone6OrSmaller ? Values.mediumSpacing : Values.veryLargeSpacing), optionsStackView ])
        topStackView.axis = .vertical
        topStackView.alignment = .fill
        
        // Set up top stack view container
        let topStackViewContainer = UIView(wrapping: topStackView, withInsets: UIEdgeInsets(top: 0, leading: Values.veryLargeSpacing, bottom: 0, trailing: Values.veryLargeSpacing))
        
        // Set up main stack view
        let mainStackView = UIStackView(arrangedSubviews: [ topSpacer, topStackViewContainer, bottomSpacer, registerButtonContainer, registerButtonBottomOffsetSpacer ])
        mainStackView.axis = .vertical
        mainStackView.alignment = .fill
        view.addSubview(mainStackView)
        mainStackView.pin(to: view)
        topSpacer.heightAnchor.constraint(equalTo: bottomSpacer.heightAnchor, multiplier: 1).isActive = true
        
        // Preselect APNs mode
        optionViews[0].isSelected = true
    }

    // MARK: - Interaction
    
    @objc private func learnMore() {
        guard let url: URL = URL(string: "https://getsession.org/faq/#privacy") else { return }
        
        UIApplication.shared.open(url)
    }

    func optionViewDidActivate(_ optionView: OptionView) {
        optionViews.filter { $0 != optionView }.forEach { $0.isSelected = false }
    }

    @objc private func registerTapped() { register() }
    
    private func register() {
        guard selectedOptionView != nil else {
            let modal: ConfirmationModal = ConfirmationModal(
                targetView: self.view,
                info: ConfirmationModal.Info(
                    title: "vc_pn_mode_no_option_picked_modal_title".localized(),
                    cancelTitle: "BUTTON_OK".localized(),
                    cancelStyle: .alert_text
                )
            )
            self.present(modal, animated: true)
            return
        }
        
        // Store whether we want to use APNS
        dependencies.mutate(cache: .onboarding) { $0.setUserAPNS(selectedOptionView == apnsOptionView) }
        
        // If we are registering then we can just continue on
        guard dependencies[cache: .onboarding].initialFlow != .register else {
            return self.completeRegistration()
        }
        
        // Check if we already have a profile name (ie. profile retrieval completed while waiting on
        // this screen)
        guard dependencies[cache: .onboarding].displayName.isEmpty else {
            // If we have one then we can go straight to the home screen
            return self.completeRegistration()
        }
        
        // If we don't have one then show a loading indicator and try to retrieve the existing name
        ModalActivityIndicatorViewController.present(fromViewController: self) { [weak self, dependencies] viewController in
            self?.profileRetrievalCancellable = dependencies[cache: .onboarding].displayNamePublisher
                .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                .timeout(.seconds(15), scheduler: DispatchQueue.main, customError: { NetworkError.timeout })
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { _ in },
                    receiveValue: { value in
                        // Hide the loading indicator
                        viewController.dismiss(animated: true)
                        
                        // If we have no display name we need to collect one
                        guard value?.isEmpty == false else {
                            let displayNameVC: DisplayNameVC = DisplayNameVC(using: dependencies)
                            self?.navigationController?.pushViewController(displayNameVC, animated: true)
                            return
                        }
                        
                        // Otherwise we are done and can go to the home screen
                        self?.completeRegistration()
                    }
                )
        }
    }
    
    private func completeRegistration() {
        dependencies.mutate(cache: .onboarding) { [weak self, dependencies] onboarding in
            let shouldSyncPushTokens: Bool = onboarding.useAPNS
            
            onboarding.completeRegistration {
                // Trigger the 'SyncPushTokensJob' directly as we don't want to wait for paths to build
                // before requesting the permission from the user
                if shouldSyncPushTokens { SyncPushTokensJob.run(uploadOnlyIfStale: false, using: dependencies) }
                
                // Go to the home screen
                let homeVC: HomeVC = HomeVC(using: dependencies)
                dependencies[singleton: .app].setHomeViewController(homeVC)
                self?.navigationController?.setViewControllers([ homeVC ], animated: true)
            }
        }
    }
}
