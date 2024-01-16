// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import YYImage
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

class UserListViewModel<T: ProfileAssociated & FetchableRecord>: SessionTableViewModel, NavigatableStateHolder, ObservableTableSource {
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    private let selectedUsersSubject: CurrentValueSubject<Set<WithProfile<T>>, Never> = CurrentValueSubject([])
    
    public let title: String
    public let emptyState: String?
    private let showProfileIcons: Bool
    private let request: (any FetchRequest<T>)
    private let footerTitle: String?
    private let onTapAction: OnTapAction
    private let onSubmitAction: OnSubmitAction
    
    // MARK: - Initialization
    
    init(
        title: String,
        emptyState: String? = nil,
        showProfileIcons: Bool,
        request: (any FetchRequest<T>),
        footerTitle: String? = nil,
        onTap: OnTapAction = .radio,
        onSubmit: OnSubmitAction = .none,
        using dependencies: Dependencies = Dependencies()
    ) {
        self.dependencies = dependencies
        self.title = title
        self.emptyState = emptyState
        self.showProfileIcons = showProfileIcons
        self.request = request
        self.footerTitle = footerTitle
        self.onTapAction = onTap
        self.onSubmitAction = onSubmit
    }
    
    // MARK: - Config
    
    public enum Section: SessionTableSection {
        case users
    }
    
    public enum TableItem: Equatable, Hashable, Differentiable {
        case user(String)
    }

    // MARK: - Content
    
    public indirect enum OnTapAction {
        case callback((UserListViewModel<T>?, WithProfile<T>) -> Void)
        case radio
        case conditionalAction(action: (WithProfile<T>) -> OnTapAction)
        case custom(rightAccessory: (WithProfile<T>) -> SessionCell.Accessory, onTap: (UserListViewModel<T>?, WithProfile<T>) -> Void)
    }
    
    public enum OnSubmitAction {
        case none
        case callback((UserListViewModel<T>?, Set<WithProfile<T>>) throws -> Void)
        case publisher((UserListViewModel<T>?, Set<WithProfile<T>>) -> AnyPublisher<Void, UserListError>)
        
        var hasAction: Bool {
            switch self {
                case .none: return false
                default: return true
            }
        }
    }
    
    var emptyStateTextPublisher: AnyPublisher<String?, Never> { Just(emptyState).eraseToAnyPublisher() }
    
    lazy var observation: TargetObservation = ObservationBuilder
        .databaseObservation(self) { [request] db -> [WithProfile<T>] in
            try request.fetchAllWithProfiles(db)
        }
        .map { [weak self, dependencies, showProfileIcons, onTapAction, selectedUsersSubject] (users: [WithProfile<T>]) -> [SectionModel] in
            return [
                SectionModel(
                    model: .users,
                    elements: users
                        .sorted()
                        .map { userInfo -> SessionCell.Info in
                            func finalAction(for action: OnTapAction) -> OnTapAction {
                                switch action {
                                    case .conditionalAction(let targetAction):
                                        return finalAction(for: targetAction(userInfo))
                                        
                                    default: return action
                                }
                            }
                            func generateAccessory(_ action: OnTapAction) -> SessionCell.Accessory? {
                                switch action {
                                    case .callback: return nil
                                    case .custom(let accessoryGenerator, _): return accessoryGenerator(userInfo)
                                    case .conditionalAction(let targetAction):
                                        return generateAccessory(targetAction(userInfo))
                                        
                                    case .radio:
                                        return .radio(
                                            isSelected: selectedUsersSubject.value.contains(where: { selectedUserInfo in
                                                selectedUserInfo.profileId == userInfo.profileId
                                            })
                                        )
                                }
                            }
                            
                            let finalAction: OnTapAction = finalAction(for: onTapAction)
                            let trailingAccessory: SessionCell.Accessory? = generateAccessory(finalAction)
                            let title: String = (
                                userInfo.profile?.displayName() ??
                                Profile.truncated(id: userInfo.profileId, truncating: .middle)
                            )
                            
                            return SessionCell.Info(
                                id: .user(userInfo.profileId),
                                leadingAccessory: .profile(
                                    id: userInfo.profileId,
                                    profile: userInfo.profile,
                                    profileIcon: (showProfileIcons ? userInfo.value.profileIcon : .none)
                                ),
                                title: title,
                                subtitle: userInfo.itemDescription(using: dependencies),
                                trailingAccessory: trailingAccessory,
                                styling: SessionCell.StyleInfo(
                                    subtitleTintColor: userInfo.itemDescriptionColor(using: dependencies),
                                    allowedSeparators: [],
                                    customPadding: SessionCell.Padding(
                                        top: Values.smallSpacing,
                                        bottom: Values.smallSpacing
                                    ),
                                    backgroundStyle: .noBackgroundEdgeToEdge
                                ),
                                accessibility: Accessibility(
                                    identifier: "Contact",
                                    label: title
                                ),
                                onTap: {
                                    // Trigger any 'onTap' actions
                                    switch finalAction {
                                        case .callback(let callback): callback(self, userInfo)
                                        case .custom(_, let callback): callback(self, userInfo)
                                        case .radio: break
                                        case .conditionalAction(_): return  // Shouldn't hit this case
                                    }
                                    
                                    // Only update the selection if the accessory is a 'radio'
                                    guard trailingAccessory is SessionCell.AccessoryConfig.Radio else { return }
                                    
                                    // Toggle the selection
                                    if !selectedUsersSubject.value.contains(userInfo) {
                                        selectedUsersSubject.send(selectedUsersSubject.value.inserting(userInfo))
                                    }
                                    else {
                                        selectedUsersSubject.send(selectedUsersSubject.value.removing(userInfo))
                                    }
                                    
                                    // Force the table data to be refreshed (the database wouldn't have been changed)
                                    self?.forceRefresh(type: .postDatabaseQuery)
                                }
                            )
                        }
                )
            ]
        }
    
