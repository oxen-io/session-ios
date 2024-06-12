// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import NVActivityIndicatorView
import SessionMessagingKit
import SessionUIKit
import SessionSnodeKit
import SessionUtilitiesKit

final class PathVC: BaseVC {
    public static let dotSize: CGFloat = 8
    public static let expandedDotSize: CGFloat = 16
    private static let rowHeight: CGFloat = (isIPhone5OrSmaller ? 52 : 75)
    
    private var pathUpdateId: UUID?
    private var cacheUpdateId: UUID?
    private var lastPath: [LibSession.Snode] = []

    // MARK: - Components
    
    private lazy var pathStackView: UIStackView = {
        let result = UIStackView()
        result.axis = .vertical
        
        return result
    }()

    private let spinner: NVActivityIndicatorView = {
        let result: NVActivityIndicatorView = NVActivityIndicatorView(
            frame: CGRect.zero,
            type: .circleStrokeSpin,
            color: .black,
            padding: nil
        )
        result.set(.width, to: 64)
        result.set(.height, to: 64)
        
        ThemeManager.onThemeChange(observer: result) { [weak result] theme, _ in
            guard let textPrimary: UIColor = theme.color(for: .textPrimary) else { return }
            
            result?.color = textPrimary
        }
        
        return result
    }()

