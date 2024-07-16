// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import SessionUIKit
import SessionUtilitiesKit

// MARK: - NavigationItemSource

protocol NavigationItemSource {
    associatedtype NavItem: Equatable
    
    var leftNavItems: AnyPublisher<[SessionNavItem<NavItem>], Never> { get }
    var rightNavItems: AnyPublisher<[SessionNavItem<NavItem>], Never> { get }
}

// MARK: - Defaults

extension NavigationItemSource {
    var leftNavItems: AnyPublisher<[SessionNavItem<NavItem>], Never> { Just([]).eraseToAnyPublisher() }
    var rightNavItems: AnyPublisher<[SessionNavItem<NavItem>], Never> { Just([]).eraseToAnyPublisher() }
}

// MARK: - Bindings

extension NavigationItemSource {
    func setupBindings(
        viewController: UIViewController,
        disposables: inout Set<AnyCancellable>
    ) {
        self.leftNavItems
            .receive(on: DispatchQueue.main)
            .sink { [weak viewController] items in
                viewController?.navigationItem.setLeftBarButtonItems(
                    items.map { item -> DisposableBarButtonItem in
                        let buttonItem: DisposableBarButtonItem = item.createBarButtonItem()
                        buttonItem.themeTintColor = .textPrimary

                        buttonItem.tapPublisher
                            .map { _ in item.id }
                            .sink(receiveValue: { _ in item.action?() })
                            .store(in: &buttonItem.disposables)

                        return buttonItem
                    },
                    animated: true
                )
            }
            .store(in: &disposables)

        self.rightNavItems
            .receive(on: DispatchQueue.main)
            .sink { [weak viewController] items in
                viewController?.navigationItem.setRightBarButtonItems(
                    items.map { item -> DisposableBarButtonItem in
                        let buttonItem: DisposableBarButtonItem = item.createBarButtonItem()
                        buttonItem.themeTintColor = .textPrimary

                        buttonItem.tapPublisher
                            .map { _ in item.id }
                            .sink(receiveValue: { _ in item.action?() })
                            .store(in: &buttonItem.disposables)

                        return buttonItem
                    },
                    animated: true
                )
            }
            .store(in: &disposables)
    }
}
