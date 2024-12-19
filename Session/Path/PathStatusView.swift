// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import Combine
import SessionUIKit
import SessionSnodeKit
import SessionMessagingKit
import SessionUtilitiesKit

final class PathStatusView: UIView {
    enum Size {
        case small
        case large
        
        var pointSize: CGFloat {
            switch self {
                case .small: return 8
                case .large: return 16
            }
        }
        
        func offset(for interfaceStyle: UIUserInterfaceStyle) -> CGFloat {
            switch self {
                case .small: return (interfaceStyle == .light ? 6 : 8)
                case .large: return (interfaceStyle == .light ? 6 : 8)
            }
        }
    }
    
    // MARK: - Initialization
    
    private let dependencies: Dependencies
    private let size: Size
    private var disposables: Set<AnyCancellable> = Set()
    
    init(size: Size = .small, using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.size = size
        
        super.init(frame: .zero)
        
        setUpViewHierarchy()
        registerObservers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Layout
    
    private func setUpViewHierarchy() {
        layer.cornerRadius = (self.size.pointSize / 2)
        layer.masksToBounds = false
        self.set(.width, to: self.size.pointSize)
        self.set(.height, to: self.size.pointSize)
    }
    
    // MARK: - Functions

    private func registerObservers() {
        /// Register for status updates (will be called immediately with current status)
        dependencies[cache: .libSessionNetwork].networkStatus
            .subscribe(on: DispatchQueue.global(qos: .background), using: dependencies)
            .receive(on: DispatchQueue.main, using: dependencies)
            .sink(
                receiveCompletion: { [weak self] _ in
                    /// If the stream completes it means the network cache was reset in which case we want to
                    /// re-register for updates in the next run loop (as the new cache should be created by then)
                    DispatchQueue.global(qos: .background).async {
                        self?.registerObservers()
                    }
                },
                receiveValue: { [weak self] status in self?.setStatus(to: status) }
            )
            .store(in: &disposables)
    }

    private func setStatus(to status: NetworkStatus) {
        themeBackgroundColor = status.themeColor
        layer.themeShadowColor = status.themeColor
        layer.shadowOffset = CGSize(width: 0, height: 0.8)
        layer.shadowPath = UIBezierPath(
            ovalIn: CGRect(
                origin: CGPoint.zero,
                size: CGSize(width: self.size.pointSize, height: self.size.pointSize)
            )
        ).cgPath
        
        ThemeManager.onThemeChange(observer: self) { [weak self] theme, _ in
            self?.layer.shadowOpacity = (theme.interfaceStyle == .light ? 0.4 : 1)
            self?.layer.shadowRadius = (self?.size.offset(for: theme.interfaceStyle) ?? 0)
        }
    }
}

public extension NetworkStatus {
    var themeColor: ThemeValue {
        switch self {
            case .unknown: return .path_unknown
            case .connecting: return .path_connecting
            case .connected: return .path_connected
            case .disconnected: return .path_error
        }
    }
}
