// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

class GlobalSearchViewController: BaseVC, LibSessionRespondingViewController, UITableViewDelegate, UITableViewDataSource {
    fileprivate typealias SectionModel = ArraySection<SearchSection, SessionThreadViewModel>
    
    fileprivate struct SearchResultData {
        var state: SearchResultsState
        var data: [SectionModel]
    }
    
    enum SearchResultsState: Int, Differentiable {
        case none
        case results
        case defaultContacts
    }
    
    // MARK: - SearchSection
    enum SearchSection: Codable, Hashable, Differentiable {
        case contactsAndGroups
        case messages
        case groupedContacts(title: String)
    }
    
    // MARK: - LibSessionRespondingViewController
    
    let isConversationList: Bool = true
    
    func forceRefreshIfNeeded() {
        // Need to do this as the 'GlobalSearchViewController' doesn't observe database changes
        updateSearchResults(searchText: searchText, force: true)
    }
    
    // MARK: - Variables
    
    private let dependencies: Dependencies
    private lazy var defaultSearchResults: SearchResultData = {
        let nonalphabeticNameTitle: String = "#" // stringlint:ignore
        let contacts: [SessionThreadViewModel] = dependencies[singleton: .storage].read { [dependencies] db -> [SessionThreadViewModel]? in
            try SessionThreadViewModel
                .defaultContactsQuery(userSessionId: dependencies[cache: .general].sessionId)
                .fetchAll(db)
        }
        .defaulting(to: [])
        .sorted {
            $0.displayName.lowercased() < $1.displayName.lowercased()
        }
        
        var groupedContacts: [String: SectionModel] = [:]
        contacts.forEach { contactViewModel in
            guard !contactViewModel.threadIsNoteToSelf else {
                groupedContacts[""] = SectionModel(
                    model: .groupedContacts(title: ""),
                    elements: [contactViewModel]
                )
                return
            }
            
            let displayName = NSMutableString(string: contactViewModel.displayName)
            CFStringTransform(displayName, nil, kCFStringTransformToLatin, false)
            CFStringTransform(displayName, nil, kCFStringTransformStripDiacritics, false)
                
            let initialCharacter: String = (displayName.length > 0 ? displayName.substring(to: 1) : "")
            let section: String = initialCharacter.capitalized.isSingleAlphabet ?
                initialCharacter.capitalized :
                nonalphabeticNameTitle
                
            if groupedContacts[section] == nil {
                groupedContacts[section] = SectionModel(
                    model: .groupedContacts(title: section),
                    elements: []
                )
            }
            groupedContacts[section]?.elements.append(contactViewModel)
        }
        
        return SearchResultData(
            state: .defaultContacts,
            data: groupedContacts.values.sorted { sectionModel0, sectionModel1 in
                let title0: String = {
                    switch sectionModel0.model {
                        case .groupedContacts(let title): return title
                        default: return ""
                    }
                }()
                let title1: String = {
                    switch sectionModel1.model {
                        case .groupedContacts(let title): return title
                        default: return ""
                    }
                }()
                
                if ![title0, title1].contains(nonalphabeticNameTitle) {
                    return title0 < title1
                }
                
                return title1 == nonalphabeticNameTitle
            }
        )
    }()
    
    private var readConnection: Atomic<Database?> = Atomic(nil)
    private lazy var searchResultSet: SearchResultData = defaultSearchResults
    private var termForCurrentSearchResultSet: String = ""
    private var lastSearchText: String?
    private var refreshTimer: Timer?
    
    var isLoading = false
    
    @objc public var searchText = "" {
        didSet {
            Log.assertOnMainThread()
            // Use a slight delay to debounce updates.
            refreshSearchResults()
        }
    }
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI Components

    internal lazy var searchBar: SearchBar = {
        let result: SearchBar = SearchBar()
        result.themeTintColor = .textPrimary
        result.delegate = self
        result.showsCancelButton = true
        
        return result
    }()
    
