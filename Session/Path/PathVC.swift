// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import NVActivityIndicatorView
import SessionMessagingKit
import SessionUIKit
import SessionSnodeKit
import SessionUtilitiesKit

final class PathVC: BaseVC {
    public static let dotSize: CGFloat = 8
    public static let expandedDotSize: CGFloat = 16
    private static let rowHeight: CGFloat = (isIPhone5OrSmaller ? 52 : 75)
    
    private let dependencies: Dependencies
    private var lastPath: [LibSession.Snode] = []
    private var disposables: Set<AnyCancellable> = Set()

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
        result.setTitle("learnMore".localized(), for: UIControl.State.normal)
        result.addTarget(self, action: #selector(learnMore), for: UIControl.Event.touchUpInside)
        
        return result
    }()

    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setUpNavBar()
        setUpViewHierarchy()
    }

    private func setUpNavBar() {
        setNavBarTitle("onionRoutingPath".localized())
    }

    private func setUpViewHierarchy() {
        // Set up explanation label
        let explanationLabel = UILabel()
        explanationLabel.font = .systemFont(ofSize: Values.smallFontSize)
        explanationLabel.text = "onionRoutingPathDescription"
            .put(key: "app_name", value: Constants.app_name)
            .localized()
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
        
        // Register for path country updates
        dependencies[cache: .ip2Country].cacheLoaded
            .receive(on: DispatchQueue.main, using: dependencies)
            .sink(receiveValue: { [weak self] _ in
                switch (self?.lastPath, self?.lastPath.isEmpty == true) {
                    case (.none, _), (_, true): self?.update(paths: [], force: true)
                    case (.some(let lastPath), _): self?.update(paths: [lastPath], force: true)
                }
            })
            .store(in: &disposables)
        
        // Register for network updates
        registerNetworkObservables()
    }

    // MARK: - Updating
    
    private func registerNetworkObservables() {
        /// Register for status updates (will be called immediately with current paths)
        dependencies[cache: .libSessionNetwork].paths
            .subscribe(on: DispatchQueue.global(qos: .background), using: dependencies)
            .receive(on: DispatchQueue.main, using: dependencies)
            .sink(
                receiveCompletion: { [weak self] _ in
                    /// If the stream completes it means the network cache was reset in which case we want to
                    /// re-register for updates in the next run loop (as the new cache should be created by then)
                    DispatchQueue.global(qos: .background).async {
                        self?.registerNetworkObservables()
                    }
                },
                receiveValue: { [weak self] paths in self?.update(paths: paths, force: false) }
            )
            .store(in: &disposables)
    }
    
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
            title: "you".localized(),
            subtitle: nil,
            location: .top,
            dotAnimationStartDelay: 1,
            dotAnimationRepeatInterval: dotAnimationRepeatInterval
        )
        let destinationRow = getPathRow(
            title: "onionRoutingPathDestination".localized(),
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
            dotAnimationRepeatInterval: dotAnimationRepeatInterval,
            using: dependencies
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
        return getPathRow(
            title: (isGuardSnode ?
                "onionRoutingPathEntryNode".localized() :
                "onionRoutingPathServiceNode".localized()
            ),
            subtitle: dependencies[cache: .ip2Country].country(for: snode.ip),
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
    private var disposables: Set<AnyCancellable> = Set()

    enum Location {
        case top, middle, bottom
    }
    
    // MARK: - Initialization
    
    init(location: Location, dotAnimationStartDelay: Double, dotAnimationRepeatInterval: Double, using dependencies: Dependencies) {
        self.location = location
        self.dotAnimationStartDelay = dotAnimationStartDelay
        self.dotAnimationRepeatInterval = dotAnimationRepeatInterval
        
        super.init(frame: CGRect.zero)
        
        setUpViewHierarchy()
        registerObservers(using: dependencies)
    }
    
    override init(frame: CGRect) {
        preconditionFailure("Use init(location:dotAnimationStartDelay:dotAnimationRepeatInterval:) instead.")
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(location:dotAnimationStartDelay:dotAnimationRepeatInterval:) instead.")
    }
    
    deinit {
        dotViewAnimationTimer?.invalidate()
    }
    
    // MARK: - Components
    
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
    
    // MARK: - Layout
    
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
    
    private func registerObservers(using dependencies: Dependencies) {
        /// Register for status updates (will be called immediately with current status)
        dependencies[cache: .libSessionNetwork].networkStatus
            .receive(on: DispatchQueue.main, using: dependencies)
            .sink(
                receiveCompletion: { [weak self] _ in
                    /// If the stream completes it means the network cache was reset in which case we want to
                    /// re-register for updates in the next run loop (as the new cache should be created by then)
                    DispatchQueue.global(qos: .background).async {
                        self?.registerObservers(using: dependencies)
                    }
                },
                receiveValue: { [weak self] status in self?.setStatus(to: status) }
            )
            .store(in: &disposables)
    }

    private func animate() {
        expandDot()
        
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            self?.collapseDot()
        }
    }

    private func expandDot() {
        UIView.animate(withDuration: 0.5) { [weak self] in
            self?.dotView.transform = CGAffineTransform(
                scaleX: PathVC.expandedDotSize / PathVC.dotSize,
                y: PathVC.expandedDotSize / PathVC.dotSize
            )
        }
    }

    private func collapseDot() {
        UIView.animate(withDuration: 0.5) { [weak self] in
            self?.dotView.transform = CGAffineTransform(scaleX: 1, y: 1)
        }
    }
    
    private func setStatus(to status: NetworkStatus) {
        dotView.themeBackgroundColor = status.themeColor
        dotView.layer.themeShadowColor = status.themeColor
    }
}