    lazy var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> = selectedUsersSubject
        .prepend([])
        .map { [weak self, dependencies, footerTitle] selectedUsers -> SessionButton.Info? in
            guard self?.onSubmitAction.hasAction == true, let title: String = footerTitle else { return nil }
            
            return SessionButton.Info(
                style: .bordered,
                title: title,
                isEnabled: !selectedUsers.isEmpty,
                onTap: { self?.submit(with: selectedUsers) }
            )
        }
        .eraseToAnyPublisher()
    
    // MARK: - Functions
    
    private func submit(with selectedUsers: Set<WithProfile<T>>) {
        switch onSubmitAction {
            case .none: return
            
            case .callback(let submission):
                do {
                    try submission(self, selectedUsers)
                    selectedUsersSubject.send([])
                    forceRefresh()    // Just in case the filter was impacted
                }
                catch {
                    transitionToScreen(
                        ConfirmationModal(
                            info: ConfirmationModal.Info(
                                title: "ALERT_ERROR_TITLE".localized(),
                                body: .text(error.localizedDescription),
                                cancelTitle: "BUTTON_OK".localized(),
                                cancelStyle: .alert_text
                            )
                        ),
                        transitionType: .present
                    )
                }
                
            case .publisher(let submission):
                transitionToScreen(
                    ModalActivityIndicatorViewController(canCancel: false) { [weak self, dependencies] modalActivityIndicator in
                        submission(self, selectedUsers)
                            .subscribe(on: DispatchQueue.global(qos: .userInitiated), using: dependencies)
                            .receive(on: DispatchQueue.main, using: dependencies)
                            .sinkUntilComplete(
                                receiveCompletion: { result in
                                    switch result {
                                        case .finished:
                                            self?.selectedUsersSubject.send([])
                                            self?.forceRefresh()    // Just in case the filter was impacted
                                            modalActivityIndicator.dismiss(completion: {})
                                            
                                        case .failure(let error):
                                            modalActivityIndicator.dismiss(completion: {
                                                self?.transitionToScreen(
                                                    ConfirmationModal(
                                                        info: ConfirmationModal.Info(
                                                            title: "ALERT_ERROR_TITLE".localized(),
                                                            body: .text(error.localizedDescription),
                                                            cancelTitle: "BUTTON_OK".localized(),
                                                            cancelStyle: .alert_text
                                                        )
                                                    ),
                                                    transitionType: .present
                                                )
                                            })
                                    }
                                }
                            )
                    },
                    transitionType: .present
                )
        }
    }
}

// MARK: - UserListError

public enum UserListError: LocalizedError {
    case error(String)
    
    public var errorDescription: String? {
        switch self {
            case .error(let content): return content
        }
    }
}
