// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

private protocol TableViewTouchDelegate {
    func tableViewWasTouched(_ tableView: TableView, withView hitView: UIView?)
}

private final class TableView: UITableView {
    var touchDelegate: TableViewTouchDelegate?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let resultingView: UIView? = super.hitTest(point, with: event)
        touchDelegate?.tableViewWasTouched(self, withView: resultingView)
        
        return resultingView
    }
}

final class NewClosedGroupVC: BaseVC, UITableViewDataSource, UITableViewDelegate, TableViewTouchDelegate, UITextFieldDelegate, UIScrollViewDelegate {
    private enum Section: Int, Differentiable, Equatable, Hashable {
        case contacts
    }
    
    private let dependencies: Dependencies
    private let contactProfiles: [Profile]
    private lazy var data: [ArraySection<Section, Profile>] = [
        ArraySection(model: .contacts, elements: contactProfiles)
    ]
    private var selectedProfiles: [String: Profile] = [:]
    private var searchText: String = ""
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.contactProfiles = Profile.fetchAllContactProfiles(excludeCurrentUser: true, using: dependencies)
        
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Components
    
    private static let textFieldHeight: CGFloat = 50
    private static let searchBarHeight: CGFloat = (36 + (Values.mediumSpacing * 2))
    
    private lazy var nameTextField: TextField = {
        let result = TextField(
            placeholder: "vc_create_closed_group_text_field_hint".localized(),
            usesDefaultHeight: false,
            customHeight: NewClosedGroupVC.textFieldHeight
        )
        result.set(.height, to: NewClosedGroupVC.textFieldHeight)
        result.themeBorderColor = .borderSeparator
        result.layer.cornerRadius = 13
        result.delegate = self
        result.accessibilityIdentifier = "Group name input"
        result.isAccessibilityElement = true
        
        return result
    }()
    
    private lazy var searchBar: ContactsSearchBar = {
        let result = ContactsSearchBar()
        result.themeTintColor = .textPrimary
        result.themeBackgroundColor = .clear
        result.delegate = self
        result.set(.height, to: NewClosedGroupVC.searchBarHeight)

        return result
    }()
    
    private lazy var headerView: UIView = {
        let result: UIView = UIView(
            frame: CGRect(
                x: 0, y: 0,
                width: UIScreen.main.bounds.width,
                height: (
                    Values.mediumSpacing +
                    NewClosedGroupVC.textFieldHeight +
                    NewClosedGroupVC.searchBarHeight
                )
            )
        )
        result.addSubview(nameTextField)
        result.addSubview(searchBar)
        
        nameTextField.pin(.top, to: .top, of: result, withInset: Values.mediumSpacing)
        nameTextField.pin(.leading, to: .leading, of: result, withInset: Values.largeSpacing)
        nameTextField.pin(.trailing, to: .trailing, of: result, withInset: -Values.largeSpacing)
        
        // Note: The top & bottom padding is built into the search bar
        searchBar.pin(.top, to: .bottom, of: nameTextField)
        searchBar.pin(.leading, to: .leading, of: result, withInset: Values.largeSpacing)
        searchBar.pin(.trailing, to: .trailing, of: result, withInset: -Values.largeSpacing)
        searchBar.pin(.bottom, to: .bottom, of: result)
        
        return result
    }()

    private lazy var tableView: TableView = {
        let result: TableView = TableView()
        result.separatorStyle = .none
        result.themeBackgroundColor = .clear
        result.showsVerticalScrollIndicator = false
        result.tableHeaderView = headerView
        result.contentInset = UIEdgeInsets(
            top: 0,
            leading: 0,
            bottom: Values.footerGradientHeight(window: UIApplication.shared.keyWindow),
            trailing: 0
        )
        result.register(view: SessionCell.self)
        result.touchDelegate = self
        result.dataSource = self
        result.delegate = self
        
        if #available(iOS 15.0, *) {
            result.sectionHeaderTopPadding = 0
        }
        
