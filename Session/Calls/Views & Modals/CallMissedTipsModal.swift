// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit

final class CallMissedTipsModal: Modal {
    private let caller: String
    
    // MARK: - UI
    
    private lazy var tipsIconContainerView: UIView = UIView()
    
    private lazy var tipsIconImageView: UIImageView = {
        let result: UIImageView = UIImageView(
            image: UIImage(named: "Tips")?.withRenderingMode(.alwaysTemplate)
        )
        result.themeTintColor = .textPrimary
        result.set(.width, to: 19)
        result.set(.height, to: 28)
        
        return result
    }()
    
    private lazy var titleLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        result.text = "callsMissedCallFrom"
            .put(key: "name", value: caller)
            .localized()
        result.themeTextColor = .textPrimary
        result.textAlignment = .center
        
        return result
    }()
    
    private lazy var messageLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .systemFont(ofSize: Values.smallFontSize)
        result.themeTextColor = .textPrimary
        result.textAlignment = .natural
        result.lineBreakMode = .byWordWrapping
        result.numberOfLines = 0
        result.attributedText = "callsYouMissedCallPermissions"
            .put(key: "name", value: caller)
            .localizedFormatted(in: result)
        
        return result
    }()
    
    private lazy var contentStackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [ tipsIconContainerView, titleLabel, messageLabel ])
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
        let result = UIStackView(arrangedSubviews: [ contentStackView, cancelButton ])
        result.axis = .vertical
        result.spacing = Values.largeSpacing - Values.smallFontSize / 2
        
        return result
    }()
    
    // MARK: - Lifecycle
    
    init(caller: String) {
        self.caller = caller
        
        super.init()
        
        self.modalPresentationStyle = .overFullScreen
        self.modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) {
        preconditionFailure("Use init(caller:) instead.")
    }

    override func populateContentView() {
        cancelButton.setTitle("okay".localized(), for: .normal)
        
        contentView.addSubview(mainStackView)
        tipsIconContainerView.addSubview(tipsIconImageView)
        
        mainStackView.pin(to: contentView)
        
        tipsIconImageView.pin(.top, to: .top, of: tipsIconContainerView)
        tipsIconImageView.pin(.bottom, to: .bottom, of: tipsIconContainerView)
        tipsIconImageView.center(in: tipsIconContainerView)
    }
}
