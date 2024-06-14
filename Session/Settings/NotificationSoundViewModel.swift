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
    
    // FIXME: Remove `threadId` once we ditch the per-thread notification sound
    private let threadId: String?
    private var audioPlayer: OWSAudioPlayer?
    private var storedSelection: Preferences.Sound?
    private var currentSelection: CurrentValueSubject<Preferences.Sound?, Never> = CurrentValueSubject(nil)
    
    // MARK: - Initialization
    
    init(threadId: String? = nil, using dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
        self.threadId = threadId
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
        .map { [weak self] currentSelection in (self?.storedSelection != currentSelection) }
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
        .databaseObservation(self) { [threadId] db -> Preferences.Sound in
            guard let threadId: String = threadId else {
                return db[.defaultNotificationSound]
                    .defaulting(to: .defaultNotificationSound)
            }
            
            return try SessionThread
                .filter(id: threadId)
                .select(.notificationSound)
                .asRequest(of: Preferences.Sound.self)
                .fetchOne(db)
                .defaulting(
                    to: db[.defaultNotificationSound]
                        .defaulting(to: .defaultNotificationSound)
                )
        }
        .map { [weak self] storedSelection in
            self?.storedSelection = storedSelection
            self?.currentSelection.send(self?.currentSelection.value ?? storedSelection)
            
            return [
                SectionModel(
                    model: .content,
                    elements: Preferences.Sound.notificationSounds
                        .map { sound in
                            SessionCell.Info(
                                id: sound,
                                title: {
                                    guard sound != .note else {
                                        return String(
                                            format: "SETTINGS_AUDIO_DEFAULT_TONE_LABEL_FORMAT".localized(),
                                            sound.displayName
                                        )
                                    }
                                    
                                    return sound.displayName
                                }(),
                                rightAccessory: .radio(
                                    isSelected: { (self?.currentSelection.value == sound) }
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
        guard let currentSelection: Preferences.Sound = self.currentSelection.value else { return }

        let threadId: String? = self.threadId
        
        Storage.shared.writeAsync { db in
            guard let threadId: String = threadId else {
                db[.defaultNotificationSound] = currentSelection
                return
            }
            
            try SessionThread
                .filter(id: threadId)
                .updateAll(
                    db,
                    SessionThread.Columns.notificationSound.set(to: currentSelection)
                )
        }
    }
}
