// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

protocol SessionTableViewModel: AnyObject, SectionedTableData {
    var dependencies: Dependencies { get }
    
    var title: String { get }
    var subtitle: String? { get }
    var initialLoadMessage: String? { get }
    var cellType: SessionTableViewCellType { get }
    var bannerInfo: AnyPublisher<InfoBanner.Info?, Never> { get }
    var emptyStateTextPublisher: AnyPublisher<String?, Never> { get }
    var state: TableDataState<Section, TableItem> { get }
    var footerView: AnyPublisher<UIView?, Never> { get }
    var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> { get }
    
    // MARK: - Functions
    
    func canEditRow(at indexPath: IndexPath) -> Bool
    func leadingSwipeActionsConfiguration(forRowAt indexPath: IndexPath, in tableView: UITableView, of viewController: UIViewController) -> UISwipeActionsConfiguration?
    func trailingSwipeActionsConfiguration(forRowAt indexPath: IndexPath, in tableView: UITableView, of viewController: UIViewController) -> UISwipeActionsConfiguration?
}

extension SessionTableViewModel {
    var subtitle: String? { nil }
    var initialLoadMessage: String? { nil }
    var cellType: SessionTableViewCellType { .general }
    var bannerInfo: AnyPublisher<InfoBanner.Info?, Never> { Just(nil).eraseToAnyPublisher() }
    var emptyStateTextPublisher: AnyPublisher<String?, Never> { Just(nil).eraseToAnyPublisher() }
    var tableData: [SectionModel] { state.tableData }
    var footerView: AnyPublisher<UIView?, Never> { Just(nil).eraseToAnyPublisher() }
    var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> { Just(nil).eraseToAnyPublisher() }
    
    // MARK: - Functions
    
    func updateTableData(_ updatedData: [SectionModel]) { state.updateTableData(updatedData) }
    
    func canEditRow(at indexPath: IndexPath) -> Bool { false }
    func leadingSwipeActionsConfiguration(forRowAt indexPath: IndexPath, in tableView: UITableView, of viewController: UIViewController) -> UISwipeActionsConfiguration? { nil }
    func trailingSwipeActionsConfiguration(forRowAt indexPath: IndexPath, in tableView: UITableView, of viewController: UIViewController) -> UISwipeActionsConfiguration? { nil }
}

// MARK: - SessionTableViewCellType

enum SessionTableViewCellType: CaseIterable {
    case general
    case fullConversation
    
    var viewType: UITableViewCell.Type {
        switch self {
            case .general: return SessionCell.self
            case .fullConversation: return FullConversationCell.self
        }
    }
}
