// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import SignalUtilitiesKit
import SessionUtilitiesKit

struct RecoveryPasswordScreen: View {
    @EnvironmentObject var host: HostWrapper
    private let dependencies: Dependencies
    
    @State private var copied: Bool = false
    @State private var showQRCode: Bool = false
    private let mnemonic: String
    private let hexEncodedSeed: String?
    
    static private let cornerRadius: CGFloat = 13
    static private let backgroundCornerRadius: CGFloat = 17
    static private let buttonWidth: CGFloat = UIDevice.current.isIPad ? Values.iPadButtonWidth : 130
    
    public init(using dependencies: Dependencies) throws {
        self.dependencies = dependencies
        self.mnemonic = try Identity.mnemonic(using: dependencies)
        self.hexEncodedSeed = try Mnemonic.decode(mnemonic: self.mnemonic)
    }
    
    public init(hardcode: String, using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.mnemonic = hardcode
        self.hexEncodedSeed = try? Mnemonic.decode(mnemonic: hardcode)
    }
    
    var body: some View {
        ZStack(alignment: .center) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(
                    alignment: .leading,
                    spacing: Values.mediumSpacing
                ) {
                    ZStack {
                        RoundedRectangle(cornerRadius: Self.backgroundCornerRadius)
                            .fill(themeColor: .backgroundSecondary)
                        
                        VStack(
                            alignment: .leading,
                            spacing: 0
                        ) {
                            HStack(
                                alignment: .center,
                                spacing: Values.smallSpacing
                            ) {
                                Text("sessionRecoveryPassword".localized())
                                    .bold()
                                    .font(.system(size: Values.mediumFontSize))
                                    .foregroundColor(themeColor: .textPrimary)
                                
                                Image("SessionShieldFilled")
                                    .resizable()
                                    .renderingMode(.template)
                                    .foregroundColor(themeColor: .textPrimary)
                                    .scaledToFit()
                                    .frame(
                                        maxWidth: Values.mediumFontSize,
                                        maxHeight: Values.mediumFontSize
                                    )
                            }
                            .padding(.bottom, Values.smallSpacing)
                            
                            Text("recoveryPasswordDescription".localized())
                                .font(.system(size: Values.smallFontSize))
                                .foregroundColor(themeColor: .textPrimary)
                                .padding(.bottom, Values.mediumSpacing)
                                .fixedSize(horizontal: false, vertical: true)
                            
                            if self.showQRCode {
                                QRCodeView(
                                    string: hexEncodedSeed ?? "",
                                    hasBackground: false,
                                    logo: "SessionShieldFilled", // stringlint:ignore
                                    themeStyle: ThemeManager.currentTheme.interfaceStyle
                                )
                                .padding(.all, Values.smallSpacing)
                                
                                ZStack(alignment: .center) {
                                    Button {
                                        withAnimation(.spring()) {
                                            self.showQRCode.toggle()
                                        }
                                    } label: {
                                        Text("recoveryPasswordView".localized())
                                            .bold()
                                            .font(.system(size: Values.verySmallFontSize))
                                            .foregroundColor(themeColor: .textPrimary)
                                            .frame(
                                                maxWidth: Self.buttonWidth,
                                                maxHeight: Values.mediumSmallButtonHeight,
                                                alignment: .center
                                            )
                                            .overlay(
                                                Capsule()
                                                    .stroke(themeColor: .textPrimary)
                                            )
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, Values.mediumSpacing)
                            } else {
                                Text(mnemonic)
                                    .font(.spaceMono(size: Values.verySmallFontSize))
                                    .multilineTextAlignment(.center)
                                    .accessibility(
                                        Accessibility(
                                            identifier: "Recovery password container",
                                            label: mnemonic
                                        )
                                    )
                                    .foregroundColor(themeColor: .sessionButton_text)
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
                                    .padding(.bottom, Values.mediumSpacing)
                                
                                HStack(
                                    alignment: .center,
                                    spacing: 0
                                ) {
                                    Button {
                                        copyRecoveryPassword()
                                    } label: {
                                        let buttonTitle: String = self.copied ? "copied".localized() : "copy".localized()
                                        Text(buttonTitle)
                                            .bold()
                                            .font(.system(size: Values.verySmallFontSize))
                                            .foregroundColor(themeColor: .textPrimary)
                                            .frame(
                                                maxWidth: .infinity,
                                                minHeight: Values.mediumSmallButtonHeight,
                                                alignment: .center
                                            )
                                            .overlay(
                                                Capsule()
                                                    .stroke(themeColor: .textPrimary)
                                            )
                                    }
                                    .frame(maxWidth: .infinity)
                                    
                                    Spacer(minLength: Values.veryLargeSpacing)
                                    
                                    Button {
                                        withAnimation(.spring()) {
                                            self.showQRCode.toggle()
                                        }
                                    } label: {
                                        Text("qrView".localized())
                                            .bold()
                                            .font(.system(size: Values.verySmallFontSize))
                                            .foregroundColor(themeColor: .textPrimary)
                                            .frame(
                                                maxWidth: .infinity,
                                                minHeight: Values.mediumSmallButtonHeight,
                                                alignment: .center
                                            )
                                            .overlay(
                                                Capsule()
                                                    .stroke(themeColor: .textPrimary)
                                            )
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }
                        }
                        .padding(.all, Values.mediumSpacing)
                    }
                    
                    ZStack {
                        RoundedRectangle(cornerRadius: Self.backgroundCornerRadius)
                            .fill(themeColor: .backgroundSecondary)
                        
                        HStack(
                            alignment: .center,
                            spacing: Values.mediumSpacing
                        ) {
                            VStack(
                                alignment: .leading,
                                spacing: 0
                            ) {
                                Text("recoveryPasswordHideRecoveryPassword".localized())
                                    .bold()
                                    .font(.system(size: Values.mediumFontSize))
                                    .foregroundColor(themeColor: .textPrimary)
                                
                                Text("recoveryPasswordHideRecoveryPasswordDescription".localized())
                                    .font(.system(size: Values.smallFontSize))
                                    .foregroundColor(themeColor: .textPrimary)
                            }
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                            
                            Button {
                                hideRecoveryPassword()
                            } label: {
                                Text("hide".localized())
                                    .bold()
                                    .font(.system(size: Values.verySmallFontSize))
                                    .foregroundColor(themeColor: .danger)
                                    .frame(
                                        width: 55,
                                        height: Values.mediumSmallButtonHeight
                                    )
                                    .overlay(
                                        Capsule()
                                            .stroke(themeColor: .danger)
                                    )
                            }
                            .accessibility(
                                Accessibility(
                                    identifier: "Hide recovery password button",
                                    label: "Hide recovery password button"
                                )
                            )
                        }
                        .padding(.all, Values.mediumSpacing)
                    }
                }
                .padding(.horizontal, Values.largeSpacing)
                .padding(.vertical, Values.mediumSpacing)
            }
        }
        .backgroundColor(themeColor: .backgroundPrimary)
        .onAppear {
            dependencies[singleton: .storage].writeAsync { db in db[.hasViewedSeed] = true }
        }
    }
    
    private func copyRecoveryPassword() {
        UIPasteboard.general.string = self.mnemonic
        self.copied = true
    }
    
    private func hideRecoveryPassword() {
        let modal: ConfirmationModal = ConfirmationModal(
            info: ConfirmationModal.Info(
                title: "recoveryPasswordHidePermanently".localized(),
                body: .text("recoveryPasswordHidePermanentlyDescription1".localized()),
                confirmTitle: "theContinue".localized(),
                confirmStyle: .danger,
                cancelStyle: .textPrimary,
                onConfirm: { modal in
                    guard let presentingViewController: UIViewController = modal.presentingViewController else {
                        return
                    }
                    
                    let continueModal: ConfirmationModal = ConfirmationModal(
                        info: ConfirmationModal.Info(
                            title: "recoveryPasswordHidePermanently".localized(),
                            body: .text("recoveryPasswordHidePermanentlyDescription2".localized()),
                            confirmTitle: "cancel".localized(),
                            confirmStyle: .textPrimary,
                            cancelTitle: "yes".localized(),
                            cancelStyle: .danger,
                            onCancel: { modal in
                                modal.dismiss(animated: true) {
                                    dependencies[singleton: .storage].writeAsync { db in
                                        db[.hideRecoveryPasswordPermanently] = true
                                    }
                                    self.host.controller?.navigationController?.popViewController(animated: true)
                                }
                            }
                        )
                    )
                    
                    return presentingViewController.present(continueModal, animated: true, completion: nil)
                }
            )
        )
        self.host.controller?.present(modal, animated: true)
    }
}

struct RecoveryPasswordView_Previews: PreviewProvider {
    static var previews: some View {
        RecoveryPasswordScreen(
            hardcode: "Voyage  urban  toyed  maverick peculiar  tuxedo penguin  tree grass  building  listen  speak withdraw  terminal  plane",
            using: Dependencies.createEmpty()
        )
    }
}
