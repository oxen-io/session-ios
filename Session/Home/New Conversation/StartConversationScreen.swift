// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SignalUtilitiesKit
import SessionUtilitiesKit

struct StartConversationScreen: View {
    @EnvironmentObject var host: HostWrapper
    private let dependencies: Dependencies
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(
                    alignment: .leading,
                    spacing: Values.smallSpacing
                ) {
                    VStack(
                        alignment: .center,
                        spacing: 0
                    ) {
                        let title: String = "messageNew"
                            .putNumber(1)
                            .localized()
                        NewConversationCell(
                            image: "Message", // stringlint:ignore
                            title: title
                        ) {
                            let viewController: SessionHostingViewController = SessionHostingViewController(
                                rootView: NewMessageScreen(using: dependencies)
                            )
                            viewController.setNavBarTitle(title)
                            viewController.setUpDismissingButton(on: .right)
                            self.host.controller?.navigationController?.pushViewController(viewController, animated: true)
                        }
                        .accessibility(
                            Accessibility(
                                identifier: "New direct message",
                                label: "New direct message"
                            )
                        )
                        
                        Line(color: .borderSeparator)
                            .padding(.leading, 38 + Values.smallSpacing)
                            .padding(.trailing, -Values.largeSpacing)
                        
                        NewConversationCell(
                            image: "Group",
                            title: "groupCreate".localized()
                        ) {
                            let viewController = NewClosedGroupVC(using: dependencies)
                            self.host.controller?.navigationController?.pushViewController(viewController, animated: true)
                        }
                        .accessibility(
                            Accessibility(
                                identifier: "Create group",
                                label: "Create group"
                            )
                        )
                        
                        Line(color: .borderSeparator)
                            .padding(.leading, 38 + Values.smallSpacing)
                            .padding(.trailing, -Values.largeSpacing)
                        
                        NewConversationCell(
                            image: "Globe", // stringlint:ignore
                            title: "communityJoin".localized()
                        ) {
                            let viewController = JoinOpenGroupVC(using: dependencies)
                            self.host.controller?.navigationController?.pushViewController(viewController, animated: true)
                        }
                        .accessibility(
                            Accessibility(
                                identifier: "Join community",
                                label: "Join community"
                            )
                        )
                        
                        Line(color: .borderSeparator)
                            .padding(.leading, 38 + Values.smallSpacing)
                            .padding(.trailing, -Values.largeSpacing)
                        
                        NewConversationCell(
                            image: "icon_invite", // stringlint:ignore
                            title: "sessionInviteAFriend".localized()
                        ) {
                            let viewController: SessionHostingViewController = SessionHostingViewController(
                                rootView: InviteAFriendScreen(accountId: dependencies[cache: .general].sessionId.hexString)
                            )
                            viewController.setNavBarTitle("sessionInviteAFriend".localized())
                            viewController.setUpDismissingButton(on: .right)
                            self.host.controller?.navigationController?.pushViewController(viewController, animated: true)
                        }
                        .accessibility(
                            Accessibility(
                                identifier: "Invite friend button",
                                label: "Invite friend button"
                            )
                        )
                    }
                    .padding(.bottom, Values.mediumSpacing)
                    
                    Text("accountIdYours".localized())
                        .font(.system(size: Values.mediumLargeFontSize))
                        .foregroundColor(themeColor: .textPrimary)
                    
                    Text("qrYoursDescription".localized())
                        .font(.system(size: Values.verySmallFontSize))
                        .foregroundColor(themeColor: .textSecondary)
                    
                    QRCodeView(
                        string: dependencies[cache: .general].sessionId.hexString,
                        hasBackground: false,
                        logo: "SessionWhite40", // stringlint:ignore
                        themeStyle: ThemeManager.currentTheme.interfaceStyle
                    )
                    .aspectRatio(1, contentMode: .fit)
                    .padding(.vertical, Values.smallSpacing)
                }
                .padding(.horizontal, Values.largeSpacing)
            }
        }
        .backgroundColor(themeColor: .backgroundSecondary)
    }
}

fileprivate struct NewConversationCell: View {
    let image: String
    let title: String
    let action: () -> ()
    
    var body: some View {
        Button {
            action()
        } label: {
            HStack(
                alignment: .center,
                spacing: Values.smallSpacing
            ) {
                ZStack(alignment: .center) {
                    Image(image)
                        .renderingMode(.template)
                        .foregroundColor(themeColor: .textPrimary)
                        .frame(width: 25, height: 24, alignment: .bottom)
                }
                .frame(width: 38, height: 38, alignment: .leading)
                
                Text(title)
                    .font(.system(size: Values.mediumLargeFontSize))
                    .foregroundColor(themeColor: .textPrimary)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
            }
            .frame(height: 55)
        }
    }
}

#Preview {
    StartConversationScreen(using: Dependencies.createEmpty())
}
