// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

public final class HomeVC: BaseVC, LibSessionRespondingViewController, UITableViewDataSource, UITableViewDelegate, SeedReminderViewDelegate {
    private static let loadingHeaderHeight: CGFloat = 40
    public static let newConversationButtonSize: CGFloat = 60
    
    private let viewModel: HomeViewModel
    private var dataChangeObservable: DatabaseCancellable? {
        didSet { oldValue?.cancel() }   // Cancel the old observable if there was one
    }
    private var hasLoadedInitialStateData: Bool = false
    private var hasLoadedInitialThreadData: Bool = false
    private var isLoadingMore: Bool = false
    private var isAutoLoadingNextPage: Bool = false
    private var viewHasAppeared: Bool = false
    private var flow: Onboarding.Flow?
    
    // MARK: - LibSessionRespondingViewController
    
    public let isConversationList: Bool = true
    
    // MARK: - Intialization
    
    init(using dependencies: Dependencies) {
        self.viewModel = HomeViewModel(using: dependencies)
        
        dependencies[singleton: .storage].addObserver(viewModel.pagedDataObserver)
        
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        preconditionFailure("Use init() instead.")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - UI
    
    private var tableViewTopConstraint: NSLayoutConstraint!
    private var loadingConversationsLabelTopConstraint: NSLayoutConstraint!
    private var navBarProfileView: ProfilePictureView?
    
    private lazy var seedReminderView: SeedReminderView = {
        let result = SeedReminderView()
        result.accessibilityLabel = "Recovery phrase reminder"
        result.title = NSAttributedString(string: "recoveryPasswordBannerTitle".localized())
        result.subtitle = "recoveryPasswordBannerDescription".localized()
        result.setProgress(1, animated: false)
        result.delegate = self
        result.isHidden = !self.viewModel.state.showViewedSeedBanner
        
        return result
    }()
    
    private lazy var loadingConversationsLabel: UILabel = {
        let result: UILabel = UILabel()
        result.translatesAutoresizingMaskIntoConstraints = false
        result.font = .systemFont(ofSize: Values.smallFontSize)
        result.text = "loading".localized()
        result.themeTextColor = .textSecondary
        result.textAlignment = .center
        result.numberOfLines = 0
        
        return result
    }()
        
    private lazy var tableView: UITableView = {
        let result = UITableView()
        result.separatorStyle = .none
        result.themeBackgroundColor = .clear
        result.contentInset = UIEdgeInsets(
            top: 0,
            left: 0,
            bottom: (
                Values.largeSpacing +
                HomeVC.newConversationButtonSize +
                Values.smallSpacing +
                (UIApplication.shared.keyWindow?.safeAreaInsets.bottom ?? 0)
            ),
            right: 0
        )
        result.showsVerticalScrollIndicator = false
        result.register(view: MessageRequestsCell.self)
        result.register(view: FullConversationCell.self)
        result.dataSource = self
        result.delegate = self
        result.sectionHeaderTopPadding = 0

        return result
    }()
    
    private lazy var newConversationButton: UIView = {
        let result: UIView = UIView()
        result.set(.width, to: HomeVC.newConversationButtonSize)
        result.set(.height, to: HomeVC.newConversationButtonSize)
        
        let button = UIButton()
        button.accessibilityLabel = "New conversation button"
        button.isAccessibilityElement = true
        button.clipsToBounds = true
        button.setImage(
            UIImage(named: "Plus")?
                .withRenderingMode(.alwaysTemplate),
            for: .normal
        )
        button.contentMode = .center
        button.adjustsImageWhenHighlighted = false
        button.themeTintColor = .menuButton_icon
        button.setThemeBackgroundColor(.menuButton_background, for: .normal)
        button.setThemeBackgroundColor(
            .highlighted(.menuButton_background, alwaysDarken: true),
            for: .highlighted
        )
        button.contentEdgeInsets = UIEdgeInsets(
            top: ((HomeVC.newConversationButtonSize - 24) / 2),
            leading: ((HomeVC.newConversationButtonSize - 24) / 2),
            bottom: ((HomeVC.newConversationButtonSize - 24) / 2),
            trailing: ((HomeVC.newConversationButtonSize - 24) / 2)
        )
        button.layer.cornerRadius = (HomeVC.newConversationButtonSize / 2)
        button.addTarget(self, action: #selector(createNewConversation), for: .touchUpInside)
        result.addSubview(button)
        button.pin(to: result)
        
        // Add the outer shadow
        result.themeShadowColor = .menuButton_outerShadow
        result.layer.shadowRadius = 15
        result.layer.shadowOpacity = 0.3
        result.layer.shadowOffset = .zero
        result.layer.cornerRadius = (HomeVC.newConversationButtonSize / 2)
        result.layer.shadowPath = UIBezierPath(
            ovalIn: CGRect(
                origin: CGPoint.zero,
                size: CGSize(
                    width: HomeVC.newConversationButtonSize,
                    height: HomeVC.newConversationButtonSize
                )
            )
        ).cgPath
        
        // Add the inner shadow
        let innerShadowLayer: CALayer = CALayer()
        innerShadowLayer.masksToBounds = true
        innerShadowLayer.themeShadowColor = .menuButton_innerShadow
        innerShadowLayer.position = CGPoint(
            x: (HomeVC.newConversationButtonSize / 2),
            y: (HomeVC.newConversationButtonSize / 2)
        )
        innerShadowLayer.bounds = CGRect(
            x: 0,
            y: 0,
            width: HomeVC.newConversationButtonSize,
            height: HomeVC.newConversationButtonSize
        )
        innerShadowLayer.cornerRadius = (HomeVC.newConversationButtonSize / 2)
        innerShadowLayer.shadowOffset = .zero
        innerShadowLayer.shadowOpacity = 0.4
        innerShadowLayer.shadowRadius = 2

        let cutout: UIBezierPath = UIBezierPath(
            roundedRect: innerShadowLayer.bounds
                .insetBy(dx: innerShadowLayer.shadowRadius, dy: innerShadowLayer.shadowRadius),
            cornerRadius: (HomeVC.newConversationButtonSize / 2)
        ).reversing()
        let path: UIBezierPath = UIBezierPath(
            roundedRect: innerShadowLayer.bounds,
            cornerRadius: (HomeVC.newConversationButtonSize / 2)
        )
        path.append(cutout)
        innerShadowLayer.shadowPath = path.cgPath
        result.layer.addSublayer(innerShadowLayer)

        return result
    }()
    
    private lazy var emptyStateView: UIView = {
        let emptyConvoLabel = UILabel()
        emptyConvoLabel.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        emptyConvoLabel.text = "conversationsNone".localized()
        emptyConvoLabel.themeTextColor = .textPrimary
        emptyConvoLabel.textAlignment = .center
        
        let instructionLabel = UILabel()
        instructionLabel.font = .systemFont(ofSize: Values.verySmallFontSize)
        instructionLabel.text = "onboardingHitThePlusButton".localized()
        instructionLabel.themeTextColor = .textPrimary
        instructionLabel.textAlignment = .center
        instructionLabel.lineBreakMode = .byWordWrapping
        instructionLabel.numberOfLines = 0
        
        let result = UIStackView(arrangedSubviews: [ 
            emptyConvoLabel,
            UIView.vSpacer(Values.smallSpacing),
            instructionLabel
        ])
        result.axis = .vertical
        result.spacing = Values.verySmallSpacing
        result.alignment = .center
        
        return result
    }()
    
    private lazy var emptyStateLogoView: UIView = {
        let sessionLogoImage: UIImageView = UIImageView(image: UIImage(named: "SessionGreen64"))
        sessionLogoImage.contentMode = .scaleAspectFit
        sessionLogoImage.set(.height, to: 103)
        
        let sessionTitleImage: UIImageView = UIImageView(
            image: UIImage(named: "SessionHeading")?
                .withRenderingMode(.alwaysTemplate)
        )
        sessionTitleImage.themeTintColor = .textPrimary
        sessionTitleImage.contentMode = .scaleAspectFit
        sessionTitleImage.set(.height, to: 22)
        
        let result = UIStackView(arrangedSubviews: [
            sessionLogoImage,
            UIView.vSpacer(Values.smallSpacing + Values.verySmallSpacing),
            sessionTitleImage,
            UIView.vSpacer(Values.verySmallSpacing)
        ])
        result.axis = .vertical
        result.spacing = Values.verySmallSpacing
        result.alignment = .fill
        result.isHidden = true
        
        return result
    }()
    
    private lazy var accountCreatedView: UIView = {
        let image: UIImageView = UIImageView(image: UIImage(named: "Hooray"))
        image.contentMode = .center
        image.set(.height, to: 96)
        
        let accountCreatedLabel = UILabel()
        accountCreatedLabel.font = .boldSystemFont(ofSize: Values.veryLargeFontSize)
        accountCreatedLabel.text = "onboardingAccountCreated".localized()
        accountCreatedLabel.themeTextColor = .textPrimary
        accountCreatedLabel.textAlignment = .center
        
        let welcomeLabel = UILabel()
        welcomeLabel.font = .systemFont(ofSize: Values.smallFontSize)
        welcomeLabel.text = "onboardingBubbleWelcomeToSession"
            .put(key: "app_name", value: Constants.app_name)
            .put(key: "emoji", value: "")
            .localized()
        welcomeLabel.themeTextColor = .sessionButton_text
        welcomeLabel.textAlignment = .center

        let result = UIStackView(arrangedSubviews: [
            image,
            accountCreatedLabel,
            welcomeLabel,
            UIView.vSpacer(Values.verySmallSpacing)
        ])
        result.axis = .vertical
        result.spacing = Values.verySmallSpacing
        result.alignment = .fill
        result.isHidden = true
        
        return result
    }()
    
    private lazy var emptyStateStackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [
            accountCreatedView,
            emptyStateLogoView,
            UIView.vSpacer(Values.smallSpacing),
            UIView.line(),
            UIView.vSpacer(Values.smallSpacing),
            emptyStateView
        ])
        result.axis = .vertical
        result.spacing = Values.verySmallSpacing
        result.alignment = .fill
        result.isHidden = true
        
        return result
    }()
    
