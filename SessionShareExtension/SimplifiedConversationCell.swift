// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SignalUtilitiesKit
import SessionUtilitiesKit

final class SimplifiedConversationCell: UITableViewCell {
    // MARK: - Initialization
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setUpViewHierarchy()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpViewHierarchy()
    }
    
    // MARK: - UI
    
    private lazy var stackView: UIStackView = {
        let stackView: UIStackView = UIStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = Values.mediumSpacing
        
        return stackView
    }()
    
    private lazy var accentLineView: UIView = {
        let result = UIView()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.themeBackgroundColor = .danger
        
        return result
    }()
    
    private lazy var profilePictureView: ProfilePictureView = {
        let view: ProfilePictureView = ProfilePictureView(size: .list)
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    private lazy var displayNameLabel: UILabel = {
        let result = UILabel()
        result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        result.themeTextColor = .textPrimary
        result.lineBreakMode = .byTruncatingTail
        
        return result
    }()
    
    // MARK: - Initialization
    
    private func setUpViewHierarchy() {
        themeBackgroundColor = .conversationButton_background
        
        let selectedBackgroundView = UIView()
        selectedBackgroundView.themeBackgroundColor = .highlighted(.conversationButton_background)
        self.selectedBackgroundView = selectedBackgroundView
        
        addSubview(stackView)
        
        stackView.addArrangedSubview(accentLineView)
        stackView.addArrangedSubview(profilePictureView)
        stackView.addArrangedSubview(displayNameLabel)
        stackView.addArrangedSubview(UIView.hSpacer(0))
        
        setupLayout()
    }
    
    // MARK: - Layout
    
    private func setupLayout() {
        accentLineView.set(.width, to: Values.accentLineThickness)
        accentLineView.set(.height, to: 68)
        
        stackView.pin(to: self)
    }
    
    // MARK: - Updating
    
    public func update(with cellViewModel: SessionThreadViewModel, using dependencies: Dependencies) {
        accentLineView.alpha = (cellViewModel.threadIsBlocked == true ? 1 : 0)
        profilePictureView.update(
            publicKey: cellViewModel.threadId,
            threadVariant: cellViewModel.threadVariant,
            displayPictureFilename: cellViewModel.displayPictureFilename,
            profile: cellViewModel.profile,
            additionalProfile: cellViewModel.additionalProfile,
            using: dependencies
        )
        displayNameLabel.text = cellViewModel.displayName
    }
}