    private lazy var learnMoreButton: SessionButton = {
        let result = SessionButton(style: .bordered, size: .large)
        result.setTitle("vc_path_learn_more_button_title".localized(), for: UIControl.State.normal)
        result.addTarget(self, action: #selector(learnMore), for: UIControl.Event.touchUpInside)
        
        return result
    }()

    // MARK: - Lifecycle
    
    deinit {
        LibSession.removeNetworkChangedCallback(callbackId: pathUpdateId)
        IP2Country.removeCacheLoadedCallback(id: cacheUpdateId)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setUpNavBar()
        setUpViewHierarchy()
    }

    private func setUpNavBar() {
        setNavBarTitle("vc_path_title".localized())
    }

    private func setUpViewHierarchy() {
        // Set up explanation label
        let explanationLabel = UILabel()
        explanationLabel.font = .systemFont(ofSize: Values.smallFontSize)
        explanationLabel.text = "vc_path_explanation".localized()
        explanationLabel.themeTextColor = .textSecondary
        explanationLabel.textAlignment = .center
        explanationLabel.lineBreakMode = .byWordWrapping
        explanationLabel.numberOfLines = 0
        
        // Set up path stack view
        let pathStackViewContainer = UIView()
        pathStackViewContainer.addSubview(pathStackView)
        pathStackView.pin([ UIView.VerticalEdge.top, UIView.VerticalEdge.bottom ], to: pathStackViewContainer)
        pathStackView.center(in: pathStackViewContainer)
        pathStackView.leadingAnchor.constraint(greaterThanOrEqualTo: pathStackViewContainer.leadingAnchor).isActive = true
        pathStackViewContainer.trailingAnchor.constraint(greaterThanOrEqualTo: pathStackView.trailingAnchor).isActive = true
        pathStackViewContainer.addSubview(spinner)
        spinner.leadingAnchor.constraint(greaterThanOrEqualTo: pathStackViewContainer.leadingAnchor).isActive = true
        spinner.topAnchor.constraint(greaterThanOrEqualTo: pathStackViewContainer.topAnchor).isActive = true
        pathStackViewContainer.trailingAnchor.constraint(greaterThanOrEqualTo: spinner.trailingAnchor).isActive = true
        pathStackViewContainer.bottomAnchor.constraint(greaterThanOrEqualTo: spinner.bottomAnchor).isActive = true
        spinner.center(in: pathStackViewContainer)
        
        // Set up rebuild path button
        let inset: CGFloat = isIPhone5OrSmaller ? 64 : 80
        let learnMoreButtonContainer = UIView(wrapping: learnMoreButton, withInsets: UIEdgeInsets(top: 0, leading: inset, bottom: 0, trailing: inset), shouldAdaptForIPadWithWidth: Values.iPadButtonWidth)
        
        // Set up spacers
        let topSpacer = UIView.vStretchingSpacer()
        let bottomSpacer = UIView.vStretchingSpacer()
        
        // Set up main stack view
        let mainStackView = UIStackView(arrangedSubviews: [ explanationLabel, topSpacer, pathStackViewContainer, bottomSpacer, learnMoreButtonContainer ])
        mainStackView.axis = .vertical
        mainStackView.alignment = .fill
        mainStackView.layoutMargins = UIEdgeInsets(
            top: Values.largeSpacing,
            left: Values.largeSpacing,
            bottom: Values.smallSpacing,
            right: Values.largeSpacing
        )
        mainStackView.isLayoutMarginsRelativeArrangement = true
        view.addSubview(mainStackView)
        mainStackView.pin(to: view)
        
        // Set up spacer constraints
        topSpacer.heightAnchor.constraint(equalTo: bottomSpacer.heightAnchor).isActive = true
        
        // Register for status updates (will be called immediately with current paths)
        pathUpdateId = LibSession.onPathsChanged { [weak self] paths, _ in
            DispatchQueue.main.async {
                self?.update(paths: paths, force: false)
            }
        }
        
        // Register for path country updates
        cacheUpdateId = IP2Country.onCacheLoaded { [weak self] in
            DispatchQueue.main.async {
                self?.update(paths: (self?.lastPath.map { [$0] } ?? []), force: true)
            }
        }
    }

    // MARK: - Updating
    
    private func update(paths: [[LibSession.Snode]], force: Bool) {
        guard let pathToDisplay: [LibSession.Snode] = paths.first else {
            pathStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
            spinner.startAnimating()
            
            UIView.animate(withDuration: 0.25) {
                self.spinner.alpha = 1
            }
            return
        }
        guard force || lastPath != pathToDisplay else { return }
        
        // Cache the path that was used to avoid recreating the UI if not needed
        lastPath = pathToDisplay
        pathStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        
        let dotAnimationRepeatInterval = Double(pathToDisplay.count) + 2
        let snodeRows: [UIStackView] = pathToDisplay.enumerated().map { index, snode in
            let isGuardSnode = (snode == pathToDisplay.first)
            
            return getPathRow(
                snode: snode,
                location: .middle,
                dotAnimationStartDelay: Double(index) + 2,
                dotAnimationRepeatInterval: dotAnimationRepeatInterval,
                isGuardSnode: isGuardSnode
            )
        }
        
        let youRow = getPathRow(
            title: "vc_path_device_row_title".localized(),
            subtitle: nil,
            location: .top,
            dotAnimationStartDelay: 1,
            dotAnimationRepeatInterval: dotAnimationRepeatInterval
        )
        let destinationRow = getPathRow(
            title: "vc_path_destination_row_title".localized(),
            subtitle: nil,
            location: .bottom,
            dotAnimationStartDelay: Double(pathToDisplay.count) + 2,
            dotAnimationRepeatInterval: dotAnimationRepeatInterval
        )
        let rows = [ youRow ] + snodeRows + [ destinationRow ]
        rows.forEach { pathStackView.addArrangedSubview($0) }
        spinner.stopAnimating()
        
        UIView.animate(withDuration: 0.25) {
            self.spinner.alpha = 0
        }
    }

    // MARK: - General
    
    private func getPathRow(title: String, subtitle: String?, location: LineView.Location, dotAnimationStartDelay: Double, dotAnimationRepeatInterval: Double) -> UIStackView {
        let lineView = LineView(
            location: location,
            dotAnimationStartDelay: dotAnimationStartDelay,
            dotAnimationRepeatInterval: dotAnimationRepeatInterval
        )
        lineView.set(.width, to: PathVC.expandedDotSize)
        lineView.set(.height, to: PathVC.rowHeight)
        
        let titleLabel: UILabel = UILabel()
        titleLabel.font = .systemFont(ofSize: Values.mediumFontSize)
        titleLabel.text = title
        titleLabel.themeTextColor = .textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        
        let titleStackView = UIStackView(arrangedSubviews: [ titleLabel ])
        titleStackView.axis = .vertical
        
        if let subtitle = subtitle {
            let subtitleLabel = UILabel()
            subtitleLabel.font = .systemFont(ofSize: Values.verySmallFontSize)
            subtitleLabel.text = subtitle
            subtitleLabel.themeTextColor = .textPrimary
            subtitleLabel.lineBreakMode = .byTruncatingTail
            titleStackView.addArrangedSubview(subtitleLabel)
        }
        
        let stackView = UIStackView(arrangedSubviews: [ lineView, titleStackView ])
        stackView.axis = .horizontal
        stackView.spacing = Values.largeSpacing
        stackView.alignment = .center
        
        return stackView
    }

    private func getPathRow(snode: LibSession.Snode, location: LineView.Location, dotAnimationStartDelay: Double, dotAnimationRepeatInterval: Double, isGuardSnode: Bool) -> UIStackView {
        let country: String = (IP2Country.isInitialized.wrappedValue ?
            IP2Country.countryNamesCache.wrappedValue[snode.ip].defaulting(to: "Resolving...") :
            "Resolving..."
        )
        
        return getPathRow(
            title: (isGuardSnode ?
                "vc_path_guard_node_row_title".localized() :
                "vc_path_service_node_row_title".localized()
            ),
            subtitle: country,
            location: location,
            dotAnimationStartDelay: dotAnimationStartDelay,
            dotAnimationRepeatInterval: dotAnimationRepeatInterval
        )
    }
    
    // MARK: - Interaction
    
    @objc private func learnMore() {
        let urlAsString = "https://getsession.org/faq/#onion-routing"
        let url = URL(string: urlAsString)!
        UIApplication.shared.open(url)
    }
}

// MARK: - Line View

private final class LineView: UIView {
    private let location: Location
    private let dotAnimationStartDelay: Double
    private let dotAnimationRepeatInterval: Double
    private var dotViewWidthConstraint: NSLayoutConstraint!
    private var dotViewHeightConstraint: NSLayoutConstraint!
    private var dotViewAnimationTimer: Timer!
    private var networkStatusCallbackId: UUID?