    // MARK: - Lifecycle
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        
        // Preparation
        updateNavBarButtons(userProfile: self.viewModel.state.userProfile)
        setUpNavBarSessionHeading()
        
        // Recovery phrase reminder
        view.addSubview(seedReminderView)
        seedReminderView.pin(.leading, to: .leading, of: view)
        seedReminderView.pin(.top, to: .top, of: view)
        seedReminderView.pin(.trailing, to: .trailing, of: view)
        
        // Loading conversations label
        view.addSubview(loadingConversationsLabel)
        
        loadingConversationsLabel.pin(.leading, to: .leading, of: view, withInset: 50)
        loadingConversationsLabel.pin(.trailing, to: .trailing, of: view, withInset: -50)
        
        // Table view
        view.addSubview(tableView)
        tableView.pin(.leading, to: .leading, of: view)
        tableView.pin(.trailing, to: .trailing, of: view)
        tableView.pin(.bottom, to: .bottom, of: view)
        
        if self.viewModel.state.showViewedSeedBanner {
            loadingConversationsLabelTopConstraint = loadingConversationsLabel.pin(.top, to: .bottom, of: seedReminderView, withInset: Values.mediumSpacing)
            tableViewTopConstraint = tableView.pin(.top, to: .bottom, of: seedReminderView)
        }
        else {
            loadingConversationsLabelTopConstraint = loadingConversationsLabel.pin(.top, to: .top, of: view, withInset: Values.veryLargeSpacing)
            tableViewTopConstraint = tableView.pin(.top, to: .top, of: view)
        }
        
