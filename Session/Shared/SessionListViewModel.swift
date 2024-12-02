// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

// MARK: - Listable

protocol Listable: Equatable, Hashable, Differentiable {
    var title: String { get }
    var subtitle: String? { get }
}

extension Listable {
    var subtitle: String? { nil }
}

// MARK: - SessionListViewModel<T>

class SessionListViewModel<T: Listable>: SessionTableViewModel, NavigationItemSource, NavigatableStateHolder, ObservableTableSource {
    typealias TableItem = T
    
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    private let selectedOptionsSubject: CurrentValueSubject<Set<T>, Never>
    
    let title: String
    private let options: [T]
    private let behaviour: Behaviour
    
    // MARK: - Initialization
    
    init(
        title: String,
        options: [T],
        behaviour: Behaviour,
        using dependencies: Dependencies
    ) {
        self.title = title
        self.selectedOptionsSubject = {
            switch behaviour {
                case .autoDismiss(let initial, _), .singleSelect(let initial, _, _): return CurrentValueSubject([initial])
                case .multiSelect(let initial, _, _): return CurrentValueSubject(initial)
            }
        }()
        self.options = options
        self.behaviour = behaviour
        self.dependencies = dependencies
    }
    
    // MARK: - Config
    
    public enum Behaviour {
        case autoDismiss(initialSelection: T, onOptionSelected: ((T) -> Void)?)
        case singleSelect(initialSelection: T, onOptionSelected: ((T) -> Void)?, onSaved: ((T) -> Void)?)
        case multiSelect(initialSelection: Set<T>, onOptionSelected: ((Set<T>) -> Void)?, onSaved: ((Set<T>) -> Void)?)
        
        static func singleSelect(initialSelection: T, onSaved: ((T) -> Void)?) -> Behaviour {
            return .singleSelect(initialSelection: initialSelection, onOptionSelected: nil, onSaved: onSaved)
        }
        
        static func multiSelect(initialSelection: Set<T>, onSaved: ((Set<T>) -> Void)?) -> Behaviour {
            return .multiSelect(initialSelection: initialSelection, onOptionSelected: nil, onSaved: onSaved)
        }
    }
    
    enum NavItem: Equatable {
        case cancel
        case save
    }
    
    public enum Section: SessionTableSection {
        case content
    }
    
    // MARK: - Navigation
    
    lazy var leftNavItems: AnyPublisher<[SessionNavItem<NavItem>], Never> = {
        switch behaviour {
            case .autoDismiss: return Just([]).eraseToAnyPublisher()
            case .singleSelect, .multiSelect:
                return Just([
                    SessionNavItem(
                        id: .cancel,
                        systemItem: .cancel,
                        accessibilityIdentifier: "Cancel button"
                    ) { [weak self] in self?.dismissScreen() }
                ]).eraseToAnyPublisher()
        }
    }()

    lazy var rightNavItems: AnyPublisher<[SessionNavItem<NavItem>], Never> = {
        switch behaviour {
            case .autoDismiss: return Just([]).eraseToAnyPublisher()
            case .singleSelect, .multiSelect:
                return selectedOptionsSubject
                    .removeDuplicates()
                    .map { [behaviour] currentSelection -> (isChanged: Bool, currentSelection: Set<T>) in
                        switch behaviour {
                            case .autoDismiss(let initialSelection, _), .singleSelect(let initialSelection, _, _):
                                return (([initialSelection] != currentSelection), currentSelection)
                                
                            case .multiSelect(let initialSelection, _, _):
                                return ((initialSelection != currentSelection), currentSelection)
                        }
                    }
                    .map { [behaviour] isChanged, currentSelection in
                        guard isChanged, let firstSelection: T = currentSelection.first else { return [] }
                        
                        return [
                            SessionNavItem(
                                id: .save,
                                systemItem: .save,
                                accessibilityIdentifier: "Save button"
                            ) { [weak self] in
                                switch behaviour {
                                    case .autoDismiss: return
                                    case .singleSelect(_, _, let onSaved): onSaved?(firstSelection)
                                    case .multiSelect(_, _, let onSaved): onSaved?(currentSelection)
                                }
                                
                                self?.dismissScreen()
                            }
                        ]
                    }
                    .eraseToAnyPublisher()
        }
    }()
    
    // MARK: - Content
    
    lazy var observation: TargetObservation = ObservationBuilder
        .subject(selectedOptionsSubject)
        .map { [weak self, options, behaviour] currentSelections -> [SectionModel] in
            return [
                SectionModel(
                    model: .content,
                    elements: options
                        .map { option in
                            SessionCell.Info(
                                id: option,
                                title: option.title,
                                subtitle: option.subtitle,
                                trailingAccessory: .radio(
                                    isSelected: currentSelections.contains(option)
                                ),
                                onTap: {
                                    switch (behaviour, currentSelections.contains(option)) {
                                        case (.autoDismiss(_, let onOptionSelected), _):
                                            onOptionSelected?(option)
                                            self?.dismissScreen()
                                            
                                        case (.singleSelect(_, let onOptionSelected, _), _):
                                            self?.selectedOptionsSubject.send([option])
                                            onOptionSelected?(option)
                                            
                                        case (.multiSelect(_, let onOptionSelected, _), true):
                                            let updatedSelection: Set<T> = currentSelections.removing(option)
                                            self?.selectedOptionsSubject.send(updatedSelection)
                                            onOptionSelected?(updatedSelection)
                                            
                                        case (.multiSelect(_, let onOptionSelected, _), false):
                                            let updatedSelection: Set<T> = currentSelections.inserting(option)
                                            self?.selectedOptionsSubject.send(updatedSelection)
                                            onOptionSelected?(updatedSelection)
                                    }
                                }
                            )
                        }
                )
            ]
        }
}
