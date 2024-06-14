// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit
import SessionSnodeKit

struct NewMessageScreen: View {
    @EnvironmentObject var host: HostWrapper
    
    @State var tabIndex = 0
    @State private var accountIdOrONS: String
    @State private var errorString: String? = nil
    
    init(accountId: String = "") {
        self.accountIdOrONS = accountId
    }
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(
                spacing: 0
            ){
                CustomTopTabBar(
                    tabIndex: $tabIndex,
                    tabTitles: [
                        "accountIdEnter".localized(),
                        "qrScan".localized()
                    ]
                ).frame(maxWidth: .infinity)
                    
                if tabIndex == 0 {
                    EnterAccountIdScreen(
                        accountIdOrONS: $accountIdOrONS,
                        error: $errorString, 
                        continueAction: continueWithAccountIdOrONS
                    )
                }
                else {
                    ScanQRCodeScreen(
                        $accountIdOrONS,
                        error: $errorString,
                        continueAction: continueWithAccountIdFromQRCode
                    )
                }
            }
        }
        .backgroundColor(themeColor: .backgroundSecondary)
    }
    
    fileprivate func startNewPrivateChatIfPossible(with sessionId: String, onError: (() -> ())?) {
        if !KeyPair.isValidHexEncodedPublicKey(candidate: sessionId) {
            errorString = "qrNotAccountId".localized()
        }
        else {
            startNewDM(with: sessionId)
        }
    }
    
    func continueWithAccountIdFromQRCode(onError: (() -> ())?) {
        startNewPrivateChatIfPossible(with: accountIdOrONS, onError: onError)
    }
    
    func continueWithAccountIdOrONS() {
        startNewDMIfPossible(with: accountIdOrONS, onError: nil)
    }
    
    fileprivate func startNewDMIfPossible(with onsNameOrPublicKey: String, onError: (() -> ())?) {
        let maybeSessionId: SessionId? = SessionId(from: onsNameOrPublicKey)
        
        if KeyPair.isValidHexEncodedPublicKey(candidate: onsNameOrPublicKey) {
            switch maybeSessionId?.prefix {
                case .standard:
                    startNewDM(with: onsNameOrPublicKey)
                    
                default:
                    errorString = "accountIdErrorInvalid".localized()
            }
            return
        }
        
        // This could be an ONS name
        ModalActivityIndicatorViewController
            .present(fromViewController: self.host.controller?.navigationController!, canCancel: false) { modalActivityIndicator in
            SnodeAPI
                .getSessionID(for: onsNameOrPublicKey)
                .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                .receive(on: DispatchQueue.main)
                .sinkUntilComplete(
                    receiveCompletion: { result in
                        switch result {
                            case .finished: break
                            case .failure(let error):
                                modalActivityIndicator.dismiss {
                                    let message: String = {
                                        switch error {
                                            case SnodeAPIError.onsDecryptionFailed, SnodeAPIError.onsHashingFailed,
                                                SnodeAPIError.onsValidationFailed:
                                                return "onsErrorUnableToSearch".localized()
                                            default: break
                                        }
                                        
                                        return (maybeSessionId?.prefix == .blinded15 || maybeSessionId?.prefix == .blinded25 ?
                                            "accountIdErrorInvalid".localized() :
                                            "onsErrorNotRecognized".localized()
                                        )
                                    }()
                                    
                                    errorString = message
                                }
                        }
                    },
                    receiveValue: { sessionId in
                        modalActivityIndicator.dismiss {
                            self.startNewDM(with: sessionId)
                        }
                    }
                )
        }
    }

    private func startNewDM(with sessionId: String) {
        SessionApp.presentConversationCreatingIfNeeded(
            for: sessionId,
            variant: .contact,
            action: .compose,
            dismissing: self.host.controller,
            animated: false
        )
    }
}

struct EnterAccountIdScreen: View {
    @Binding var accountIdOrONS: String
    @Binding var error: String?
    @State var isTextFieldInErrorMode: Bool = false
    var continueAction: () -> ()
    
    var body: some View {
        VStack(
            alignment: .center,
            spacing: Values.mediumSpacing
        ) {
            SessionTextField(
                $accountIdOrONS,
                placeholder: "accountIdOrOnsEnter".localized(),
                error: $error, 
                accessibility: Accessibility(
                    identifier: "Session ID input box",
                    label: "Session ID input box"
                )
            ) {
                ZStack {
                    Text("\("messageNewDescription".localized())\(Image(systemName: "questionmark.circle"))")
                        .font(.system(size: Values.verySmallFontSize))
                        .foregroundColor(themeColor: .textSecondary)
                        .multilineTextAlignment(.center)
                }
                .accessibility(
                    Accessibility(
                        identifier: "Help desk link",
                        label: "Help desk link"
                    )
                )
                .padding(.horizontal, Values.smallSpacing)
                .padding(.top, Values.smallSpacing)
                .onTapGesture {
                    if let url: URL = URL(string: "https://sessionapp.zendesk.com/hc/en-us/articles/4439132747033-How-do-Session-ID-usernames-work-") {
                        UIApplication.shared.open(url)
                    }
                }
            }
            
            Spacer()
            
            if !accountIdOrONS.isEmpty {
                Button {
                    continueAction()
                } label: {
                    Text("next".localized())
                        .bold()
                        .font(.system(size: Values.smallFontSize))
                        .foregroundColor(themeColor: .sessionButton_text)
                        .frame(
                            maxWidth: 160,
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
                        identifier: "Next",
                        label: "Next"
                    )
                )
                .padding(.horizontal, Values.massiveSpacing)
            }
        }
        .padding(.all, Values.largeSpacing)
    }
}

#Preview {
    NewMessageScreen()
}
