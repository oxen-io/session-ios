// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SignalUtilitiesKit
import SessionUtilitiesKit

struct InviteAFriendScreen: View {
    @EnvironmentObject var host: HostWrapper
    
    @State private var copied: Bool = false
    private let accountId: String
    
    static private let cornerRadius: CGFloat = 13
    
    init(accountId: String) {
        self.accountId = accountId
    }
    
    var body: some View {
        ZStack(alignment: .center) {
            VStack(
                alignment: .center,
                spacing: Values.mediumSpacing
            ) {
                Text(accountId)
                    .font(.system(size: Values.smallFontSize))
                    .multilineTextAlignment(.center)
                    .foregroundColor(themeColor: .textPrimary)
                    .accessibility(
                        Accessibility(
                            identifier: "Account ID"
                        )
                    )
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.all, Values.largeSpacing)
                    .overlay(
                        RoundedRectangle(
                            cornerSize: CGSize(
                                width: Self.cornerRadius,
                                height: Self.cornerRadius
                            )
                        )
                        .stroke(themeColor: .borderSeparator)
                    )
                
                Text(
                    "shareAccountIdDescription"
                        .put(key: "app_name", value: Constants.app_name)
                        .localized()
                )
                .font(.system(size: Values.verySmallFontSize))
                .multilineTextAlignment(.center)
                .foregroundColor(themeColor: .textSecondary)
                .padding(.horizontal, Values.smallSpacing)
                
                HStack(
                    alignment: .center,
                    spacing: 0
                ) {
                    Button {
                        share()
                    } label: {
                        Text("share".localized())
                            .bold()
                            .font(.system(size: Values.mediumFontSize))
                            .foregroundColor(themeColor: .textPrimary)
                            .frame(
                                maxWidth: .infinity,
                                minHeight: Values.mediumButtonHeight,
                                alignment: .center
                            )
                            .overlay(
                                Capsule()
                                    .stroke(themeColor: .textPrimary)
                            )
                    }
                    .accessibility(
                        Accessibility(
                            identifier: "Share button",
                            label: "Share button"
                        )
                    )
                    .frame(maxWidth: .infinity)
                    
                    Spacer(minLength: Values.mediumSpacing)
                    
                    Button {
                        copyAccountId()
                    } label: {
                        let buttonTitle: String = self.copied ? "copied".localized() : "copy".localized()
                        Text(buttonTitle)
                            .bold()
                            .font(.system(size: Values.mediumFontSize))
                            .foregroundColor(themeColor: .textPrimary)
                            .frame(
                                maxWidth: .infinity,
                                minHeight: Values.mediumButtonHeight,
                                alignment: .center
                            )
                            .overlay(
                                Capsule()
                                    .stroke(themeColor: .textPrimary)
                            )
                    }
                    .accessibility(
                        Accessibility(
                            identifier: "Copy button",
                            label: "Copy button"
                        )
                    )
                    .frame(maxWidth: .infinity)
                }
                
                Spacer()
            }
            .padding(Values.largeSpacing)
        }
        .backgroundColor(themeColor: .backgroundSecondary)
    }
    
    private func copyAccountId() {
        UIPasteboard.general.string = self.accountId
        self.copied = true
    }
    
    private func share() {
        let invitation: String = "Hey, I've been using Session to chat with complete privacy and security. Come join me! My Account ID is \n\n\(self.accountId) \n\nDownload it at https://getsession.org/"
        let shareVC: UIActivityViewController = UIActivityViewController(
            activityItems: [ invitation ],
            applicationActivities: nil
        )
        
        if UIDevice.current.isIPad {
            shareVC.popoverPresentationController?.permittedArrowDirections = []
            shareVC.popoverPresentationController?.sourceView = self.host.controller?.view
            shareVC.popoverPresentationController?.sourceRect = (self.host.controller?.view.bounds ?? UIScreen.main.bounds)
        }
        
        self.host.controller?.present(
            shareVC,
            animated: true
        )
    }
}

#Preview {
    InviteAFriendScreen(accountId: "050000000000000000000000000000000000000000000000000000000000000000")
}
