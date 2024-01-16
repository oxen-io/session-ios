// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import GRDB
import SessionUIKit
import SessionSnodeKit
import SessionMessagingKit
import SignalUtilitiesKit
import SessionUtilitiesKit

final class NukeDataModal: Modal {
    // MARK: - Initialization
    
    override init(targetView: UIView? = nil, dismissType: DismissType = .recursive, afterClosed: (() -> ())? = nil) {
        super.init(targetView: targetView, dismissType: dismissType, afterClosed: afterClosed)
        
        self.modalPresentationStyle = .overFullScreen
        self.modalTransitionStyle = .crossDissolve
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Components
    
    private lazy var titleLabel: UILabel = {
        let result = UILabel()
        result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        result.text = "modal_clear_all_data_title".localized()
        result.themeTextColor = .textPrimary
        result.textAlignment = .center
        result.lineBreakMode = .byWordWrapping
        result.numberOfLines = 0
        
        return result
    }()
    
    private lazy var explanationLabel: UILabel = {
        let result = UILabel()
        result.font = .systemFont(ofSize: Values.smallFontSize)
        result.text = "modal_clear_all_data_explanation".localized()
        result.themeTextColor = .textPrimary
        result.textAlignment = .center
        result.lineBreakMode = .byWordWrapping
        result.numberOfLines = 0
        
        return result
    }()
    
    private lazy var clearDeviceRadio: RadioButton = {
        let result: RadioButton = RadioButton(size: .small) { [weak self] radio in
            self?.clearNetworkRadio.update(isSelected: false)
            radio.update(isSelected: true)
        }
        result.font = .systemFont(ofSize: Values.smallFontSize)
        result.text = "modal_clear_all_data_device_only_button_title".localized()
        result.update(isSelected: true)
        
        return result
    }()
    
    private lazy var clearNetworkRadio: RadioButton = {
        let result: RadioButton = RadioButton(size: .small) { [weak self] radio in
            self?.clearDeviceRadio.update(isSelected: false)
            radio.update(isSelected: true)
        }
        result.font = .systemFont(ofSize: Values.smallFontSize)
        result.text = "modal_clear_all_data_entire_account_button_title".localized()
        
        return result
    }()
    
    private lazy var clearDataButton: UIButton = {
        let result: UIButton = Modal.createButton(
            title: "modal_clear_all_data_confirm".localized(),
            titleColor: .danger
        )
        result.addTarget(self, action: #selector(clearAllData), for: UIControl.Event.touchUpInside)
        
        return result
    }()
    
    private lazy var buttonStackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [ clearDataButton, cancelButton ])
        result.axis = .horizontal
        result.distribution = .fillEqually
        
        return result
    }()
    