    private var searchBarWidth: NSLayoutConstraint?

    internal lazy var tableView: UITableView = {
        let result: UITableView = UITableView(frame: .zero, style: .grouped)
        result.themeBackgroundColor = .clear
        result.rowHeight = UITableView.automaticDimension
        result.estimatedRowHeight = 60
        result.separatorStyle = .none
        result.keyboardDismissMode = .onDrag
        result.register(view: EmptySearchResultCell.self)
        result.register(view: FullConversationCell.self)
        result.showsVerticalScrollIndicator = false
        
        return result
    }()

    // MARK: - View Lifecycle
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)
        tableView.pin(.leading, to: .leading, of: view)
        tableView.pin(.top, to: .top, of: view, withInset: Values.smallSpacing)
        tableView.pin(.trailing, to: .trailing, of: view)
        tableView.pin(.bottom, to: .bottom, of: view)

        navigationItem.hidesBackButton = true
        setupNavigationBar()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        searchBar.becomeFirstResponder()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        UIView.performWithoutAnimation {
            searchBar.resignFirstResponder()
        }
    }
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        searchBarWidth?.constant = size.width - 32
    }

    private func setupNavigationBar() {
        // This is a workaround for a UI issue that the navigation bar can be a bit higher if
        // the search bar is put directly to be the titleView. And this can cause the tableView
        // in home screen doing a weird scrolling when going back to home screen.
        let searchBarContainer: UIView = UIView()
        searchBarContainer.layoutMargins = UIEdgeInsets.zero
        searchBar.sizeToFit()
        searchBar.layoutMargins = UIEdgeInsets.zero
        searchBarContainer.set(.height, to: 44)
        searchBarWidth = searchBarContainer.set(.width, to: UIScreen.main.bounds.width - 32)
        searchBarContainer.addSubview(searchBar)
        navigationItem.titleView = searchBarContainer
        
        // On iPad, the cancel button won't show
        // See more https://developer.apple.com/documentation/uikit/uisearchbar/1624283-showscancelbutton?language=objc
        if UIDevice.current.isIPad {
            let ipadCancelButton = UIButton()
            ipadCancelButton.setTitle("cancel".localized(), for: .normal)
            ipadCancelButton.setThemeTitleColor(.textPrimary, for: .normal)
            ipadCancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
            searchBarContainer.addSubview(ipadCancelButton)
            
            ipadCancelButton.pin(.trailing, to: .trailing, of: searchBarContainer)
            ipadCancelButton.center(.vertical, in: searchBarContainer)
            searchBar.pin(.top, to: .top, of: searchBar)
            searchBar.pin(.leading, to: .leading, of: searchBar)
            searchBar.pin(.trailing, to: .leading, of: ipadCancelButton, withInset: -Values.smallSpacing)
            searchBar.pin(.bottom, to: .bottom, of: searchBar)
        }
        else {
            searchBar.pin(toMarginsOf: searchBarContainer)
        }
    }

    // MARK: - Update Search Results

    private func refreshSearchResults() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimerOnMainThread(withTimeInterval: 0.1, using: dependencies) { [weak self] _ in
            self?.updateSearchResults(searchText: (self?.searchText ?? ""))
        }
    }

    private func updateSearchResults(
        searchText rawSearchText: String,
        force: Bool = false
    ) {
        let searchText = rawSearchText.stripped
        
        guard searchText.count > 0 else {
            guard searchText != (lastSearchText ?? "") else { return }
            
            searchResultSet = defaultSearchResults
            lastSearchText = nil
            tableView.reloadData()
            return
        }
        guard force || lastSearchText != searchText else { return }

        lastSearchText = searchText

        DispatchQueue.global(qos: .default).async { [weak self, dependencies] in
            self?.readConnection.wrappedValue?.interrupt()
            
            let result: Result<[SectionModel], Error>? = dependencies[singleton: .storage].read { db -> Result<[SectionModel], Error> in
                self?.readConnection.mutate { $0 = db }
                
                do {
                    let userSessionId: SessionId = dependencies[cache: .general].sessionId
                    let contactsAndGroupsResults: [SessionThreadViewModel] = try SessionThreadViewModel
                        .contactsAndGroupsQuery(
                            userSessionId: userSessionId,
                            pattern: try SessionThreadViewModel.pattern(db, searchTerm: searchText),
                            searchTerm: searchText
                        )
                        .fetchAll(db)
                    let messageResults: [SessionThreadViewModel] = try SessionThreadViewModel
                        .messagesQuery(
                            userSessionId: userSessionId,
                            pattern: try SessionThreadViewModel.pattern(db, searchTerm: searchText)
                        )
                        .fetchAll(db)
                    
                    return .success([
                        ArraySection(model: .contactsAndGroups, elements: contactsAndGroupsResults),
                        ArraySection(model: .messages, elements: messageResults)
                    ])
                }
                catch {
                    // Don't log the 'interrupt' error as that's just the user typing too fast
                    if (error as? DatabaseError)?.resultCode != DatabaseError.SQLITE_INTERRUPT {
                        SNLog("[GlobalSearch] Failed to find results due to error: \(error)")
                    }
                    
                    return .failure(error)
                }
            }
            
            DispatchQueue.main.async {
                switch result {
                    case .success(let sections):
                        self?.termForCurrentSearchResultSet = searchText
                        self?.searchResultSet = SearchResultData(
                            state: (sections.map { $0.elements.count }.reduce(0, +) > 0) ? .results : .none,
                            data: sections
                        )
                        self?.isLoading = false
                        self?.tableView.reloadData()
                        self?.refreshTimer = nil
                        
                    default: break
                }
            }
        }
    }
    
    @objc func cancel() {
        self.navigationController?.popViewController(animated: true)
    }
}

