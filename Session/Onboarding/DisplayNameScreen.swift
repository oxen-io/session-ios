// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SessionMessagingKit
import SignalUtilitiesKit

struct DisplayNameScreen: View {
    @EnvironmentObject var host: HostWrapper
    
    @State private var displayName: String = ""
    @State private var error: String? = nil
    
    private let flow: Onboarding.Flow
    
    public init(flow: Onboarding.Flow) {
        self.flow = flow
    }
    
    var body: some View {
        ZStack(alignment: .center) {
            ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary).ignoresSafeArea()
            
            VStack(
                alignment: .leading,
                spacing: 0
            ) {
                Spacer(minLength: 0)
                
                let title: String = (self.flow == .register) ? "displayNamePick".localized() : "displayNameNew".localized()
                Text(title)
                    .bold()
                    .font(.system(size: Values.veryLargeFontSize))
                    .foregroundColor(themeColor: .textPrimary)
                
                Spacer(minLength: 0)
                    .frame(maxHeight: 2 * Values.mediumSpacing)
                
                let explanation: String = (self.flow == .register) ? "displayNameDescription".localized() : "displayNameErrorNew".localized()
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
        guard !ProfileManager.isTooLong(profileName: displayName) else {
            error = "displayNameErrorDescriptionShorter".localized()
            return
        }
        
        // Try to save the user name but ignore the result
        ProfileManager.updateLocal(
            queue: .global(qos: .default),
            profileName: displayName
        )
        
        // If we are not in the registration flow then we are finished and should go straight
        // to the home screen
        guard self.flow == .register else {
            self.flow.completeRegistration()
            
            let homeVC: HomeVC = HomeVC(flow: self.flow)
            self.host.controller?.navigationController?.setViewControllers([ homeVC ], animated: true)
            
            return
        }
        
        // Need to get the PN mode if registering
        let viewController: SessionHostingViewController = SessionHostingViewController(rootView: PNModeScreen(flow: flow))
        viewController.setUpNavBarSessionIcon()
        self.host.controller?.navigationController?.pushViewController(viewController, animated: true)
    }
}

struct DisplayNameView_Previews: PreviewProvider {
    static var previews: some View {
        DisplayNameScreen(flow: .register)
    }
}
