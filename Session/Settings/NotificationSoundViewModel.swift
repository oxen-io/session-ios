// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import DifferenceKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

class NotificationSoundViewModel: SessionTableViewModel, NavigationItemSource, NavigatableStateHolder, ObservableTableSource {
    typealias TableItem = Preferences.Sound
    
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    
    private let originalSelection: Preferences.Sound
    private var audioPlayer: OWSAudioPlayer?
    private var currentSelection: CurrentValueSubject<Preferences.Sound, Never>
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        let originalSelection: Preferences.Sound = dependencies[singleton: .storage, key: .defaultNotificationSound]
            .defaulting(to: .defaultNotificationSound)
        self.originalSelection = originalSelection
        self.currentSelection = CurrentValueSubject(originalSelection)
    }
    
    deinit {
        self.audioPlayer?.stop()
        self.audioPlayer = nil
    }
    
    // MARK: - Config
    
    enum NavItem: Equatable {
        case cancel
        case save
    }
    
    public enum Section: SessionTableSection {
        case content
    }
    
    // MARK: - Navigation
    
    lazy var leftNavItems: AnyPublisher<[SessionNavItem<NavItem>], Never> = [
        SessionNavItem(
            id: .cancel,
            systemItem: .cancel,
            accessibilityIdentifier: "Cancel button"
        ) { [weak self] in self?.dismissScreen() }
    ]

    lazy var rightNavItems: AnyPublisher<[SessionNavItem<NavItem>], Never> = currentSelection
        .removeDuplicates()
        .map { [originalSelection] currentSelection in (originalSelection != currentSelection) }
        .map { isChanged in
            guard isChanged else { return [] }
            
            return [
                SessionNavItem(
                    id: .save,
                    systemItem: .save,
                    accessibilityIdentifier: "Save button"
                ) { [weak self] in
                    self?.saveChanges()
                    self?.dismissScreen()
                }
            ]
        }
       .eraseToAnyPublisher()
    
    // MARK: - Content
    
    let title: String = "notificationsSound".localized()
    
    lazy var observation: TargetObservation = ObservationBuilder
        .subject(currentSelection)
        .map { [weak self] selectedSound in
            return [
                SectionModel(
                    model: .content,
                    elements: Preferences.Sound.notificationSounds
                        .map { sound in
                            SessionCell.Info(
                                id: sound,
                                title: {
                                    guard sound != .note else {
                                        return "\(sound.displayName) (default)"
                                    }
                                    
                                    return sound.displayName
                                }(),
                                trailingAccessory: .radio(
                                    isSelected: (selectedSound == sound)
                                ),
                                onTap: {
                                    self?.currentSelection.send(sound)
                                    self?.audioPlayer?.stop()   // Stop the old sound immediately
                                    
                                    // Play the sound (to prevent UI lag we dispatch after a short delay)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
                                        self?.audioPlayer = Preferences.Sound.audioPlayer(
                                            for: sound,
                                            behavior: .playback
                                        )
                                        self?.audioPlayer?.isLooping = false
                                        self?.audioPlayer?.play()
                                    }
                                }
                            )
                        }
                )
            ]
        }
    
    // MARK: - Functions
    
    private func saveChanges() {
        dependencies[singleton: .storage].writeAsync { [currentSelection] db in
            db[.defaultNotificationSound] = currentSelection.value
        }
    }
}