// MARK: - UISearchBarDelegate

extension GlobalSearchViewController: UISearchBarDelegate {
    public func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
        self.updateSearchText()
    }

    public func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
        self.updateSearchText()
    }

    public func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        self.updateSearchText()
    }

    public func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        searchBar.text = nil
        searchBar.resignFirstResponder()
        self.navigationController?.popViewController(animated: true)
    }

    func updateSearchText() {
        guard let searchText = searchBar.text?.stripped else { return }
        self.searchText = searchText
    }
}

// MARK: - UITableViewDelegate & UITableViewDataSource

extension GlobalSearchViewController {

    // MARK: - UITableViewDelegate

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        
        let section: SectionModel = self.searchResultSet.data[indexPath.section]
        
        switch section.model {
            case .contactsAndGroups, .messages:
                show(
                    threadId: section.elements[indexPath.row].threadId,
                    threadVariant: section.elements[indexPath.row].threadVariant,
                    focusedInteractionInfo: {
                        guard
                            let interactionId: Int64 = section.elements[indexPath.row].interactionId,
                            let timestampMs: Int64 = section.elements[indexPath.row].interactionTimestampMs
                        else { return nil }
                        
                        return Interaction.TimestampInfo(
                            id: interactionId,
                            timestampMs: timestampMs
                        )
                    }()
                )
            case .groupedContacts:
                show(
                    threadId: section.elements[indexPath.row].threadId,
                    threadVariant: section.elements[indexPath.row].threadVariant
                )
        }
    }

    private func show(
        threadId: String,
        threadVariant: SessionThread.Variant,
        focusedInteractionInfo: Interaction.TimestampInfo? = nil,
        animated: Bool = true
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.show(threadId: threadId, threadVariant: threadVariant, focusedInteractionInfo: focusedInteractionInfo, animated: animated)
            }
            return
        }
        
        // If it's a one-to-one thread then make sure the thread exists before pushing to it (in case the
        // contact has been hidden)
        if threadVariant == .contact {
            dependencies[singleton: .storage].write { [dependencies] db in
                try SessionThread.fetchOrCreate(
                    db,
                    id: threadId,
                    variant: threadVariant,
                    creationDateTimestamp: (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000),
                    shouldBeVisible: nil,    // Don't change current state
                    calledFromConfig: nil,
                    using: dependencies
                )
            }
        }
        
        let viewController: ConversationVC = ConversationVC(
            threadId: threadId,
            threadVariant: threadVariant,
            focusedInteractionInfo: focusedInteractionInfo,
            using: dependencies
        )
        self.navigationController?.pushViewController(viewController, animated: true)
    }

    // MARK: - UITableViewDataSource

    public func numberOfSections(in tableView: UITableView) -> Int {
        return self.searchResultSet.data.count
    }
    
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.searchResultSet.data[section].elements.count
    }

    public func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        UIView()
    }

    public func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        .leastNonzeroMagnitude
    }

    public func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        guard self.searchResultSet.state != .none else {
            return .leastNonzeroMagnitude
        }
        
        return UITableView.automaticDimension
    }

    public func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let section: SectionModel = self.searchResultSet.data[section]
        
        let titleLabel = UILabel()
        titleLabel.themeTextColor = .textPrimary

        let container = UIView()
        container.themeBackgroundColor = .backgroundPrimary
        container.addSubview(titleLabel)
        
        titleLabel.pin(.top, to: .top, of: container, withInset: Values.verySmallSpacing)
        titleLabel.pin(.bottom, to: .bottom, of: container, withInset: -Values.verySmallSpacing)
        titleLabel.pin(.left, to: .left, of: container, withInset: Values.largeSpacing)
        titleLabel.pin(.right, to: .right, of: container, withInset: -Values.largeSpacing)
        
        switch section.model {
            case .contactsAndGroups: 
                guard !section.elements.isEmpty else { return UIView() }
                titleLabel.font = .boldSystemFont(ofSize: Values.largeFontSize)
                titleLabel.text = "sessionConversations".localized()
                break
            case .messages: 
                guard !section.elements.isEmpty else { return UIView() }
                titleLabel.font = .boldSystemFont(ofSize: Values.largeFontSize)
                titleLabel.text = "messages".localized()
                break
            case .groupedContacts(let title): 
                guard !section.elements.isEmpty else { return UIView() }
                if title.isEmpty {
                    titleLabel.font = .boldSystemFont(ofSize: Values.largeFontSize)
                    titleLabel.text = "contactContacts".localized()
                } else {
                    titleLabel.font = .systemFont(ofSize: Values.smallFontSize)
                    titleLabel.text = title
                }
                break
        }

        return container
    }

    public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard self.searchResultSet.state != .none else {
            let cell: EmptySearchResultCell = tableView.dequeue(type: EmptySearchResultCell.self, for: indexPath)
            cell.configure(isLoading: isLoading)
            return cell
        }
        
        let section: SectionModel = self.searchResultSet.data[indexPath.section]
        
        switch section.model {
            case .contactsAndGroups:
                let cell: FullConversationCell = tableView.dequeue(type: FullConversationCell.self, for: indexPath)
                cell.updateForContactAndGroupSearchResult(
                    with: section.elements[indexPath.row],
                    searchText: self.termForCurrentSearchResultSet,
                    using: dependencies
                )
                return cell
                
            case .messages:
                let cell: FullConversationCell = tableView.dequeue(type: FullConversationCell.self, for: indexPath)
                cell.updateForMessageSearchResult(
                    with: section.elements[indexPath.row],
                    searchText: self.termForCurrentSearchResultSet,
                    using: dependencies
                )
                return cell
            
            case .groupedContacts:
                let cell: FullConversationCell = tableView.dequeue(type: FullConversationCell.self, for: indexPath)
                cell.updateForDefaultContacts(with: section.elements[indexPath.row], using: dependencies)
                return cell
        }
    }
}
