// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SessionMessagingKit
import SignalUtilitiesKit
import SessionUtilitiesKit

struct DisplayNameScreen: View {
    @EnvironmentObject var host: HostWrapper
    
    @State private var displayName: String = ""
    @State private var error: String? = nil
    
    private let dependencies: Dependencies
    
    public init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    var body: some View {
        ZStack(alignment: .center) {
            ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary).ignoresSafeArea()
            
            VStack(
                alignment: .leading,
                spacing: 0
            ) {
                Spacer(minLength: 0)
                
                let title: String = (dependencies[cache: .onboarding].initialFlow == .register ?
                    "displayNamePick".localized() :
                    "displayNameNew".localized()
                )
                Text(title)
                    .bold()
                    .font(.system(size: Values.veryLargeFontSize))
                    .foregroundColor(themeColor: .textPrimary)
                
                Spacer(minLength: 0)
                    .frame(maxHeight: 2 * Values.mediumSpacing)
                
                let explanation: String = (dependencies[cache: .onboarding].initialFlow == .register ?
                    "displayNameDescription".localized() :
                    "displayNameErrorNew".localized()
                )
                Text(explanation)
                    .font(.system(size: Values.smallFontSize))
                    .foregroundColor(themeColor: .textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                
                Spacer(minLength: 0)
                    .frame(maxHeight: 2 * Values.mediumSpacing)
                
                SessionTextField(
                    $displayName,
                    placeholder: "displayNameEnter".localized(),
                    error: $error, 
                    accessibility: Accessibility(
                        identifier: "Enter display name",
                        label: "Enter display name"
                    )
                )
                
                Spacer(minLength: 0)
                    .frame(maxHeight: Values.massiveSpacing)
                
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Values.veryLargeSpacing)
            .padding(.bottom, Values.largeButtonHeight)
            
            VStack() {
                Spacer(minLength: 0)
                
                Button {
                    register()
                } label: {
                    Text("theContinue".localized())
                        .bold()
                        .font(.system(size: Values.smallFontSize))
                        .foregroundColor(themeColor: .sessionButton_text)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: Values.largeButtonHeight,
                            alignment: .center
                        )
                        .overlay(
                            Capsule()
                                .stroke(themeColor: .sessionButton_border)
                        )
                }
                .accessibility(
                    Accessibility(
                        identifier: "Continue",
                        label: "Continue"
                    )
                )
                .padding(.horizontal, Values.massiveSpacing)
            }
            .padding(.vertical, Values.mediumSpacing)
        }
    }
    
    private func register() {
        let displayName = self.displayName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !displayName.isEmpty else {
            error = "displayNameErrorDescription".localized()
            return
        }
        guard !Profile.isTooLong(profileName: displayName) else {
            error = "displayNameErrorDescriptionShorter".localized()
            return
        }
        
        // Store the new name in the onboarding cache
        dependencies.mutate(cache: .onboarding) { $0.setDisplayName(displayName) }
        
        // If we are not in the registration flow then we are finished and should go straight
        // to the home screen
        guard dependencies[cache: .onboarding].initialFlow == .register else {
            return dependencies.mutate(cache: .onboarding) { [dependencies] onboarding in
                // If the `initialFlow` is `none` then it means the user is just providing a missing displayName
                // and so shouldn't change the APNS setting, otherwise we should base it on the users selection
                // during the onboarding process
                let shouldSyncPushTokens: Bool = (onboarding.initialFlow != .none && onboarding.useAPNS)
                
                onboarding.completeRegistration {
                    // Trigger the 'SyncPushTokensJob' directly as we don't want to wait for paths to build
                    // before requesting the permission from the user
                    if shouldSyncPushTokens { SyncPushTokensJob.run(uploadOnlyIfStale: false, using: dependencies) }
                    
                    // Go to the home screen
                    let homeVC: HomeVC = HomeVC(using: dependencies)
                    dependencies[singleton: .app].setHomeViewController(homeVC)
                    self.host.controller?.navigationController?.setViewControllers([ homeVC ], animated: true)
                }
            }
        }
        
        // Need to get the PN mode if registering
        let viewController: SessionHostingViewController = SessionHostingViewController(
            rootView: PNModeScreen(using: dependencies)
        )
        viewController.setUpNavBarSessionIcon(using: dependencies)
        self.host.controller?.navigationController?.pushViewController(viewController, animated: true)
    }
}

struct DisplayNameView_Previews: PreviewProvider {
    static var previews: some View {
        DisplayNameScreen(using: Dependencies.createEmpty())
    }
}
