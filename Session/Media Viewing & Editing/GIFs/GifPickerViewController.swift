// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import Reachability
import SignalUtilitiesKit
import SessionUIKit
import SignalCoreKit
import SessionUtilitiesKit
import SessionMessagingKit

class GifPickerViewController: OWSViewController, UISearchBarDelegate, UICollectionViewDataSource, UICollectionViewDelegate, GifPickerLayoutDelegate {

    // MARK: Properties

    enum ViewMode {
        case idle, searching, results, noResults, error
    }

    private var viewMode = ViewMode.idle {
        didSet {
            Logger.info("viewMode: \(viewMode)")

            updateContents()
        }
    }

    var lastQuery: String = ""

    private let dependencies: Dependencies
    public weak var delegate: GifPickerViewControllerDelegate?

    let searchBar: SearchBar
    let layout: GifPickerLayout
    let collectionView: UICollectionView
    var noResultsView: UILabel?
    var searchErrorView: UILabel?
    var activityIndicator: UIActivityIndicatorView?
    var hasSelectedCell: Bool = false
    var imageInfos = [GiphyImageInfo]()
    
    private let kCellReuseIdentifier = "kCellReuseIdentifier"

    var progressiveSearchTimer: Timer?
    
    private var disposables: Set<AnyCancellable> = Set()

    // MARK: - Initialization

    @available(*, unavailable, message:"use other constructor instead.")
    required init?(coder aDecoder: NSCoder) {
        notImplemented()
    }

    required init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.searchBar = SearchBar()
        self.layout = GifPickerLayout()
        self.collectionView = UICollectionView(frame: CGRect.zero, collectionViewLayout: self.layout)

        super.init(nibName: nil, bundle: nil)

