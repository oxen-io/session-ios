// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit
import SessionUtilitiesKit
import SignalUtilitiesKit

final class ReactionContainerView: UIView {
    private static let arrowSize: CGSize = CGSize(width: 15, height: 13)
    private static let arrowSpacing: CGFloat = Values.verySmallSpacing
    
    // We have explicit limits on the number of emoji which should be displayed before they
    // automatically get collapsed, these values are consistent across platforms so are set
    // here (even though the logic will automatically calculate and limit to a single line
    // of reactions dynamically for the size of the view)
    private static let numCollapsedEmoji: Int = 4
    private static let maxEmojiBeforeCollapse: Int = 6
    
    private var maxWidth: CGFloat = 0
    private var showingAllReactions: Bool = false
    private var showNumbers: Bool = true
    private var oldSize: CGSize = .zero
    
    var reactions: [ReactionViewModel] = []
    var reactionViews: [ReactionButton] = []
    
    // MARK: - UI
    
    private let dummyReactionButton: ReactionButton = ReactionButton(
        viewModel: ReactionViewModel(
            emoji: EmojiWithSkinTones(baseEmoji: .a, skinTones: nil),
            number: 0,
            showBorder: false
        )
    )
    
    private lazy var mainStackView: UIStackView = {
        let result: UIStackView = UIStackView(arrangedSubviews: [ reactionContainerView, collapseButton ])
        result.axis = .vertical
        result.spacing = Values.smallSpacing
        result.alignment = .center
        
        return result
    }()
    
    var expandButton: ExpandingReactionButton?
    
    private lazy var reactionContainerView: UIStackView = {
        let result: UIStackView = UIStackView()
        result.axis = .vertical
        result.spacing = Values.smallSpacing
        result.alignment = .leading
        
        return result
    }()
    
    lazy var collapseButton: UIView = {
        let arrow: UIImageView = UIImageView(
            image: UIImage(named: "ic_chevron_up")?
                .resizedImage(to: ReactionContainerView.arrowSize)?
                .withRenderingMode(.alwaysTemplate)
        )
        arrow.themeTintColor = .textPrimary
        arrow.setContentHuggingPriority(.required, for: .horizontal)
        
        let textLabel: UILabel = UILabel()
        textLabel.setContentHuggingPriority(.required, for: .vertical)
        textLabel.setContentHuggingPriority(.required, for: .horizontal)
        textLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        textLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        textLabel.font = .systemFont(ofSize: Values.verySmallFontSize)
        textLabel.text = "showLess".localized()
        textLabel.themeTextColor = .textPrimary
        
        let result: UIView = UIView()
        result.isHidden = true
        result.addSubview(arrow)
        result.addSubview(textLabel)
        
        arrow.pin(.top, to: .top, of: result)
        arrow.pin(.bottom, to: .bottom, of: result)
        
        textLabel.center(.horizontal, in: result, withInset: (ReactionContainerView.arrowSize.width / 2))
        textLabel.pin(.top, to: .top, of: result)
        textLabel.pin(.leading, to: .trailing, of: arrow, withInset: ReactionContainerView.arrowSpacing)
        textLabel.pin(.bottom, to: .bottom, of: result)
        
        return result
    }()
    
    // MARK: - Lifecycle
    
    init() {
        super.init(frame: CGRect.zero)
        setUpViewHierarchy()
    }
    
    override init(frame: CGRect) {
        preconditionFailure("Use init(viewItem:textColor:) instead.")
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(viewItem:textColor:) instead.")
    }
    
    private func setUpViewHierarchy() {
        addSubview(mainStackView)
        
        mainStackView.pin(.top, to: .top, of: self)
        mainStackView.pin(.leading, to: .leading, of: self)
        mainStackView.pin(.trailing, to: .trailing, of: self)
        mainStackView.pin(.bottom, to: .bottom, of: self, withInset: -Values.verySmallSpacing)
        reactionContainerView.set(.width, to: .width, of: mainStackView)
        collapseButton.set(.width, to: .width, of: mainStackView)
    }
    