        // Empty state view
        view.addSubview(emptyStateStackView)
        emptyStateStackView.set(.width, to: 300)
        emptyStateStackView.center(.horizontal, in: view)
        let verticalCenteringConstraint2 = emptyStateStackView.center(.vertical, in: view)
        verticalCenteringConstraint2.constant = -Values.massiveSpacing // Makes things appear centered visually
        
        // New conversation button
        view.addSubview(newConversationButton)
        newConversationButton.center(.horizontal, in: view)
        newConversationButton.pin(.bottom, to: .bottom, of: view.safeAreaLayoutGuide, withInset: -Values.smallSpacing)
        
        // Notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive(_:)),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        
        // Start polling if needed (i.e. if the user just created or restored their Session ID)
        if Identity.userExists(using: viewModel.dependencies), let appDelegate: AppDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.startPollersIfNeeded()
        }
        
        // Onion request path countries cache
        viewModel.dependencies.warmCache(cache: .ip2Country)
    }
    
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        startObservingChanges()
    }
    
    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        self.viewHasAppeared = true
        self.autoLoadNextPageIfNeeded()
    }
    
    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        stopObservingChanges()
    }
    
    @objc func applicationDidBecomeActive(_ notification: Notification) {
        /// Need to dispatch to the next run loop to prevent a possible crash caused by the database resuming mid-query
        DispatchQueue.main.async { [weak self] in
            self?.startObservingChanges(didReturnFromBackground: true)
        }
    }
    
    @objc func applicationDidResignActive(_ notification: Notification) {
        stopObservingChanges()
    }
    
    // MARK: - Updating
    
    public func startObservingChanges(didReturnFromBackground: Bool = false, onReceivedInitialChange: (() -> ())? = nil) {
        guard dataChangeObservable == nil else { return }
        
        var runAndClearInitialChangeCallback: (() -> ())? = nil
        
        runAndClearInitialChangeCallback = { [weak self] in
            guard self?.hasLoadedInitialStateData == true && self?.hasLoadedInitialThreadData == true else { return }
            
            onReceivedInitialChange?()
            runAndClearInitialChangeCallback = nil
        }
        
        dataChangeObservable = viewModel.dependencies[singleton: .storage].start(
            viewModel.observableState,
            onError: { _ in },
            onChange: { [weak self] state in
                // The default scheduler emits changes on the main thread
                self?.handleUpdates(state)
                runAndClearInitialChangeCallback?()
            }
        )
        
        self.viewModel.onThreadChange = { [weak self] updatedThreadData, changeset in
            self?.handleThreadUpdates(updatedThreadData, changeset: changeset)
            runAndClearInitialChangeCallback?()
        }
        
        // Note: When returning from the background we could have received notifications but the
        // PagedDatabaseObserver won't have them so we need to force a re-fetch of the current
        // data to ensure everything is up to date
        if didReturnFromBackground {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.viewModel.pagedDataObserver?.reload()
            }
        }
    }
    
    private func stopObservingChanges() {
        // Stop observing database changes
        self.dataChangeObservable = nil
        self.viewModel.onThreadChange = nil
    }
    
    private func handleUpdates(_ updatedState: HomeViewModel.State, initialLoad: Bool = false) {
        // Ensure the first load runs without animations (if we don't do this the cells will animate
        // in from a frame of CGRect.zero)
        guard hasLoadedInitialStateData else {
            hasLoadedInitialStateData = true
            UIView.performWithoutAnimation { handleUpdates(updatedState, initialLoad: true) }
            return
        }
        
        if updatedState.userProfile != self.viewModel.state.userProfile {
            updateNavBarButtons(userProfile: updatedState.userProfile)
        }
        
        // Update the 'view seed' UI
        if updatedState.showViewedSeedBanner != self.viewModel.state.showViewedSeedBanner {
            tableViewTopConstraint.isActive = false
            loadingConversationsLabelTopConstraint.isActive = false
            seedReminderView.isHidden = !updatedState.showViewedSeedBanner

            if updatedState.showViewedSeedBanner {
                loadingConversationsLabelTopConstraint = loadingConversationsLabel.pin(.top, to: .bottom, of: seedReminderView, withInset: Values.mediumSpacing)
                tableViewTopConstraint = tableView.pin(.top, to: .bottom, of: seedReminderView)
            }
            else {
                loadingConversationsLabelTopConstraint = loadingConversationsLabel.pin(.top, to: .top, of: view, withInset: Values.veryLargeSpacing)
                tableViewTopConstraint = tableView.pin(.top, to: .top, of: view, withInset: Values.smallSpacing)
            }
        }
        
        self.viewModel.updateState(updatedState)
    }
    
    private func handleThreadUpdates(
        _ updatedData: [HomeViewModel.SectionModel],
        changeset: StagedChangeset<[HomeViewModel.SectionModel]>,
        initialLoad: Bool = false
    ) {
        // Ensure the first load runs without animations (if we don't do this the cells will animate
        // in from a frame of CGRect.zero)
        guard hasLoadedInitialThreadData else {
            UIView.performWithoutAnimation { [weak self] in
                // Hide the 'loading conversations' label (now that we have received conversation data)
                self?.loadingConversationsLabel.isHidden = true
                
                // Show the empty state if there is no data
                self?.accountCreatedView.isHidden = (self?.flow != .register)
                self?.emptyStateLogoView.isHidden = (self?.flow == .register)
                self?.emptyStateStackView.isHidden = (
                    !updatedData.isEmpty &&
                    updatedData.contains(where: { !$0.elements.isEmpty })
                )
                
                self?.viewModel.updateThreadData(updatedData)
                self?.tableView.reloadData()
                self?.hasLoadedInitialThreadData = true
            }
            return
        }
        
        // Hide the 'loading conversations' label (now that we have received conversation data)
        loadingConversationsLabel.isHidden = true
        
        // Show the empty state if there is no data
        if self.flow == .register {
            accountCreatedView.isHidden = false
            emptyStateLogoView.isHidden = true
        } else {
            accountCreatedView.isHidden = true
            emptyStateLogoView.isHidden = false
        }
        
        emptyStateStackView.isHidden = (
            !updatedData.isEmpty &&
            updatedData.contains(where: { !$0.elements.isEmpty })
        )
        
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            // Complete page loading
            self?.isLoadingMore = false
            self?.autoLoadNextPageIfNeeded()
        }
        
        // Reload the table content (animate changes after the first load)
        tableView.reload(
            using: changeset,
            deleteSectionsAnimation: .none,
            insertSectionsAnimation: .none,
            reloadSectionsAnimation: .none,
            deleteRowsAnimation: .bottom,
            insertRowsAnimation: .none,
            reloadRowsAnimation: .none,
            interrupt: { $0.changeCount > 100 }    // Prevent too many changes from causing performance issues
        ) { [weak self] updatedData in
            self?.viewModel.updateThreadData(updatedData)
        }
        
        CATransaction.commit()
    }
    
    private func autoLoadNextPageIfNeeded() {
        guard
            self.hasLoadedInitialThreadData &&
            !self.isAutoLoadingNextPage &&
            !self.isLoadingMore
        else { return }
        
        self.isAutoLoadingNextPage = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + PagedData.autoLoadNextPageDelay) { [weak self] in
            self?.isAutoLoadingNextPage = false
            
            // Note: We sort the headers as we want to prioritise loading newer pages over older ones
            let sections: [(HomeViewModel.Section, CGRect)] = (self?.viewModel.threadData
                .enumerated()
                .map { index, section in (section.model, (self?.tableView.rectForHeader(inSection: index) ?? .zero)) })
                .defaulting(to: [])
            let shouldLoadMore: Bool = sections
                .contains { section, headerRect in
                    section == .loadMore &&
                    headerRect != .zero &&
                    (self?.tableView.bounds.contains(headerRect) == true)
                }
            
            guard shouldLoadMore else { return }
            
            self?.isLoadingMore = true
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.viewModel.pagedDataObserver?.load(.pageAfter)
            }
        }
    }
    
    private func updateNavBarButtons(userProfile: Profile) {
        // Profile picture view
        let profilePictureView = ProfilePictureView(size: .navigation)
        profilePictureView.accessibilityIdentifier = "User settings"
        profilePictureView.accessibilityLabel = "User settings"
        profilePictureView.isAccessibilityElement = true
        profilePictureView.update(
            publicKey: userProfile.id,
            threadVariant: .contact,
            displayPictureFilename: nil,
            profile: userProfile,
            profileIcon: (viewModel.dependencies[feature: .serviceNetwork] == .testnet ?
                .letter("T") :     // stringlint:disable
                .none
            ),
            additionalProfile: nil,
            using: viewModel.dependencies
        )
        navBarProfileView = profilePictureView
        
        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(openSettings))
        profilePictureView.addGestureRecognizer(tapGestureRecognizer)
        
        // Path status indicator
        let pathStatusView = PathStatusView(using: viewModel.dependencies)
        pathStatusView.accessibilityLabel = "Current onion routing path indicator"
        
        viewModel.dependencies.publisher(feature: .serviceNetwork)
            .subscribe(on: DispatchQueue.global(qos: .background), using: viewModel.dependencies)
            .receive(on: DispatchQueue.main, using: viewModel.dependencies)
            .sink(
                receiveCompletion: { [weak self] _ in
                    /// If the stream completes it means the network cache was reset in which case we want to
                    /// re-register for updates in the next run loop (as the new cache should be created by then)
                    DispatchQueue.main.async {
                        self?.updateNavBarButtons(userProfile: userProfile)
                    }
                },
                receiveValue: { [weak profilePictureView, dependencies = viewModel.dependencies] value in
                    profilePictureView?.update(
                        publicKey: userProfile.id,
                        threadVariant: .contact,
                        displayPictureFilename: nil,
                        profile: userProfile,
                        profileIcon: (value == .testnet ?
                            .letter("T") :     // stringlint:disable
                            .none
                        ),
                        additionalProfile: nil,
                        using: dependencies
                    )
                }
            )
            .store(in: &profilePictureView.disposables)
        
        // Container view
        let profilePictureViewContainer = UIView()
        profilePictureViewContainer.addSubview(profilePictureView)
        profilePictureView.pin(to: profilePictureViewContainer)
        profilePictureViewContainer.addSubview(pathStatusView)
        pathStatusView.pin(.trailing, to: .trailing, of: profilePictureViewContainer)
        pathStatusView.pin(.bottom, to: .bottom, of: profilePictureViewContainer)
        
        // Left bar button item
        let leftBarButtonItem = UIBarButtonItem(customView: profilePictureViewContainer)
        leftBarButtonItem.isAccessibilityElement = true
        navigationItem.leftBarButtonItem = leftBarButtonItem
        
        // Right bar button item - search button
        let rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .search, target: self, action: #selector(showSearchUI))
        rightBarButtonItem.accessibilityLabel = "Search button"
        rightBarButtonItem.isAccessibilityElement  = true
        navigationItem.rightBarButtonItem = rightBarButtonItem
    }
    
    // MARK: - UITableViewDataSource
    
    public func numberOfSections(in tableView: UITableView) -> Int {
        return viewModel.threadData.count
    }
    
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let section: HomeViewModel.SectionModel = viewModel.threadData[section]
        
        return section.elements.count
    }
    
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let section: HomeViewModel.SectionModel = viewModel.threadData[indexPath.section]
        
        switch section.model {
            case .messageRequests:
                let threadViewModel: SessionThreadViewModel = section.elements[indexPath.row]
                let cell: MessageRequestsCell = tableView.dequeue(type: MessageRequestsCell.self, for: indexPath)
                cell.accessibilityIdentifier = "Message requests banner"
                cell.isAccessibilityElement = true
                cell.update(with: Int(threadViewModel.threadUnreadCount ?? 0))
                return cell
                
            case .threads:
                let threadViewModel: SessionThreadViewModel = section.elements[indexPath.row]
                let cell: FullConversationCell = tableView.dequeue(type: FullConversationCell.self, for: indexPath)
                cell.update(with: threadViewModel, using: viewModel.dependencies)
                cell.accessibilityIdentifier = "Conversation list item"
                cell.accessibilityLabel = threadViewModel.displayName
                return cell
                
            default: preconditionFailure("Other sections should have no content")
        }
    }
    
    public func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let section: HomeViewModel.SectionModel = viewModel.threadData[section]
        
        switch section.model {
            case .loadMore:
                let loadingIndicator: UIActivityIndicatorView = UIActivityIndicatorView(style: .medium)
                loadingIndicator.themeTintColor = .textPrimary
                loadingIndicator.alpha = 0.5
                loadingIndicator.startAnimating()
                
                let view: UIView = UIView()
                view.addSubview(loadingIndicator)
                loadingIndicator.center(in: view)
                
                return view
            
            default: return nil
        }
    }
    
    // MARK: - UITableViewDelegate
    
    public func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        let section: HomeViewModel.SectionModel = viewModel.threadData[section]
        
        switch section.model {
            case .loadMore: return HomeVC.loadingHeaderHeight
            default: return 0
        }
    }
    
    public func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard self.hasLoadedInitialThreadData && self.viewHasAppeared && !self.isLoadingMore else { return }
        
        let section: HomeViewModel.SectionModel = self.viewModel.threadData[section]
        
        switch section.model {
            case .loadMore:
                self.isLoadingMore = true
                
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.viewModel.pagedDataObserver?.load(.pageAfter)
                }
                
            default: break
        }
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        let section: HomeViewModel.SectionModel = self.viewModel.threadData[indexPath.section]
        
        switch section.model {
            case .messageRequests:
                let viewController: SessionTableViewController = SessionTableViewController(
                    viewModel: MessageRequestsViewModel(using: viewModel.dependencies)
                )
                self.navigationController?.pushViewController(viewController, animated: true)
                
            case .threads:
                let threadViewModel: SessionThreadViewModel = section.elements[indexPath.row]
                let viewController: ConversationVC = ConversationVC(
                    threadId: threadViewModel.threadId,
                    threadVariant: threadViewModel.threadVariant,
                    focusedInteractionInfo: nil,
                    using: viewModel.dependencies
                )
                self.navigationController?.pushViewController(viewController, animated: true)
                
            default: break
        }
    }
    
    public func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }
    
    public func tableView(_ tableView: UITableView, willBeginEditingRowAt indexPath: IndexPath) {
        UIContextualAction.willBeginEditing(indexPath: indexPath, tableView: tableView)
    }
    
    public func tableView(_ tableView: UITableView, didEndEditingRowAt indexPath: IndexPath?) {
        UIContextualAction.didEndEditing(indexPath: indexPath, tableView: tableView)
    }
    
    public func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let section: HomeViewModel.SectionModel = self.viewModel.threadData[indexPath.section]
        let threadViewModel: SessionThreadViewModel = section.elements[indexPath.row]
        
        switch section.model {
            case .threads:
                // Cannot properly sync outgoing blinded message requests so don't provide the option
                guard
                    threadViewModel.threadVariant != .contact ||
                    (try? SessionId(from: section.elements[indexPath.row].threadId))?.prefix == .standard
                else { return nil }
                
                return UIContextualAction.configuration(
                    for: UIContextualAction.generateSwipeActions(
                        [.toggleReadStatus],
                        for: .leading,
                        indexPath: indexPath,
                        tableView: tableView,
                        threadViewModel: threadViewModel,
                        viewController: self,
                        navigatableStateHolder: viewModel,
                        using: viewModel.dependencies
                    )
                )
            
            default: return nil
        }
    }
    
    public func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let section: HomeViewModel.SectionModel = self.viewModel.threadData[indexPath.section]
        let threadViewModel: SessionThreadViewModel = section.elements[indexPath.row]
        
        switch section.model {
            case .messageRequests:
                return UIContextualAction.configuration(
                    for: UIContextualAction.generateSwipeActions(
                        [.hide],
                        for: .trailing,
                        indexPath: indexPath,
                        tableView: tableView,
                        threadViewModel: threadViewModel,
                        viewController: self,
                        navigatableStateHolder: viewModel,
                        using: viewModel.dependencies
                    )
                )
                
            case .threads:
                let sessionIdPrefix: SessionId.Prefix? = try? SessionId.Prefix(from: threadViewModel.threadId)
                
                // Cannot properly sync outgoing blinded message requests so only provide valid options
                let shouldHavePinAction: Bool = (
                    sessionIdPrefix != .blinded15 &&
                    sessionIdPrefix != .blinded25
                )
                let shouldHaveMuteAction: Bool = {
                    switch threadViewModel.threadVariant {
                        case .contact: return (
                            !threadViewModel.threadIsNoteToSelf &&
                            sessionIdPrefix != .blinded15 &&
                            sessionIdPrefix != .blinded25
                        )
                            
                        case .legacyGroup, .group: return (
                            threadViewModel.currentUserIsClosedGroupMember == true
                        )
                            
                        case .community: return true
                    }
                }()
                let destructiveAction: UIContextualAction.SwipeAction = {
                    switch (threadViewModel.threadVariant, threadViewModel.threadIsNoteToSelf, threadViewModel.currentUserIsClosedGroupMember) {
                        case (.contact, true, _): return .clear
                        case (.legacyGroup, _, true), (.group, _, true), (.community, _, _): return .leave
                        default: return .delete
                    }
                }()
                
                return UIContextualAction.configuration(
                    for: UIContextualAction.generateSwipeActions(
                        [
                            (!shouldHavePinAction ? nil : .pin),
                            (!shouldHaveMuteAction ? nil : .mute),
                            destructiveAction
                        ].compactMap { $0 },
                        for: .trailing,
                        indexPath: indexPath,
                        tableView: tableView,
                        threadViewModel: threadViewModel,
                        viewController: self,
                        navigatableStateHolder: viewModel,
                        using: viewModel.dependencies
                    )
                )
                
            default: return nil
        }
    }
    
    // MARK: - Interaction
    
    func handleContinueButtonTapped(from seedReminderView: SeedReminderView) {
        guard let recoveryPasswordView: RecoveryPasswordScreen = try? RecoveryPasswordScreen(using: viewModel.dependencies) else {
            let targetViewController: UIViewController = ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "theError".localized(),
                    body: .text("recoveryPasswordErrorLoad".localized()),
                    cancelTitle: "okay".localized(),
                    cancelStyle: .alert_text
                )
            )
            present(targetViewController, animated: true, completion: nil)
            return
        }

        let viewController: SessionHostingViewController = SessionHostingViewController(rootView: recoveryPasswordView)
        viewController.setNavBarTitle("sessionRecoveryPassword".localized())
        self.navigationController?.pushViewController(viewController, animated: true)
    }
    
    @objc private func openSettings() {
        let settingsViewController: SessionTableViewController = SessionTableViewController(
            viewModel: SettingsViewModel(using: viewModel.dependencies)
        )
        let navigationController = StyledNavigationController(rootViewController: settingsViewController)
        navigationController.modalPresentationStyle = .fullScreen
        present(navigationController, animated: true, completion: nil)
    }
    
    @objc private func showSearchUI() {
        if let presentedVC = self.presentedViewController {
            presentedVC.dismiss(animated: false, completion: nil)
        }
        let searchController = GlobalSearchViewController(using: viewModel.dependencies)
        self.navigationController?.setViewControllers([ self, searchController ], animated: true)
    }
    
    @objc private func createNewConversation() {
        viewModel.dependencies[singleton: .app].createNewConversation()
    }
    
    func createNewDMFromDeepLink(sessionId: String) {
        let viewController: SessionHostingViewController = SessionHostingViewController(
            rootView: NewMessageScreen(accountId: sessionId, using: viewModel.dependencies)
        )
        viewController.setNavBarTitle(
            "messageNew"
                .putNumber(1)
                .localized()
        )
        let navigationController = StyledNavigationController(rootViewController: viewController)
        if UIDevice.current.isIPad {
            navigationController.modalPresentationStyle = .fullScreen
        }
        navigationController.modalPresentationCapturesStatusBarAppearance = true
        present(navigationController, animated: true, completion: nil)
    }
}