        self.layout.delegate = self
    }

    deinit {
        NotificationCenter.default.removeObserver(self)

        progressiveSearchTimer?.invalidate()
    }

    @objc func didBecomeActive() {
        AssertIsOnMainThread()

        Logger.info("")

        // Prod cells to try to load when app becomes active.
        ensureCellState()
    }

    @objc func reachabilityChanged() {
        AssertIsOnMainThread()

        Logger.info("")

        // Prod cells to try to load when connectivity changes.
        ensureCellState()
    }

    func ensureCellState() {
        for cell in self.collectionView.visibleCells {
            guard let cell = cell as? GifPickerCell else {
                owsFailDebug("unexpected cell.")
                return
            }
            cell.ensureCellState()
        }
    }

    // MARK: View Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        self.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(donePressed)
        )
        
        // Loki: Customize title
        let titleLabel: UILabel = UILabel()
        titleLabel.font = .boldSystemFont(ofSize: Values.veryLargeFontSize)
        titleLabel.text = "accessibility_gif_button".localized().uppercased()
        titleLabel.themeTextColor = .textPrimary
        navigationItem.titleView = titleLabel

        createViews()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reachabilityChanged),
            name: .reachabilityChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didBecomeActive),
            name: .sessionDidBecomeActive,
            object: nil
        )
        
        loadTrending()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        self.searchBar.becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        progressiveSearchTimer?.invalidate()
        progressiveSearchTimer = nil
    }

    // MARK: Views

    private func createViews() {
        self.view.themeBackgroundColor = .backgroundPrimary
        
        // Search
        searchBar.delegate = self

        self.view.addSubview(searchBar)
        searchBar.set(.width, to: .width, of: view)
        searchBar.pin(.top, to: .top, of: view)

        self.collectionView.delegate = self
        self.collectionView.dataSource = self
        self.collectionView.themeBackgroundColor = .backgroundPrimary
        self.collectionView.register(GifPickerCell.self, forCellWithReuseIdentifier: kCellReuseIdentifier)
        // Inserted below searchbar because we later occlude the collectionview
        // by inserting a masking layer between the search bar and collectionview
        self.view.insertSubview(self.collectionView, belowSubview: searchBar)
        self.collectionView.pin(.top, to: .bottom, of: searchBar)
        self.collectionView.pin(.leading, to: .leading, of: view.safeAreaLayoutGuide)
        self.collectionView.pin(.trailing, to: .trailing, of: view.safeAreaLayoutGuide)
        
        // Block UIKit from adjust insets of collection view which screws up
        // min/max scroll positions
        self.collectionView.contentInsetAdjustmentBehavior = .never

        // for iPhoneX devices, extends the black background to the bottom edge of the view.
        let bottomBannerContainer = UIView()
        bottomBannerContainer.themeBackgroundColor = .backgroundPrimary
        self.view.addSubview(bottomBannerContainer)
        bottomBannerContainer.set(.width, to: .width, of: self.collectionView)
        bottomBannerContainer.pin(.top, to: .bottom, of: self.collectionView)
        bottomBannerContainer.pin(.bottom, to: .bottom, of: view)

        let bottomBanner = UIView()
        bottomBannerContainer.addSubview(bottomBanner)

        bottomBanner.set(.width, to: .width, of: bottomBannerContainer)
        bottomBanner.pin(.top, to: .top, of: bottomBannerContainer)
        self.pinViewToBottomOfViewControllerOrKeyboard(bottomBanner, avoidNotch: true)

        // The Giphy API requires us to "show their trademark prominently" in our GIF experience.
        let logoImage = UIImage(named: "giphy_logo")
        let logoImageView = UIImageView(image: logoImage)
        bottomBanner.addSubview(logoImageView)
        logoImageView.set(.height, to: .height, of: bottomBanner, withOffset: -3)
        logoImageView.center(.horizontal, in: bottomBanner)

        let noResultsView = createErrorLabel(text: "GIF_VIEW_SEARCH_NO_RESULTS".localized())
        self.noResultsView = noResultsView
        self.view.addSubview(noResultsView)
        noResultsView.set(.width, to: .width, of: self.view, withOffset: -20)
        noResultsView.center(.horizontal, in: self.collectionView)

        let searchErrorView = createErrorLabel(text: "GIF_VIEW_SEARCH_ERROR".localized())
        self.searchErrorView = searchErrorView
        self.view.addSubview(searchErrorView)
        searchErrorView.set(.width, to: .width, of: self.view, withOffset: -20)
        searchErrorView.center(.horizontal, in: self.collectionView)

        searchErrorView.isUserInteractionEnabled = true
        searchErrorView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(retryTapped)))

        let activityIndicator = UIActivityIndicatorView(style: .large)
        self.activityIndicator = activityIndicator
        self.view.addSubview(activityIndicator)
        activityIndicator.center(.horizontal, in: self.view)
        activityIndicator.center(.vertical, in: self.collectionView)
        
        self.updateContents()
    }

    private func createErrorLabel(text: String) -> UILabel {
        let label: UILabel = UILabel()
        label.font = UIFont.systemFont(ofSize: 20, weight: .medium)
        label.text = text
        label.themeTextColor = .textPrimary
        label.textAlignment = .center
        label.lineBreakMode = .byWordWrapping
        label.numberOfLines = 0
        
        return label
    }

    private func updateContents() {
        guard let noResultsView = self.noResultsView else {
            owsFailDebug("Missing noResultsView")
            return
        }
        guard let searchErrorView = self.searchErrorView else {
            owsFailDebug("Missing searchErrorView")
            return
        }
        guard let activityIndicator = self.activityIndicator else {
            owsFailDebug("Missing activityIndicator")
            return
        }

        switch viewMode {
            case .idle:
                self.collectionView.isHidden = true
                noResultsView.isHidden = true
                searchErrorView.isHidden = true
                activityIndicator.isHidden = true
                activityIndicator.stopAnimating()
                
            case .searching:
                self.collectionView.isHidden = true
                noResultsView.isHidden = true
                searchErrorView.isHidden = true
                activityIndicator.isHidden = false
                activityIndicator.startAnimating()
                
            case .results:
                self.collectionView.isHidden = false
                noResultsView.isHidden = true
                searchErrorView.isHidden = true
                activityIndicator.isHidden = true
                activityIndicator.stopAnimating()

                self.collectionView.collectionViewLayout.invalidateLayout()
                self.collectionView.reloadData()
                
            case .noResults:
                self.collectionView.isHidden = true
                noResultsView.isHidden = false
                searchErrorView.isHidden = true
                activityIndicator.isHidden = true
                activityIndicator.stopAnimating()
                
            case .error:
                self.collectionView.isHidden = true
                noResultsView.isHidden = true
                searchErrorView.isHidden = false
                activityIndicator.isHidden = true
                activityIndicator.stopAnimating()
        }
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        self.searchBar.resignFirstResponder()
    }

    // MARK: - UICollectionViewDataSource

    public func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return imageInfos.count
    }

    public  func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: kCellReuseIdentifier, for: indexPath)

        guard indexPath.row < imageInfos.count else {
            Logger.warn("indexPath: \(indexPath.row) out of range for imageInfo count: \(imageInfos.count) ")
            return cell
        }
        let imageInfo = imageInfos[indexPath.row]

        guard let gifCell = cell as? GifPickerCell else {
            owsFailDebug("Unexpected cell type.")
            return cell
        }
        gifCell.dependencies = dependencies
        gifCell.imageInfo = imageInfo
        return cell
    }

    // MARK: - UICollectionViewDelegate

    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let cell = collectionView.cellForItem(at: indexPath) as? GifPickerCell else {
            owsFailDebug("unexpected cell.")
            return
        }

        guard cell.stillAsset != nil || cell.animatedAsset != nil else {
            // we don't want to let the user blindly select a gray cell
            Logger.debug("ignoring selection of cell with no preview")
            return
        }

        guard self.hasSelectedCell == false else {
            owsFailDebug("Already selected cell")
            return
        }
        self.hasSelectedCell = true

        // Fade out all cells except the selected one.
        let maskingView = BezierPathView()

        // Selecting cell behind searchbar masks part of search bar.
        // So we insert mask *behind* the searchbar.
        self.view.insertSubview(maskingView, belowSubview: searchBar)
        let cellRect = self.collectionView.convert(cell.frame, to: self.view)
        maskingView.configureShapeLayer = { layer, bounds in
            let path = UIBezierPath(rect: bounds)
            path.append(UIBezierPath(rect: cellRect))

            layer.path = path.cgPath
            layer.fillRule = .evenOdd
            layer.themeFillColor = .black
            layer.opacity = 0.7
        }
        maskingView.pin(to: self.view)

        cell.isCellSelected = true
        self.collectionView.isUserInteractionEnabled = false

        getFileForCell(cell)
    }

    public func getFileForCell(_ cell: GifPickerCell) {
        dependencies[singleton: .giphyDownloader].cancelAllRequests()
        
        cell
            .requestRenditionForSending()
            .subscribe(on: DispatchQueue.global(qos: .userInitiated))
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] result in
                    switch result {
                        case .finished: break
                        case .failure(let error):
                            let modal: ConfirmationModal = ConfirmationModal(
                                targetView: self?.view,
                                info: ConfirmationModal.Info(
                                    title: "GIF_PICKER_FAILURE_ALERT_TITLE".localized(),
                                    body: .text(error.localizedDescription),
                                    confirmTitle: CommonStrings.retryButton,
                                    cancelTitle: CommonStrings.dismissButton,
                                    cancelStyle: .alert_text,
                                    onConfirm: { _ in
                                        self?.getFileForCell(cell)
                                    }
                                )
                            )
                            self?.present(modal, animated: true)
                    }
                },
                receiveValue: { [weak self] asset in
                    guard let rendition = asset.assetDescription as? GiphyRendition else {
                        owsFailDebug("Invalid asset description.")
                        return
                    }

                    let filePath = asset.filePath
                    let dataSource = DataSourcePath(filePath: asset.filePath, shouldDeleteOnDeinit: false)
                    let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: rendition.utiType, imageQuality: .medium)

                    self?.dismiss(animated: true) {
                        // Delegate presents view controllers, so it's important that *this* controller be dismissed before that occurs.
                        self?.delegate?.gifPickerDidSelect(attachment: attachment)
                    }
                }
            )
            .store(in: &disposables)
    }

    public func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let cell = cell as? GifPickerCell else {
            owsFailDebug("unexpected cell.")
            return
        }
        // We only want to load the cells which are on-screen.
        cell.isCellVisible = true
    }

    public func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let cell = cell as? GifPickerCell else {
            owsFailDebug("unexpected cell.")
            return
        }
        cell.isCellVisible = false
    }

    // MARK: - Event Handlers

    @objc func donePressed(sender: UIButton) {
        dismiss(animated: true, completion: nil)
    }

    // MARK: - UISearchBarDelegate

    public func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        // Clear error messages immediately.
        if viewMode == .error || viewMode == .noResults {
            viewMode = .idle
        }

        // Do progressive search after a delay.
        progressiveSearchTimer?.invalidate()
        progressiveSearchTimer = nil
        let kProgressiveSearchDelaySeconds = 1.0
        progressiveSearchTimer = Timer.scheduledTimerOnMainThread(withTimeInterval: kProgressiveSearchDelaySeconds, repeats: true) { [weak self] _ in
            self?.tryToSearch()
        }
    }

    public func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        self.searchBar.resignFirstResponder()

        tryToSearch()
    }

    public func tryToSearch() {
        progressiveSearchTimer?.invalidate()
        progressiveSearchTimer = nil

        guard let text: String = searchBar.text else {
            // Alert message shown when user tries to search for GIFs without entering any search terms
            let modal: ConfirmationModal = ConfirmationModal(
                targetView: self.view,
                info: ConfirmationModal.Info(
                    title: CommonStrings.errorAlertTitle,
                    body: .text("GIF_PICKER_VIEW_MISSING_QUERY".localized()),
                    cancelTitle: "BUTTON_OK".localized(),
                    cancelStyle: .alert_text
                )
            )
            self.present(modal, animated: true)
            return
        }
        
        let query: String = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if (viewMode == .searching || viewMode == .results) && lastQuery == query {
            Logger.info("ignoring duplicate search: \(query)")
            return
        }

        guard !query.isEmpty else {
            loadTrending()
            return
        }
        
        search(query: query)
    }
    
    private func loadTrending() {
        assert(progressiveSearchTimer == nil)
        assert(searchBar.text == nil || searchBar.text?.count == 0)

        GiphyAPI.trending()
            .subscribe(on: DispatchQueue.global(qos: .userInitiated))
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error):
                            // Don't both showing error UI feedback for default "trending" results.
                            Logger.error("error: \(error)")
                    }
                },
                receiveValue: { [weak self] imageInfos in
                    Logger.info("showing trending")
                    
                    if imageInfos.count > 0 {
                        self?.imageInfos = imageInfos
                        self?.viewMode = .results
                    }
                    else {
                        owsFailDebug("trending results was unexpectedly empty")
                    }
                }
            )
            .store(in: &disposables)
    }

    private func search(query: String) {
        Logger.info("searching: \(query)")

        progressiveSearchTimer?.invalidate()
        progressiveSearchTimer = nil
        imageInfos = []
        viewMode = .searching
        lastQuery = query
        self.collectionView.contentOffset = CGPoint.zero

        GiphyAPI
            .search(query: query)
            .subscribe(on: DispatchQueue.global(qos: .userInitiated))
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] result in
                    switch result {
                        case .finished: break
                        case .failure:
                            Logger.info("search failed.")
                            // TODO: Present this error to the user.
                            self?.viewMode = .error
                    }
                },
                receiveValue: { [weak self] imageInfos in
                    Logger.info("search complete")
                    self?.imageInfos = imageInfos
                    
                    if imageInfos.count > 0 {
                        self?.viewMode = .results
                    }
                    else {
                        self?.viewMode = .noResults
                    }
                }
            )
            .store(in: &disposables)
    }

    // MARK: - GifPickerLayoutDelegate

    func imageInfosForLayout() -> [GiphyImageInfo] {
        return imageInfos
    }

    // MARK: - Event Handlers

    @objc func retryTapped(sender: UIGestureRecognizer) {
        guard sender.state == .recognized else {
            return
        }
        guard viewMode == .error else {
            return
        }
        tryToSearch()
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        layout.invalidateLayout()
    }
}

// MARK: - GifPickerViewControllerDelegate

protocol GifPickerViewControllerDelegate: AnyObject {
    func gifPickerDidSelect(attachment: SignalAttachment)
}
