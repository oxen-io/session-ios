// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

public class ThemePreviewView: UIView {
    private let dependencies: Dependencies
    
    // MARK: - Components
    
    private lazy var incomingMessagePreview: UIView = {
        let result: VisibleMessageCell = VisibleMessageCell()
        result.translatesAutoresizingMaskIntoConstraints = true
        result.update(
            with: MessageViewModel(
                variant: .standardIncoming,
                body: "appearancePreview2".localized(),
                quote: Quote(
                    interactionId: -1,
                    authorId: "",
                    timestampMs: 0,
                    body: "appearancePreview1".localized(),
                    attachmentId: nil
                ),
                cellType: .textOnlyMessage
            ),
            mediaCache: NSCache(),
            playbackInfo: nil,
            showExpandedReactions: false,
            lastSearchText: nil,
            using: dependencies
        )
        
        return result
    }()
    
    private lazy var outgoingMessagePreview: UIView = {
        let result: VisibleMessageCell = VisibleMessageCell()
        result.translatesAutoresizingMaskIntoConstraints = true
        result.update(
            with: MessageViewModel(
                variant: .standardOutgoing,
                body: "appearancePreview3".localized(),
                cellType: .textOnlyMessage,
                isLast: false // To hide the status indicator
            ),
            mediaCache: NSCache(),
            playbackInfo: nil,
            showExpandedReactions: false,
            lastSearchText: nil,
            using: dependencies
        )
        
        return result
    }()
    
    // MARK: - Initializtion
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        super.init(frame: .zero)
        
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Layout
    
    private func setupUI() {
        self.themeBackgroundColor = .appearance_sectionBackground
        
        addSubview(incomingMessagePreview)
        addSubview(outgoingMessagePreview)
        
        setupLayout()
    }
    
    private func setupLayout() {
        incomingMessagePreview.pin(.top, to: .top, of: self)
        incomingMessagePreview.pin(.leading, to: .leading, of: self, withInset: Values.veryLargeSpacing)
        
        outgoingMessagePreview.pin(.top, to: .bottom, of: incomingMessagePreview)
        outgoingMessagePreview.pin(.trailing, to: .trailing, of: self, withInset: -Values.veryLargeSpacing)
        outgoingMessagePreview.pin(.bottom, to: .bottom, of: self, withInset: -Values.mediumSpacing)
    }
}
