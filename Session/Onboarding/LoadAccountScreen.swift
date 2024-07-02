// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SignalUtilitiesKit
import SessionUtilitiesKit
import AVFoundation

struct LoadAccountScreen: View {
    @EnvironmentObject var host: HostWrapper
    
    @State var tabIndex = 0
    @State private var recoveryPassword: String = ""
    @State private var hexEncodedSeed: String = ""
    @State private var errorString: String? = nil
        
    var body: some View {
        ZStack(alignment: .topLeading) {
            if #available(iOS 14.0, *) {
                ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary).ignoresSafeArea()
            } else {
                ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary)
            }
            VStack(
                spacing: 0
            ){
                CustomTopTabBar(
                    tabIndex: $tabIndex,
                    tabTitles: [
                        "sessionRecoveryPassword".localized(),
                        "vc_qr_code_view_scan_qr_code_tab_title".localized()
                    ]
                ).frame(maxWidth: .infinity)
                    
                if tabIndex == 0 {
                    EnterRecoveryPasswordScreen(
                        $recoveryPassword,
                        error: $errorString,
                        continueWithMnemonic: continueWithMnemonic
                    )
                }
                else {
                    ScanQRCodeScreen(
                        $hexEncodedSeed,
                        error: $errorString,
                        continueAction: continueWithhexEncodedSeed
                    )
                }
            }
        }
    }
    
    private func continueWithSeed(seed: Data, from source: Onboarding.SeedSource, onSuccess: (() -> ())?, onError: (() -> ())?) {
        if (seed.count != 16) {
            errorString =  source.genericErrorMessage
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                onError?()
            }
            return
        }
        let (ed25519KeyPair, x25519KeyPair) = try! Identity.generate(from: seed)
        
        Onboarding.Flow.link
            .preregister(
                with: seed,
                ed25519KeyPair: ed25519KeyPair,
                x25519KeyPair: x25519KeyPair
            )
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            onSuccess?()
        }
        
        // Otherwise continue on to request push notifications permissions
        let viewController: SessionHostingViewController = SessionHostingViewController(rootView: PNModeScreen(flow: .link))
        viewController.setUpNavBarSessionIcon()
        self.host.controller?.navigationController?.pushViewController(viewController, animated: true)
    }
    
    func continueWithhexEncodedSeed(onSuccess: (() -> ())?, onError: (() -> ())?) {
        let seed = Data(hex: hexEncodedSeed)
        continueWithSeed(seed: seed, from: .qrCode, onSuccess: onSuccess, onError: onError)
    }
    
    func continueWithMnemonic() {
        let mnemonic = recoveryPassword.lowercased()
        let hexEncodedSeed: String
        do {
            hexEncodedSeed = try Mnemonic.decode(mnemonic: mnemonic)
        } catch {
            if let decodingError = error as? Mnemonic.DecodingError {
                switch decodingError {
                    case .inputTooShort:
                        errorString = "recoveryPasswordErrorMessageShort".localized()
                    case .invalidWord:
                        errorString = "recoveryPasswordErrorMessageIncorrect".localized()
                    default:
                        errorString = "recoveryPasswordErrorMessageGeneric".localized()
                }
            } else {
                errorString = "recoveryPasswordErrorMessageGeneric".localized()
            }
            return
        }
        let seed = Data(hex: hexEncodedSeed)
        continueWithSeed(seed: seed, from: .mnemonic, onSuccess: nil, onError: nil)
    }
}

struct EnterRecoveryPasswordScreen: View{
    @Binding var recoveryPassword: String
    @Binding var error: String?
    
    var continueWithMnemonic: (() -> Void)?
    
    init(
        _ recoveryPassword: Binding<String>,
        error: Binding<String?>,
        continueWithMnemonic: (() -> Void)?
    ) {
        self._recoveryPassword = recoveryPassword
        self._error = error
        self.continueWithMnemonic = continueWithMnemonic
    }
    
    var body: some View{
        ZStack(alignment: .center) {
            VStack(
                alignment: .leading,
                spacing: 0
            ) {
                Spacer(minLength: 0)
                
                HStack(
                    alignment: .bottom,
                    spacing: Values.smallSpacing
                ) {
                    Text("sessionRecoveryPassword".localized())
                        .bold()
                        .font(.system(size: Values.veryLargeFontSize))
                        .foregroundColor(themeColor: .textPrimary)
                    
                    Image("SessionShield")
                        .resizable()
                        .renderingMode(.template)
                        .foregroundColor(themeColor: .textPrimary)
                        .scaledToFit()
                        .frame(
                            maxWidth: Values.largeFontSize,
                            maxHeight: Values.largeFontSize
                        )
                        .padding(.bottom, Values.verySmallSpacing)
                }
                
                Spacer(minLength: 0)
                    .frame(maxHeight: 2 * Values.mediumSpacing)
                
                Text("onboarding_recovery_password_tab_explanation".localized())
                    .font(.system(size: Values.smallFontSize))
                    .foregroundColor(themeColor: .textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                
                Spacer(minLength: 0)
                    .frame(maxHeight: 2 * Values.mediumSpacing)
                
                SessionTextField(
                    $recoveryPassword,
                    placeholder: "recoveryPasswordEnter".localized(),
                    error: $error, 
                    accessibility: Accessibility(identifier: "Recovery password input")
                )
                
                Spacer(minLength: 0)
                    .frame(maxHeight: Values.massiveSpacing)
                
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Values.veryLargeSpacing)
            .padding(.bottom, Values.largeButtonHeight)
            
            VStack() {
                Spacer()
                
                Button {
                    continueWithMnemonic?()
                } label: {
                    Text("continue_2".localized())
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
}

struct LoadAccountView_Previews: PreviewProvider {
    static var previews: some View {
        LoadAccountScreen()
    }
}