        return result
    }()
    
    private lazy var fadeView: GradientView = {
        let result: GradientView = GradientView()
        result.themeBackgroundGradient = [
            .value(.newConversation_background, alpha: 0), // Want this to take up 20% (~25pt)
            .newConversation_background,
            .newConversation_background,
            .newConversation_background,
            .newConversation_background
        ]
        result.set(.height, to: Values.footerGradientHeight(window: UIApplication.shared.keyWindow))
        
        return result
    }()
    
    private lazy var createGroupButton: SessionButton = {
        let result = SessionButton(style: .bordered, size: .large)
        result.translatesAutoresizingMaskIntoConstraints = false
        result.setTitle("CREATE_GROUP_BUTTON_TITLE".localized(), for: .normal)
        result.addTarget(self, action: #selector(createClosedGroup), for: .touchUpInside)
        result.accessibilityIdentifier = "Create group"
        result.isAccessibilityElement = true
        result.set(.width, to: 160)
        
        return result
    }()
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.themeBackgroundColor = .newConversation_background
        
        let customTitleFontSize = Values.largeFontSize
        setNavBarTitle("vc_create_closed_group_title".localized(), customFontSize: customTitleFontSize)
        
        let closeButton = UIBarButtonItem(image: #imageLiteral(resourceName: "X"), style: .plain, target: self, action: #selector(close))
        closeButton.themeTintColor = .textPrimary
        navigationItem.rightBarButtonItem = closeButton
        navigationItem.leftBarButtonItem?.accessibilityIdentifier = "Cancel"
        navigationItem.leftBarButtonItem?.isAccessibilityElement = true
        
        // Set up content
        setUpViewHierarchy()
    }

    private func setUpViewHierarchy() {
        guard !contactProfiles.isEmpty else {
            let explanationLabel: UILabel = UILabel()
            explanationLabel.font = .systemFont(ofSize: Values.smallFontSize)
            explanationLabel.text = "vc_create_closed_group_empty_state_message".localized()
            explanationLabel.themeTextColor = .textSecondary
            explanationLabel.textAlignment = .center
            explanationLabel.lineBreakMode = .byWordWrapping
            explanationLabel.numberOfLines = 0
            
            view.addSubview(explanationLabel)
            explanationLabel.pin(.top, to: .top, of: view, withInset: Values.largeSpacing)
            explanationLabel.center(.horizontal, in: view)
            return
        }
        
        view.addSubview(tableView)
        tableView.pin(.top, to: .top, of: view)
        tableView.pin(.leading, to: .leading, of: view)
        tableView.pin(.trailing, to: .trailing, of: view)
        tableView.pin(.bottom, to: .bottom, of: view)
        
        view.addSubview(fadeView)
        fadeView.pin(.leading, to: .leading, of: view)
        fadeView.pin(.trailing, to: .trailing, of: view)
        fadeView.pin(.bottom, to: .bottom, of: view)
        
        view.addSubview(createGroupButton)
        createGroupButton.center(.horizontal, in: view)
        createGroupButton.pin(.bottom, to: .bottom, of: view.safeAreaLayoutGuide, withInset: -Values.smallSpacing)
    }
    
    // MARK: - Table View Data Source
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return data[section].elements.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell: SessionCell = tableView.dequeue(type: SessionCell.self, for: indexPath)
        let profile: Profile = data[indexPath.section].elements[indexPath.row]
        cell.update(
            with: SessionCell.Info(
                id: profile,
                position: Position.with(indexPath.row, count: data[indexPath.section].elements.count),
                leadingAccessory: .profile(id: profile.id, profile: profile),
                title: profile.displayName(),
                trailingAccessory: .radio(isSelected: (selectedProfiles[profile.id] != nil)),
                styling: SessionCell.StyleInfo(backgroundStyle: .edgeToEdge),
                accessibility: Accessibility(
                    identifier: "Contact"
                )
            )
        )
        
        return cell
    }
    
    // MARK: - UITableViewDelegate
    
    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let profile: Profile = data[indexPath.section].elements[indexPath.row]
        
        if selectedProfiles[profile.id] == nil {
            selectedProfiles[profile.id] = profile
        }
        else {
            selectedProfiles.removeValue(forKey: profile.id)
        }
        
        tableView.deselectRow(at: indexPath, animated: true)
        tableView.reloadRows(at: [indexPath], with: .none)
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let nameTextFieldCenterY = nameTextField.convert(nameTextField.bounds.center, to: scrollView).y
        let shouldShowGroupNameInTitle: Bool = (scrollView.contentOffset.y > nameTextFieldCenterY)
        let groupNameLabelVisible: Bool = (crossfadeLabel.alpha >= 1)
        
        switch (shouldShowGroupNameInTitle, groupNameLabelVisible) {
            case (true, false):
                UIView.animate(withDuration: 0.2) {
                    self.navBarTitleLabel.alpha = 0
                    self.crossfadeLabel.alpha = 1
                }
                
            case (false, true):
                UIView.animate(withDuration: 0.2) {
                    self.navBarTitleLabel.alpha = 1
                    self.crossfadeLabel.alpha = 0
                }
                
            default: break
        }
    }
    
    // MARK: - Interaction
    
    func textFieldDidEndEditing(_ textField: UITextField) {
        crossfadeLabel.text = (textField.text?.isEmpty == true ?
            "vc_create_closed_group_title".localized() :
            textField.text
        )
    }

    fileprivate func tableViewWasTouched(_ tableView: TableView, withView hitView: UIView?) {
        if nameTextField.isFirstResponder {
            nameTextField.resignFirstResponder()
        }
        else if searchBar.isFirstResponder {
            var hitSuperview: UIView? = hitView?.superview
            
            while hitSuperview != nil && hitSuperview != searchBar {
                hitSuperview = hitSuperview?.superview
            }
            
            // If the user hit the cancel button then do nothing (we want to let the cancel
            // button remove the focus or it will instantly refocus)
            if hitSuperview == searchBar { return }
            
            searchBar.resignFirstResponder()
        }
    }
    
    @objc private func close() {
        dismiss(animated: true, completion: nil)
    }
    
    @objc private func createClosedGroup() {
        func showError(title: String, message: String = "") {
            let modal: ConfirmationModal = ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: title,
                    body: .text(message),
                    cancelTitle: "BUTTON_OK".localized(),
                    cancelStyle: .alert_text
                    
                )
            )
            present(modal, animated: true)
        }
        guard
            let name: String = nameTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            name.count > 0
        else {
            return showError(title: "vc_create_closed_group_group_name_missing_error".localized())
        }
        guard name.utf8CString.count < LibSession.sizeMaxGroupNameBytes else {
            return showError(title: "vc_create_closed_group_group_name_too_long_error".localized())
        }
        guard selectedProfiles.count >= 1 else {
            return showError(title: "GROUP_ERROR_NO_MEMBER_SELECTION".localized())
        }
        /// Minus one because we're going to include self later
        guard selectedProfiles.count < (LibSession.sizeMaxGroupMemberCount - 1) else {
            return showError(title: "vc_create_closed_group_too_many_group_members_error".localized())
        }
        let selectedProfiles: [(String, Profile?)] = self.selectedProfiles
            .reduce(into: []) { result, next in result.append((next.key, next.value)) }
        
        ModalActivityIndicatorViewController.present(fromViewController: navigationController!) { [weak self, dependencies] _ in
            let createPublisher: AnyPublisher<SessionThread, Error> = {
                switch dependencies[feature: .updatedGroups] {
                    case true:
                        return MessageSender.createGroup(
                            name: name,
                            description: nil,
                            displayPictureData: nil,
                            members: selectedProfiles,
                            using: dependencies
                        )
                        
                    case false:
                        return MessageSender.createLegacyClosedGroup(
                            name: name,
                            members: selectedProfiles.map { $0.0 }.asSet(),
                            using: dependencies
                        )
                }
            }()
            
            createPublisher
                .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                .receive(on: DispatchQueue.main)
                .sinkUntilComplete(
                    receiveCompletion: { result in
                        switch result {
                            case .finished: break
                            case .failure:
                                self?.dismiss(animated: true, completion: nil) // Dismiss the loader
                                
                                let modal: ConfirmationModal = ConfirmationModal(
                                    targetView: self?.view,
                                    info: ConfirmationModal.Info(
                                        title: "GROUP_CREATION_ERROR_TITLE".localized(),
                                        body: .text("GROUP_CREATION_ERROR_MESSAGE".localized()),
                                        cancelTitle: "BUTTON_OK".localized(),
                                        cancelStyle: .alert_text
                                    )
                                )
                                self?.present(modal, animated: true)
                        }
                    },
                    receiveValue: { thread in
                        SessionApp.presentConversationCreatingIfNeeded(
                            for: thread.id,
                            variant: thread.variant,
                            dismissing: self?.presentingViewController,
                            animated: false,
                            using: dependencies
                        )
                    }
                )
        }
    }
}

extension NewClosedGroupVC: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        self.searchText = searchText
        
        let changeset: StagedChangeset<[ArraySection<Section, Profile>]> = StagedChangeset(
            source: data,
            target: [
                ArraySection(
                    model: .contacts,
                    elements: (searchText.isEmpty ?
                        contactProfiles :
                        contactProfiles
                            .filter { $0.displayName().range(of: searchText, options: [.caseInsensitive]) != nil }
                    )
                )
            ]
        )
        
        self.tableView.reload(
            using: changeset,
            deleteSectionsAnimation: .none,
            insertSectionsAnimation: .none,
            reloadSectionsAnimation: .none,
            deleteRowsAnimation: .none,
            insertRowsAnimation: .none,
            reloadRowsAnimation: .none,
            interrupt: { $0.changeCount > 100 }
        ) { [weak self] updatedData in
            self?.data = updatedData
        }
    }
    
    func searchBarShouldBeginEditing(_ searchBar: UISearchBar) -> Bool {
        searchBar.setShowsCancelButton(true, animated: true)
        return true
    }
    
    func searchBarShouldEndEditing(_ searchBar: UISearchBar) -> Bool {
        searchBar.setShowsCancelButton(false, animated: true)
        return true
    }
    
    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}
