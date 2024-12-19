// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import CryptoKit
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

class HelpViewModel: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource {
    typealias TableItem = Section
    
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - Section
    
    public enum Section: SessionTableSection {
        case report
        case translate
        case feedback
        case faq
        case support
        
        var style: SessionTableSectionStyle { .padding }
    }
    
    // MARK: - Content
    
    let title: String = "sessionHelp".localized()
    
    lazy var observation: TargetObservation = [
        SectionModel(
            model: .report,
            elements: [
                SessionCell.Info(
                    id: .report,
                    title: "helpReportABug".localized(),
                    subtitle: "helpReportABugExportLogsDescription"
                        .put(key: "app_name", value: Constants.app_name)
                        .localized(),
                    trailingAccessory: .highlightingBackgroundLabel(
                        title: "helpReportABugExportLogs".localized()
                    ),
                    onTapView: { [dependencies] view in
                        HelpViewModel.shareLogs(targetView: view, using: dependencies)
                    }
                )
            ]
        ),
        SectionModel(
            model: .translate,
            elements: [
                SessionCell.Info(
                    id: .translate,
                    title: "helpHelpUsTranslateSession"
                        .put(key: "app_name", value: Constants.app_name)
                        .localized(),
                    trailingAccessory: .icon(
                        UIImage(systemName: "arrow.up.forward.app")?
                            .withRenderingMode(.alwaysTemplate),
                        size: .small
                    ),
                    onTap: {
                        guard let url: URL = URL(string: "https://getsession.org/translate") else {
                            return
                        }
                        
                        UIApplication.shared.open(url)
                    }
                )
            ]
        ),
        SectionModel(
            model: .feedback,
            elements: [
                SessionCell.Info(
                    id: .feedback,
                    title: "helpWedLoveYourFeedback".localized(),
                    trailingAccessory: .icon(
                        UIImage(systemName: "arrow.up.forward.app")?
                            .withRenderingMode(.alwaysTemplate),
                        size: .small
                    ),
                    onTap: {
                        guard let url: URL = URL(string: "https://getsession.org/survey") else {
                            return
                        }
                        
                        UIApplication.shared.open(url)
                    }
                )
            ]
        ),
        SectionModel(
            model: .faq,
            elements: [
                SessionCell.Info(
                    id: .faq,
                    title: "helpFAQ".localized(),
                    trailingAccessory: .icon(
                        UIImage(systemName: "arrow.up.forward.app")?
                            .withRenderingMode(.alwaysTemplate),
                        size: .small
                    ),
                    onTap: {
                        guard let url: URL = URL(string: "https://getsession.org/faq") else {
                            return
                        }
                        
                        UIApplication.shared.open(url)
                    }
                )
            ]
        ),
        SectionModel(
            model: .support,
            elements: [
                SessionCell.Info(
                    id: .support,
                    title: "helpSupport".localized(),
                    trailingAccessory: .icon(
                        UIImage(systemName: "arrow.up.forward.app")?
                            .withRenderingMode(.alwaysTemplate),
                        size: .small
                    ),
                    onTap: {
                        guard let url: URL = URL(string: "https://sessionapp.zendesk.com/hc/en-us") else {
                            return
                        }
                        
                        UIApplication.shared.open(url)
                    }
                )
            ]
        )
    ]
    
    // MARK: - Functions
    
    public static func shareLogs(
        viewControllerToDismiss: UIViewController? = nil,
        targetView: UIView? = nil,
        animated: Bool = true,
        using dependencies: Dependencies,
        onShareComplete: (() -> ())? = nil
    ) {
        guard
            let latestLogFilePath: String = Log.logFilePath(using: dependencies),
            let viewController: UIViewController = dependencies[singleton: .appContext].frontMostViewController
        else { return }
        
        #if targetEnvironment(simulator)
        // stringlint:ignore_start
        let modal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: "Export Logs",
                body: .text(
                    "How would you like to export the logs?\n\n(This modal only appears on the Simulator)"
                ),
                confirmTitle: "Copy Path",
                cancelTitle: "Share",
                cancelStyle: .alert_text,
                onConfirm: { _ in UIPasteboard.general.string = latestLogFilePath },
                onCancel: { modal in
                    modal.dismiss(animated: true) {
                        HelpViewModel.shareLogsInternal(
                            viewControllerToDismiss: viewControllerToDismiss,
                            targetView: targetView,
                            animated: animated,
                            using: dependencies,
                            onShareComplete: onShareComplete
                        )
                    }
                }
            )
        )
        // stringlint:ignore_stop
        viewController.present(modal, animated: animated, completion: nil)
        #else
        HelpViewModel.shareLogsInternal(
            viewControllerToDismiss: viewControllerToDismiss,
            targetView: targetView,
            animated: animated,
            using: dependencies,
            onShareComplete: onShareComplete
        )
        #endif
    }
    
    private static func shareLogsInternal(
        viewControllerToDismiss: UIViewController? = nil,
        targetView: UIView? = nil,
        animated: Bool = true,
        using dependencies: Dependencies,
        onShareComplete: (() -> ())? = nil
    ) {
        Log.info("[Version] \(dependencies[cache: .appVersion].versionInfo)")
        Log.flush()
        
        guard
            let latestLogFilePath: String = Log.logFilePath(using: dependencies),
            let viewController: UIViewController = dependencies[singleton: .appContext].frontMostViewController
        else { return }
        
        let showShareSheet: () -> () = {
            let shareVC = UIActivityViewController(
                activityItems: [ URL(fileURLWithPath: latestLogFilePath) ],
                applicationActivities: nil
            )
            shareVC.completionWithItemsHandler = { _, _, _, _ in onShareComplete?() }
            
            if UIDevice.current.isIPad {
                shareVC.excludedActivityTypes = []
                shareVC.popoverPresentationController?.permittedArrowDirections = (targetView != nil ? [.up] : [])
                shareVC.popoverPresentationController?.sourceView = (targetView ?? viewController.view)
                shareVC.popoverPresentationController?.sourceRect = (targetView ?? viewController.view).bounds
            }
            viewController.present(shareVC, animated: animated, completion: nil)
        }
        
        guard let viewControllerToDismiss: UIViewController = viewControllerToDismiss else {
            showShareSheet()
            return
        }

        viewControllerToDismiss.dismiss(animated: animated) {
            showShareSheet()
        }
    }
}
