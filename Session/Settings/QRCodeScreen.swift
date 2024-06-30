// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SignalUtilitiesKit
import SessionUtilitiesKit
import AVFoundation

struct QRCodeScreen: View {
    @EnvironmentObject var host: HostWrapper
    
    @State var tabIndex = 0
    @State private var accountId: String = ""
    @State private var errorString: String? = nil
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(
                spacing: 0
            ){
                CustomTopTabBar(
                    tabIndex: $tabIndex,
                    tabTitles: [
                        "view".localized(),
                        "scan".localized()
                    ]
                ).frame(maxWidth: .infinity)
                    
                if tabIndex == 0 {
                    MyQRCodeScreen()
                }
                else {
                    ScanQRCodeScreen(
                        $accountId,
                        error: $errorString,
                        continueAction: continueWithAccountId
                    )
                }
            }
        }
        .backgroundColor(themeColor: .backgroundPrimary)
    }
    
    fileprivate func startNewPrivateChatIfPossible(with hexEncodedPublicKey: String, onError: (() -> ())?) {
        if !KeyPair.isValidHexEncodedPublicKey(candidate: hexEncodedPublicKey) {
            errorString = "qrNotAccountId".localized()
        }
        else {
            SessionApp.presentConversationCreatingIfNeeded(
                for: hexEncodedPublicKey,
                variant: .contact,
                action: .compose,
                dismissing: self.host.controller,
                animated: false
            )
        }
    }
    
    func continueWithAccountId(onError: (() -> ())?) {
        let hexEncodedPublicKey = accountId
        startNewPrivateChatIfPossible(with: hexEncodedPublicKey, onError: onError)
    }
}

struct MyQRCodeScreen: View {
    var body: some View{
        VStack(
            spacing: Values.mediumSpacing
        ) {
            QRCodeView(
                string: getUserHexEncodedPublicKey(),
                hasBackground: false,
                logo: "SessionWhite40",
                themeStyle: ThemeManager.currentTheme.interfaceStyle
            )
            .accessibility(
                Accessibility(
                    identifier: "QR code",
                    label: "QR code"
                )
            )
            .aspectRatio(1, contentMode: .fit)
            
            Text("accountIdYoursDescription".localized())
                .font(.system(size: Values.verySmallFontSize))
                .foregroundColor(themeColor: .textSecondary)
                .multilineTextAlignment(.center)
            
            Spacer()
        }
        .padding(.horizontal, Values.mediumSpacing)
        .padding(.all, Values.veryLargeSpacing)
    }
}

#Preview {
    QRCodeScreen()
}
