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
    
    init(shouldShowCloseButton: Bool = false, using dependencies: Dependencies = Dependencies()) {
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
                case .screenSecurity: return "screenSecurity".localized()
                case .messageRequests: return "sessionMessageRequests".localized()
                case .readReceipts: return "readReceipts".localized()
                case .typingIndicators: return "typingIndicators".localized()
                case .linkPreviews: return "linkPreviews".localized()
                case .calls: return "callsSettings".localized()
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
    
    let title: String = "sessionPrivacy".localized()
    
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
                            title: "lockApp".localized(),
                            subtitle: "lockAppDescriptionIos"
                                .put(key: "app_name", value: Singleton.appName)
                                .localized(),
                            rightAccessory: .toggle(
                                .boolValue(
                                    key: .isScreenLockEnabled,
                                    value: current.isScreenLockEnabled,
                                    oldValue: (previous ?? current).isScreenLockEnabled
                                )
                            ),
                            onTap: { [weak self] in
                                // Make sure the device has a passcode set before allowing screen lock to
                                // be enabled (Note: This will always return true on a simulator)
                                guard LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
                                    self?.transitionToScreen(
                                        ConfirmationModal(
                                            info: ConfirmationModal.Info(
                                                title: "lockAppEnablePasscode".localized(),
                                                cancelTitle: "okay".localized(),
                                                cancelStyle: .alert_text
                                            )
                                        ),
                                        transitionType: .present
                                    )
                                    return
                                }
                                
                                Storage.shared.write { db in
                                    try db.setAndUpdateConfig(.isScreenLockEnabled, to: !db[.isScreenLockEnabled])
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
                            title: "messageRequestsCommunities".localized(),
                            subtitle: "messageRequestsCommunitiesDescription".localized(),
                            rightAccessory: .toggle(
                                .boolValue(
                                    key: .checkForCommunityMessageRequests,
                                    value: current.checkForCommunityMessageRequests,
                                    oldValue: (previous ?? current).checkForCommunityMessageRequests
                                )
                            ),
                            onTap: { [weak self] in
                                Storage.shared.write { db in
                                    try db.setAndUpdateConfig(
                                        .checkForCommunityMessageRequests,
                                        to: !db[.checkForCommunityMessageRequests]
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
                            title: "readReceipts".localized(),
                            subtitle: "readReceiptsDescription".localized(),
                            rightAccessory: .toggle(
                                .boolValue(
                                    key: .areReadReceiptsEnabled,
                                    value: current.areReadReceiptsEnabled,
                                    oldValue: (previous ?? current).areReadReceiptsEnabled
                                )
                            ),
                            onTap: {
                                Storage.shared.write { db in
                                    try db.setAndUpdateConfig(.areReadReceiptsEnabled, to: !db[.areReadReceiptsEnabled])
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
                                "typingIndicators".localized(),
                                font: .title
                            ),
                            subtitle: SessionCell.TextInfo(
                                "typingIndicatorsDescription".localized(),
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
                                    cell.transform = CGAffineTransform.scale(targetHeight / cell.bounds.height)
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
                            rightAccessory: .toggle(
                                .boolValue(
                                    key: .typingIndicatorsEnabled,
                                    value: current.typingIndicatorsEnabled,
                                    oldValue: (previous ?? current).typingIndicatorsEnabled
                                )
                            ),
                            onTap: {
                                Storage.shared.write { db in
                                    try db.setAndUpdateConfig(.typingIndicatorsEnabled, to: !db[.typingIndicatorsEnabled])
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
                            title: "linkPreviewsSend".localized(),
                            subtitle: "linkPreviewsDescription".localized(),
                            rightAccessory: .toggle(
                                .boolValue(
                                    key: .areLinkPreviewsEnabled,
                                    value: current.areLinkPreviewsEnabled,
                                    oldValue: (previous ?? current).areLinkPreviewsEnabled
                                )
                            ),
                            onTap: {
                                Storage.shared.write { db in
                                    try db.setAndUpdateConfig(.areLinkPreviewsEnabled, to: !db[.areLinkPreviewsEnabled])
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
                            title: "callsVoiceAndVideo".localized(),
                            subtitle: "callsVoiceAndVideoToggleDescription".localized(),
                            rightAccessory: .toggle(
                                .boolValue(
                                    key: .areCallsEnabled,
                                    value: current.areCallsEnabled,
                                    oldValue: (previous ?? current).areCallsEnabled
                                )
                            ),
                            accessibility: Accessibility(
                                label: "Allow voice and video calls"
                            ),
                            confirmationInfo: ConfirmationModal.Info(
                                title: "callsVoiceAndVideoBeta".localized(),
                                body: .text("callsVoiceAndVideoModalDescription".localized()),
                                showCondition: .disabled,
                                confirmTitle: "theContinue".localized(),
                                confirmAccessibility: Accessibility(identifier: "Enable"),
                                confirmStyle: .textPrimary,
                                onConfirm: { _ in Permissions.requestMicrophonePermissionIfNeeded() }
                            ),
                            onTap: {
                                Storage.shared.write { db in
                                    try db.setAndUpdateConfig(.areCallsEnabled, to: !db[.areCallsEnabled])
                                }
                            }
                        )
                    ]
                )
            ]
        }
}
