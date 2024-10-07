// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit

class VersionFooterView: UIView {
    private static let footerHeight: CGFloat = 75
    private static let logoHeight: CGFloat = 24
    
    private let multiTapCallback: (() -> Void)?
    
    // MARK: - UI
    
    private lazy var logoImageView: UIImageView = {
        let result: UIImageView = UIImageView(
            image: UIImage(named: "oxen_logo")?
                .withRenderingMode(.alwaysTemplate)
        )
        result.setContentHuggingPriority(.required, for: .vertical)
        result.setContentCompressionResistancePriority(.required, for: .vertical)
        result.themeTintColor = .textSecondary
        result.contentMode = .scaleAspectFit
        result.set(.height, to: VersionFooterView.logoHeight)
        
        return result
    }()
    
    private lazy var versionLabel: UILabel = {
        let result: UILabel = UILabel()
        result.setContentHuggingPriority(.required, for: .vertical)
        result.setContentCompressionResistancePriority(.required, for: .vertical)
        result.font = .systemFont(ofSize: Values.verySmallFontSize)
        result.themeTextColor = .textSecondary
        result.textAlignment = .center
        result.lineBreakMode = .byCharWrapping
        result.numberOfLines = 0
        
        let infoDict = Bundle.main.infoDictionary
        let version: String = ((infoDict?["CFBundleShortVersionString"] as? String) ?? "0.0.0")   // stringlint:disable
        let buildNumber: String? = (infoDict?["CFBundleVersion"] as? String)                      // stringlint:disable
        let commitInfo: String? = (infoDict?["GitCommitHash"] as? String)                         // stringlint:disable
        let buildInfo: String? = [buildNumber, commitInfo]
            .compactMap { $0 }
            .joined(separator: " - ")                                                             // stringlint:disable
            .nullIfEmpty
            .map { "(\($0))" }                                                                    // stringlint:disable
        result.text = [
            "Version \(version)",                                                                 // stringlint:disable
            buildInfo
        ].compactMap { $0 }.joined(separator: " ")                                                // stringlint:disable
        
        return result
    }()
    
    // MARK: - Initialization
    
    init(numTaps: Int = 0, multiTapCallback: (() -> Void)? = nil) {
        self.multiTapCallback = multiTapCallback
        
        // Note: Need to explicitly set the height for a table footer view
        // or it will have no height
        super.init(
            frame: CGRect(
                x: 0,
                y: 0,
                width: 0,
                height: VersionFooterView.footerHeight
            )
        )
        
        setupViewHierarchy(numTaps: numTaps)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Content
    
    private func setupViewHierarchy(numTaps: Int) {
        addSubview(logoImageView)
        addSubview(versionLabel)
        
        logoImageView.pin(.top, to: .top, of: self, withInset: Values.mediumSpacing)
        logoImageView.center(.horizontal, in: self, withInset: -2)
        versionLabel.pin(.top, to: .bottom, of: logoImageView, withInset: Values.mediumSpacing)
        versionLabel.pin(.left, to: .left, of: self)
        versionLabel.pin(.right, to: .right, of: self)
        
        if numTaps > 0 {
            let tapGestureRecognizer: UITapGestureRecognizer = UITapGestureRecognizer(
                target: self,
                action: #selector(onMultiTap)
            )
            tapGestureRecognizer.numberOfTapsRequired = numTaps
            addGestureRecognizer(tapGestureRecognizer)
        }
    }
    
    @objc private func onMultiTap() {
        self.multiTapCallback?()
    }
}
