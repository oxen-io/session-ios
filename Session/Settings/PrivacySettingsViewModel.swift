// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import LocalAuthentication
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

class PrivacySettingsViewModel: SessionTableViewModel, NavigationItemSource, NavigatableStateHolder, ObservableTableSource {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let editableState: EditableState<TableItem> = EditableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    private let shouldShowCloseButton: Bool
    
    // MARK: - Initialization
    
    init(shouldShowCloseButton: Bool = false, using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.shouldShowCloseButton = shouldShowCloseButton
    }
    
    // MARK: - Config
    
    enum NavItem: Equatable {
        case close
    }
    
    public enum Section: SessionTableSection {
        case screenSecurity
        case messageRequests
        case readReceipts
        case typingIndicators
        case linkPreviews
        case calls
        
        var title: String? {
            switch self {
                case .screenSecurity: return "PRIVACY_SECTION_SCREEN_SECURITY".localized()
                case .messageRequests: return "PRIVACY_SECTION_MESSAGE_REQUESTS".localized()
                case .readReceipts: return "PRIVACY_SECTION_READ_RECEIPTS".localized()
                case .typingIndicators: return "PRIVACY_SECTION_TYPING_INDICATORS".localized()
                case .linkPreviews: return "PRIVACY_SECTION_LINK_PREVIEWS".localized()
                case .calls: return "PRIVACY_SECTION_CALLS".localized()
            }
        }
        
        var style: SessionTableSectionStyle { return .titleRoundedContent }
    }
    
    public enum TableItem: Differentiable {
        case screenLock
        case communityMessageRequests
        case screenshotNotifications
        case readReceipts
        case typingIndicators
        case linkPreviews
        case calls
    }
    
    // MARK: - Navigation
    
    lazy var leftNavItems: AnyPublisher<[SessionNavItem<NavItem>], Never> = (!shouldShowCloseButton ? [] :
        [
            SessionNavItem(
                id: .close,
                image: UIImage(named: "X")?
                    .withRenderingMode(.alwaysTemplate),
                style: .plain,
                accessibilityIdentifier: "Close button"
            ) { [weak self] in self?.dismissScreen() }
        ]
    )
    
    // MARK: - Content
    
    private struct State: Equatable {
        let isScreenLockEnabled: Bool
        let checkForCommunityMessageRequests: Bool
        let areReadReceiptsEnabled: Bool
        let typingIndicatorsEnabled: Bool
        let areLinkPreviewsEnabled: Bool
        let areCallsEnabled: Bool
    }
    
    let title: String = "PRIVACY_TITLE".localized()
    
