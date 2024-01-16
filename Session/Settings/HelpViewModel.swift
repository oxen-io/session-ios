// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import CryptoKit
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalCoreKit

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
    
    let title: String = "HELP_TITLE".localized()
    
    lazy var observation: TargetObservation = [
        SectionModel(
            model: .report,
            elements: [
                SessionCell.Info(
                    id: .report,
                    title: "HELP_REPORT_BUG_TITLE".localized(),
                    subtitle: "HELP_REPORT_BUG_DESCRIPTION".localized(),
                    trailingAccessory: .highlightingBackgroundLabel(
                        title: "HELP_REPORT_BUG_ACTION_TITLE".localized()
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
                    title: "HELP_TRANSLATE_TITLE".localized(),
                    trailingAccessory: .icon(
                        UIImage(systemName: "arrow.up.forward.app")?
                            .withRenderingMode(.alwaysTemplate),
                        size: .small
                    ),
                    onTap: {
                        guard let url: URL = URL(string: "https://crowdin.com/project/session-ios") else {
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
                    title: "HELP_FEEDBACK_TITLE".localized(),
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
                    title: "HELP_FAQ_TITLE".localized(),
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
                    title: "HELP_SUPPORT_TITLE".localized(),
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
        OWSLogger.info("[Version] \(SessionApp.versionInfo)")
        DDLog.flushLog()
        
        let logFilePaths: [String] = AppEnvironment.shared.fileLogger.logFileManager.sortedLogFilePaths
        
        guard
            let latestLogFilePath: String = logFilePaths.first,
            dependencies.hasInitialised(singleton: .appContext),
            let viewController: UIViewController = dependencies[singleton: .appContext].frontmostViewController
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
