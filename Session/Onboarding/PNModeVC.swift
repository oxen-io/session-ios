// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import SessionUIKit
import SessionMessagingKit
import SessionSnodeKit
import SignalUtilitiesKit
import SessionUtilitiesKit

final class PNModeVC: BaseVC, OptionViewDelegate {
    private let flow: Onboarding.Flow
    
    private var optionViews: [OptionView] {
        [ apnsOptionView, backgroundPollingOptionView ]
    }

    private var selectedOptionView: OptionView? {
        return optionViews.first { $0.isSelected }
    }
    
    // MARK: - Initialization
    
    init(flow: Onboarding.Flow) {
        self.flow = flow
        
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
    
    private func register(using dependencies: Dependencies = Dependencies()) {
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
        
        let useAPNS: Bool = (selectedOptionView == apnsOptionView)
        dependencies[defaults: .standard, key: .isUsingFullAPNs] = useAPNS
        
        // If we are registering then we can just continue on
        guard flow != .register else {
            return self.completeRegistration(useAPNS: useAPNS)
        }
        
        // Check if we already have a profile name (ie. profile retrieval completed while waiting on
        // this screen)
        let existingProfileName: String? = dependencies[singleton: .storage].read { [dependencies] db in
            try Profile
                .filter(id: getUserSessionId(db, using: dependencies).hexString)
                .select(.name)
                .asRequest(of: String.self)
                .fetchOne(db)
        }
        
        guard existingProfileName?.isEmpty != false else {
            // If we have one then we can go straight to the home screen
            return self.completeRegistration(useAPNS: useAPNS)
        }
        
        // If we don't have one then show a loading indicator and try to retrieve the existing name
        ModalActivityIndicatorViewController.present(fromViewController: self) { [weak self, flow = self.flow] viewController in
            Onboarding.profileNamePublisher
                .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                .timeout(.seconds(15), scheduler: DispatchQueue.main, customError: { HTTPError.timeout })
                .catch { _ -> AnyPublisher<String?, Error> in
                    SNLog("Onboarding failed to retrieve existing profile information")
                    return Just(nil)
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                .receive(on: DispatchQueue.main)
                .sinkUntilComplete(
                    receiveValue: { value in
                        // Hide the loading indicator
                        viewController.dismiss(animated: true)
                        
                        // If we have no display name we need to collect one
                        guard value?.isEmpty == false else {
                            let displayNameVC: DisplayNameVC = DisplayNameVC(flow: flow)
                            self?.navigationController?.pushViewController(displayNameVC, animated: true)
                            return
                        }
                        
                        // Otherwise we are done and can go to the home screen
                        self?.completeRegistration(useAPNS: useAPNS)
                    }
                )
        }
    }
    
    private func completeRegistration(useAPNS: Bool) {
        self.flow.completeRegistration()
        
        // Trigger the 'SyncPushTokensJob' directly as we don't want to wait for paths to build
        // before requesting the permission from the user
        if useAPNS { SyncPushTokensJob.run(uploadOnlyIfStale: false) }
        
        // Go to the home screen
        let homeVC: HomeVC = HomeVC()
        self.navigationController?.setViewControllers([ homeVC ], animated: true)
    }
}