    lazy var observation: TargetObservation = ObservationBuilder
        .databaseObservation(self) { [weak self] db -> State in
            State(
                isScreenLockEnabled: db[.isScreenLockEnabled],
                checkForCommunityMessageRequests: db[.checkForCommunityMessageRequests],
                areReadReceiptsEnabled: db[.areReadReceiptsEnabled],
                typingIndicatorsEnabled: db[.typingIndicatorsEnabled],
                areLinkPreviewsEnabled: db[.areLinkPreviewsEnabled],
                areCallsEnabled: db[.areCallsEnabled]
            )
        }
        .mapWithPrevious { [dependencies] previous, current -> [SectionModel] in
            return [
                SectionModel(
                    model: .screenSecurity,
                    elements: [
                        SessionCell.Info(
                            id: .screenLock,
                            title: "PRIVACY_SCREEN_SECURITY_LOCK_SESSION_TITLE".localized(),
                            subtitle: "PRIVACY_SCREEN_SECURITY_LOCK_SESSION_DESCRIPTION".localized(),
                            trailingAccessory: .toggle(
                                current.isScreenLockEnabled,
                                oldValue: previous?.isScreenLockEnabled
                            ),
                            onTap: { [weak self] in
                                // Make sure the device has a passcode set before allowing screen lock to
                                // be enabled (Note: This will always return true on a simulator)
                                guard LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
                                    self?.transitionToScreen(
                                        ConfirmationModal(
                                            info: ConfirmationModal.Info(
                                                title: "SCREEN_LOCK_ERROR_LOCAL_AUTHENTICATION_NOT_AVAILABLE".localized(),
                                                cancelTitle: "BUTTON_OK".localized(),
                                                cancelStyle: .alert_text
                                            )
                                        ),
                                        transitionType: .present
                                    )
                                    return
                                }
                                
                                dependencies[singleton: .storage].write { db in
                                    try db.setAndUpdateConfig(
                                        .isScreenLockEnabled,
                                        to: !db[.isScreenLockEnabled],
                                        using: dependencies
                                    )
                                }
                            }
                        )
                    ]
                ),
                SectionModel(
                    model: .messageRequests,
                    elements: [
                        SessionCell.Info(
                            id: .communityMessageRequests,
                            title: "PRIVACY_SCREEN_MESSAGE_REQUESTS_COMMUNITY_TITLE".localized(),
                            subtitle: "PRIVACY_SCREEN_MESSAGE_REQUESTS_COMMUNITY_DESCRIPTION".localized(),
                            trailingAccessory: .toggle(
                                current.checkForCommunityMessageRequests,
                                oldValue: previous?.checkForCommunityMessageRequests
                            ),
                            onTap: { [weak self] in
                                dependencies[singleton: .storage].write { db in
                                    try db.setAndUpdateConfig(
                                        .checkForCommunityMessageRequests,
                                        to: !db[.checkForCommunityMessageRequests],
                                        using: dependencies
                                    )
                                }
                            }
                        )
                    ]
                ),
                SectionModel(
                    model: .readReceipts,
                    elements: [
                        SessionCell.Info(
                            id: .readReceipts,
                            title: "PRIVACY_READ_RECEIPTS_TITLE".localized(),
                            subtitle: "PRIVACY_READ_RECEIPTS_DESCRIPTION".localized(),
                            trailingAccessory: .toggle(
                                current.areReadReceiptsEnabled,
                                oldValue: previous?.areReadReceiptsEnabled
                            ),
                            onTap: {
                                dependencies[singleton: .storage].write { db in
                                    try db.setAndUpdateConfig(
                                        .areReadReceiptsEnabled,
                                        to: !db[.areReadReceiptsEnabled],
                                        using: dependencies
                                    )
                                }
                            }
                        )
                    ]
                ),
                SectionModel(
                    model: .typingIndicators,
                    elements: [
                        SessionCell.Info(
                            id: .typingIndicators,
                            title: SessionCell.TextInfo(
                                "PRIVACY_TYPING_INDICATORS_TITLE".localized(),
                                font: .title
                            ),
                            subtitle: SessionCell.TextInfo(
                                "PRIVACY_TYPING_INDICATORS_DESCRIPTION".localized(),
                                font: .subtitle,
                                extraViewGenerator: {
                                    let targetHeight: CGFloat = 20
                                    let targetWidth: CGFloat = ceil(20 * (targetHeight / 12))
                                    let result: UIView = UIView(
                                        frame: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
                                    )
                                    result.set(.width, to: targetWidth)
                                    result.set(.height, to: targetHeight)
                                    
                                    // Use a transform scale to reduce the size of the typing indicator to the
                                    // desired size (this way the animation remains intact)
                                    let cell: TypingIndicatorCell = TypingIndicatorCell()
                                    cell.transform = CGAffineTransform(
                                        scaleX: targetHeight / cell.bounds.height,
                                        y: targetHeight / cell.bounds.height
                                    )
                                    cell.typingIndicatorView.startAnimation()
                                    result.addSubview(cell)
                                    
                                    // Note: Because we are messing with the transform these values don't work
                                    // logically so we inset the positioning to make it look visually centered
                                    // within the layout inspector
                                    cell.center(.vertical, in: result, withInset: -(targetHeight * 0.15))
                                    cell.center(.horizontal, in: result, withInset: -(targetWidth * 0.35))
                                    cell.set(.width, to: .width, of: result)
                                    cell.set(.height, to: .height, of: result)
                                    
                                    return result
                                }
                            ),
                            trailingAccessory: .toggle(
                                current.typingIndicatorsEnabled,
                                oldValue: previous?.typingIndicatorsEnabled
                            ),
                            onTap: {
                                dependencies[singleton: .storage].write { db in
                                    try db.setAndUpdateConfig(
                                        .typingIndicatorsEnabled,
                                        to: !db[.typingIndicatorsEnabled],
                                        using: dependencies
                                    )
                                }
                            }
                        )
                    ]
                ),
                SectionModel(
                    model: .linkPreviews,
                    elements: [
                        SessionCell.Info(
                            id: .linkPreviews,
                            title: "PRIVACY_LINK_PREVIEWS_TITLE".localized(),
                            subtitle: "PRIVACY_LINK_PREVIEWS_DESCRIPTION".localized(),
                            trailingAccessory: .toggle(
                                current.areLinkPreviewsEnabled,
                                oldValue: previous?.areLinkPreviewsEnabled
                            ),
                            onTap: {
                                dependencies[singleton: .storage].write { db in
                                    try db.setAndUpdateConfig(
                                        .areLinkPreviewsEnabled,
                                        to: !db[.areLinkPreviewsEnabled],
                                        using: dependencies
                                    )
                                }
                            }
                        )
                    ]
                ),
                SectionModel(
                    model: .calls,
                    elements: [
                        SessionCell.Info(
                            id: .calls,
                            title: "PRIVACY_CALLS_TITLE".localized(),
                            subtitle: "PRIVACY_CALLS_DESCRIPTION".localized(),
                            trailingAccessory: .toggle(
                                current.areCallsEnabled,
                                oldValue: previous?.areCallsEnabled
                            ),
                            accessibility: Accessibility(
                                label: "Allow voice and video calls"
                            ),
                            confirmationInfo: ConfirmationModal.Info(
                                title: "PRIVACY_CALLS_WARNING_TITLE".localized(),
                                body: .text("PRIVACY_CALLS_WARNING_DESCRIPTION".localized()),
                                showCondition: .disabled,
                                confirmTitle: "continue_2".localized(),
                                confirmAccessibility: Accessibility(identifier: "Enable"),
                                confirmStyle: .textPrimary,
                                onConfirm: { _ in Permissions.requestMicrophonePermissionIfNeeded(using: dependencies) }
                            ),
                            onTap: {
                                dependencies[singleton: .storage].write { db in
                                    try db.setAndUpdateConfig(
                                        .areCallsEnabled,
                                        to: !db[.areCallsEnabled],
                                        using: dependencies
                                    )
                                }
                            }
                        )
                    ]
                )
            ]
        }
}