    public func update(
        _ reactions: [ReactionViewModel],
        maxWidth: CGFloat,
        showingAllReactions: Bool,
        showNumbers: Bool
    ) {
        self.reactions = reactions
        self.maxWidth = maxWidth
        self.showNumbers = showNumbers
        self.reactionViews = []
        self.reactionContainerView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        
        let collapsedCount: Int = {
            // If there are already more than 'maxEmojiBeforeCollapse' then no need to calculate, just
            // always collapse
            guard reactions.count <= ReactionContainerView.maxEmojiBeforeCollapse else {
                return ReactionContainerView.numCollapsedEmoji
            }
            
            var numReactions: Int = 0
            var runningWidth: CGFloat = 0
            let estimatedExpandingButtonWidth: CGFloat = 52
            let itemSpacing: CGFloat = self.reactionContainerView.spacing
            
            for reaction in reactions {
                let reactionViewWidth: CGFloat = dummyReactionButton
                    .updating(with: reaction, showNumber: showNumbers)
                    .systemLayoutSizeFitting(CGSize(width: maxWidth, height: 9999))
                    .width
                let estimatedFullWidth: CGFloat = (
                    runningWidth +
                    (reactionViewWidth + itemSpacing) +
                    estimatedExpandingButtonWidth
                )
                
                if estimatedFullWidth >= maxWidth {
                    break
                }

                runningWidth += (reactionViewWidth + itemSpacing)
                numReactions += 1
            }
            
            return numReactions
        }()
        
        // Generate the lines of reactions (if the 'collapsedCount' matches the total number of
        // reactions then just show them app)
        if showingAllReactions || collapsedCount >= reactions.count {
            self.updateAllReactions(reactions, maxWidth: maxWidth, showNumbers: showNumbers)
        }
        else {
            self.updateCollapsedReactions(reactions, maxWidth: maxWidth, showNumbers: showNumbers, collapsedCount: collapsedCount)
        }
        
        // Just in case we couldn't show everything for some reason update this based on the
        // internal logic
        self.collapseButton.isHidden = !showingAllReactions
        self.showingAllReactions = !self.collapseButton.isHidden
        self.layoutIfNeeded()
    }
    
    private func createLineStackView() -> UIStackView {
        let result: UIStackView = UIStackView()
        result.axis = .horizontal
        result.spacing = Values.smallSpacing
        result.alignment = .center
        result.set(.height, to: ReactionButton.height)
        
        return result
    }
    
    private func updateCollapsedReactions(
        _ reactions: [ReactionViewModel],
        maxWidth: CGFloat,
        showNumbers: Bool,
        collapsedCount: Int
    ) {
        guard !reactions.isEmpty else { return }
        
        let maxSize: CGSize = CGSize(width: maxWidth, height: 9999)
        let stackView: UIStackView = createLineStackView()
        let displayedReactions: [ReactionViewModel] = Array(reactions.prefix(upTo: collapsedCount))
        let expandButtonReactions: [EmojiWithSkinTones] = reactions
            .suffix(from: collapsedCount)
            .prefix(3)
            .map { $0.emoji }
        
        for reaction in displayedReactions {
            let reactionView = ReactionButton(viewModel: reaction, showNumber: showNumbers)
            let reactionViewWidth: CGFloat = reactionView.systemLayoutSizeFitting(maxSize).width
            stackView.addArrangedSubview(reactionView)
            reactionViews.append(reactionView)
            reactionView.set(.width, to: reactionViewWidth)
        }
        
        self.expandButton = {
            guard !expandButtonReactions.isEmpty else { return nil }
                 
            let result: ExpandingReactionButton = ExpandingReactionButton(emojis: expandButtonReactions)
            stackView.addArrangedSubview(result)
            
            return result
        }()
        
        reactionContainerView.addArrangedSubview(stackView)
    }
    
    private func updateAllReactions(
        _ reactions: [ReactionViewModel],
        maxWidth: CGFloat,
        showNumbers: Bool
    ) {
        guard !reactions.isEmpty else { return }
        
        let maxSize: CGSize = CGSize(width: maxWidth, height: 9999)
        var lineStackView: UIStackView = createLineStackView()
        reactionContainerView.addArrangedSubview(lineStackView)
        
        for reaction in self.reactions {
            let reactionView: ReactionButton = ReactionButton(viewModel: reaction, showNumber: showNumbers)
            let reactionViewWidth: CGFloat = reactionView.systemLayoutSizeFitting(maxSize).width
            reactionViews.append(reactionView)
            
            // Check if we need to create a new line
            let stackViewWidth: CGFloat = (lineStackView.arrangedSubviews.isEmpty ?
                0 :
                lineStackView.systemLayoutSizeFitting(maxSize).width
            )
            
            if stackViewWidth + reactionViewWidth > maxWidth {
                lineStackView = createLineStackView()
                reactionContainerView.addArrangedSubview(lineStackView)
            }
            
            lineStackView.addArrangedSubview(reactionView)
            reactionView.set(.width, to: reactionViewWidth)
        }
    }
    
    public func showAllEmojis() {
        guard !showingAllReactions else { return }
        
        update(reactions, maxWidth: maxWidth, showingAllReactions: true, showNumbers: showNumbers)
    }
    
    public func showLessEmojis() {
        guard showingAllReactions else { return }
        
        update(reactions, maxWidth: maxWidth, showingAllReactions: false, showNumbers: showNumbers)
    }
}
