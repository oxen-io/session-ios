// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SignalUtilitiesKit
import SessionUtilitiesKit
import AVFoundation

struct QRCodeScreen: View {
    @EnvironmentObject var host: HostWrapper
    let dependencies: Dependencies
    
    @State var tabIndex = 0
    @State private var accountId: String = ""
    @State private var errorString: String? = nil
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
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
                    MyQRCodeScreen(using: dependencies)
                }
                else {
                    ScanQRCodeScreen(
                        $accountId,
                        error: $errorString,
                        continueAction: continueWithAccountId,
                        using: dependencies
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
            dependencies[singleton: .app].presentConversationCreatingIfNeeded(
                for: hexEncodedPublicKey,
                variant: .contact,
                action: .compose,
                dismissing: self.host.controller,
                animated: false
            )
        }
    }
    
    func continueWithAccountId(onSuccess: (() -> ())?, onError: (() -> ())?) {
        let hexEncodedPublicKey = accountId
        startNewPrivateChatIfPossible(with: hexEncodedPublicKey, onError: onError)
    }
}

struct MyQRCodeScreen: View {
    let dependencies: Dependencies
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    var body: some View{
        VStack(
            spacing: Values.mediumSpacing
        ) {
            QRCodeView(
                string: dependencies[cache: .general].sessionId.hexString,
                hasBackground: false,
                logo: "SessionWhite40", // stringlint:ignore
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
    QRCodeScreen(using: Dependencies.createEmpty())
}