    private lazy var contentStackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [
            titleLabel,
            explanationLabel,
            clearDeviceRadio,
            UIView.separator(),
            clearNetworkRadio
        ])
        result.axis = .vertical
        result.spacing = Values.smallSpacing
        result.isLayoutMarginsRelativeArrangement = true
        result.layoutMargins = UIEdgeInsets(
            top: Values.largeSpacing,
            leading: Values.largeSpacing,
            bottom: Values.verySmallSpacing,
            trailing: Values.largeSpacing
        )
        
        return result
    }()
    
    private lazy var mainStackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [ contentStackView, buttonStackView ])
        result.axis = .vertical
        result.spacing = Values.largeSpacing - Values.smallFontSize / 2
        
        return result
    }()
    
    // MARK: - Lifecycle
    
    override func populateContentView() {
        contentView.addSubview(mainStackView)
        
        mainStackView.pin(to: contentView)
    }
    
    // MARK: - Interaction
    
    @objc private func clearAllData() {
        guard clearNetworkRadio.isSelected else {
            clearDeviceOnly()
            return
        }
        
        let confirmationModal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: "modal_clear_all_data_title".localized(),
                body: .text("modal_clear_all_data_explanation_2".localized()),
                confirmTitle: "modal_clear_all_data_confirm".localized(),
                confirmStyle: .danger,
                cancelStyle: .alert_text,
                dismissOnConfirm: false
            ) { [weak self] confirmationModal in
                self?.clearEntireAccount(presentedViewController: confirmationModal)
            }
        )
        present(confirmationModal, animated: true, completion: nil)
    }
    
    private func clearDeviceOnly() {
        ModalActivityIndicatorViewController.present(fromViewController: self, canCancel: false) { [weak self] _ in
            ConfigurationSyncJob.run(sessionIdHexString: getUserSessionId().hexString)
                .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                .receive(on: DispatchQueue.main)
                .sinkUntilComplete(
                    receiveCompletion: { _ in
                        self?.deleteAllLocalData()
                        self?.dismiss(animated: true, completion: nil) // Dismiss the loader
                    }
                )
        }
    }
    
    private func clearEntireAccount(
        presentedViewController: UIViewController,
        using dependencies: Dependencies = Dependencies()
    ) {
        typealias PreparedClearRequests = (
            deleteAll: HTTP.PreparedRequest<[String: Bool]>,
            inboxRequestInfo: [HTTP.PreparedRequest<String>]
        )
        
        ModalActivityIndicatorViewController
            .present(fromViewController: presentedViewController, canCancel: false) { [weak self] _ in
                dependencies[singleton: .storage]
                    .readPublisher { db -> PreparedClearRequests in
                        (
                            try SnodeAPI.preparedDeleteAllMessages(
                                namespace: .all,
                                authMethod: try Authentication.with(
                                    db,
                                    sessionIdHexString: getUserSessionId(db, using: dependencies).hexString,
                                    using: dependencies
                                ),
                                using: dependencies
                            ),
                            try OpenGroup
                                .filter(OpenGroup.Columns.isActive == true)
                                .select(.server)
                                .distinct()
                                .asRequest(of: String.self)
                                .fetchSet(db)
                                .map { server in
                                    try OpenGroupAPI.preparedClearInbox(db, on: server)
                                        .map { _, _ in server }
                                }
                        )
                    }
                    .subscribe(on: DispatchQueue.global(qos: .userInitiated), using: dependencies)
                    .flatMap { preparedRequests -> AnyPublisher<(HTTP.PreparedRequest<[String: Bool]>, [String]), Error> in
                        Publishers
                            .MergeMany(preparedRequests.inboxRequestInfo.map { $0.send(using: dependencies) })
                            .collect()
                            .map { response in (preparedRequests.deleteAll, response.map { $0.1 }) }
                            .eraseToAnyPublisher()
                    }
                    .flatMap { preparedDeleteAllRequest, clearedServers in
                        preparedDeleteAllRequest
                            .send(using: dependencies)
                            .map { _, data in
                                clearedServers.reduce(into: data) { result, next in result[next] = true }
                            }
                    }
                    .receive(on: DispatchQueue.main, using: dependencies)
                    .sinkUntilComplete(
                        receiveCompletion: { result in
                            switch result {
                                case .finished: break
                                case .failure(let error):
                                    self?.dismiss(animated: true, completion: nil) // Dismiss the loader

                                    let modal: ConfirmationModal = ConfirmationModal(
                                        targetView: self?.view,
                                        info: ConfirmationModal.Info(
                                            title: "ALERT_ERROR_TITLE".localized(),
                                            body: .text(error.localizedDescription),
                                            cancelTitle: "BUTTON_OK".localized(),
                                            cancelStyle: .alert_text
                                        )
                                    )
                                    self?.present(modal, animated: true)
                            }
                        },
                        receiveValue: { confirmations in
                            self?.dismiss(animated: true, completion: nil) // Dismiss the loader

                            let potentiallyMaliciousSnodes = confirmations
                                .compactMap { ($0.value == false ? $0.key : nil) }

                            guard !potentiallyMaliciousSnodes.isEmpty else {
                                self?.deleteAllLocalData()
                                return
                            }

                            let message: String

                            if potentiallyMaliciousSnodes.count == 1 {
                                message = String(format: "dialog_clear_all_data_deletion_failed_1".localized(), potentiallyMaliciousSnodes[0])
                            }
                            else {
                                message = String(format: "dialog_clear_all_data_deletion_failed_2".localized(), String(potentiallyMaliciousSnodes.count), potentiallyMaliciousSnodes.joined(separator: ", "))
                            }

                            let modal: ConfirmationModal = ConfirmationModal(
                                targetView: self?.view,
                                info: ConfirmationModal.Info(
                                    title: "ALERT_ERROR_TITLE".localized(),
                                    body: .text(message),
                                    cancelTitle: "BUTTON_OK".localized(),
                                    cancelStyle: .alert_text
                                )
                            )
                            self?.present(modal, animated: true)
                        }
                    )
            }
    }
    
    private func deleteAllLocalData(using dependencies: Dependencies = Dependencies()) {
        // Unregister push notifications if needed
        let isUsingFullAPNs: Bool = dependencies[defaults: .standard, key: .isUsingFullAPNs]
        let maybeDeviceToken: String? = dependencies[defaults: .standard, key: .deviceToken]
        
        if isUsingFullAPNs, let deviceToken: String = maybeDeviceToken {
            PushNotificationAPI
                .unsubscribeAll(token: Data(hex: deviceToken), using: dependencies)
                .sinkUntilComplete()
        }
        
        /// Stop and cancel all current jobs (don't want to inadvertantly have a job store data after it's table has already been cleared)
        ///
        /// **Note:** This is file as long as this process kills the app, if it doesn't then we need an alternate mechanism to flag that
        /// the `JobRunner` is allowed to start it's queues again
        dependencies[singleton: .jobRunner].stopAndClearPendingJobs(using: dependencies)
        
        // Clear the app badge and notifications
        dependencies[singleton: .notificationsManager].clearAllNotifications()
        UIApplication.shared.applicationIconBadgeNumber = 0
        
        // Clear out the user defaults
        UserDefaults.removeAll()
        
        // Remove the cached key so it gets re-cached on next access
        dependencies.mutate(cache: .general) {
            $0.sessionId = nil
            $0.recentReactionTimestamps = []
        }
        
        // Clear the Snode pool
        SnodeAPI.clearSnodePool(using: dependencies)
        
        // Stop any pollers
        (UIApplication.shared.delegate as? AppDelegate)?.stopPollers(using: dependencies)
        
        // Call through to the SessionApp's "resetAppData" which will wipe out logs, database and
        // profile storage
        let wasUnlinked: Bool = dependencies[defaults: .standard, key: .wasUnlinked]
        
        SessionApp.resetAppData(using: dependencies) {
            // Resetting the data clears the old user defaults. We need to restore the unlink default.
            dependencies[defaults: .standard, key: .wasUnlinked] = wasUnlinked
        }
    }
}