    enum Location {
        case top, middle, bottom
    }

    private lazy var dotView: UIView = {
        let result = UIView()
        result.themeBackgroundColor = .path_connected
        result.layer.themeShadowColor = .path_connected
        result.layer.shadowOffset = .zero
        result.layer.shadowPath = UIBezierPath(
            ovalIn: CGRect(
                origin: CGPoint.zero,
                size: CGSize(width: PathVC.dotSize, height: PathVC.dotSize)
            )
        ).cgPath
        result.layer.cornerRadius = (PathVC.dotSize / 2)
        
        ThemeManager.onThemeChange(observer: result) { [weak result] theme, _ in
            result?.layer.shadowOpacity = (theme.interfaceStyle == .light ? 0.4 : 1)
            result?.layer.shadowRadius = (theme.interfaceStyle == .light ? 1 : 2)
        }
        
        return result
    }()
    
    init(location: Location, dotAnimationStartDelay: Double, dotAnimationRepeatInterval: Double) {
        self.location = location
        self.dotAnimationStartDelay = dotAnimationStartDelay
        self.dotAnimationRepeatInterval = dotAnimationRepeatInterval
        
        super.init(frame: CGRect.zero)
        
        setUpViewHierarchy()
        registerObservers()
    }
    
    override init(frame: CGRect) {
        preconditionFailure("Use init(location:dotAnimationStartDelay:dotAnimationRepeatInterval:) instead.")
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(location:dotAnimationStartDelay:dotAnimationRepeatInterval:) instead.")
    }
    
    deinit {
        LibSession.removeNetworkChangedCallback(callbackId: networkStatusCallbackId)
        dotViewAnimationTimer?.invalidate()
    }
    
    private func setUpViewHierarchy() {
        let lineView = UIView()
        lineView.set(.width, to: Values.separatorThickness)
        lineView.themeBackgroundColor = .textPrimary
        addSubview(lineView)
        
        lineView.center(.horizontal, in: self)
        
        switch location {
            case .top: lineView.topAnchor.constraint(equalTo: centerYAnchor).isActive = true
            case .middle, .bottom: lineView.pin(.top, to: .top, of: self)
        }
        
        switch location {
            case .top, .middle: lineView.pin(.bottom, to: .bottom, of: self)
            case .bottom: lineView.bottomAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        
        let dotSize = PathVC.dotSize
        dotViewWidthConstraint = dotView.set(.width, to: dotSize)
        dotViewHeightConstraint = dotView.set(.height, to: dotSize)
        addSubview(dotView)
        
        dotView.center(in: self)
        
        let repeatInterval: TimeInterval = self.dotAnimationRepeatInterval
        Timer.scheduledTimer(withTimeInterval: dotAnimationStartDelay, repeats: false) { [weak self] _ in
            self?.animate()
            self?.dotViewAnimationTimer = Timer.scheduledTimer(withTimeInterval: repeatInterval, repeats: true) { _ in
                self?.animate()
            }
        }
    }
    
    private func registerObservers() {
        // Register for status updates (will be called immediately with current status)
        networkStatusCallbackId = LibSession.onNetworkStatusChanged { [weak self] status in
            DispatchQueue.main.async {
                self?.setStatus(to: status)
            }
        }
    }

    private func animate() {
        expandDot()
        
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            self?.collapseDot()
        }
    }

    private func expandDot() {
        UIView.animate(withDuration: 0.5) { [weak self] in
            self?.dotView.transform = CGAffineTransform.scale(PathVC.expandedDotSize / PathVC.dotSize)
        }
    }

    private func collapseDot() {
        UIView.animate(withDuration: 0.5) { [weak self] in
            self?.dotView.transform = CGAffineTransform.scale(1)
        }
    }
    
    private func setStatus(to status: LibSession.NetworkStatus) {
        dotView.themeBackgroundColor = status.themeColor
        dotView.layer.themeShadowColor = status.themeColor
    }
}
