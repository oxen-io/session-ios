// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import SessionUIKit
import AVFoundation
import SessionUtilitiesKit

struct ScanQRCodeScreen: View {
    @Binding var result: String
    @Binding var error: String?
    @State var hasCameraAccess: Bool = (AVCaptureDevice.authorizationStatus(for: .video) == .authorized)
    
    var continueAction: (((() -> ())?) -> Void)?
    
    init(
        _ result: Binding<String>,
        error: Binding<String?>,
        continueAction: (((() -> ())?) -> Void)?
    ) {
        self._result = result
        self._error = error
        self.continueAction = continueAction
    }
    
    var body: some View{
        ZStack{
            if hasCameraAccess {
                VStack {
                    QRCodeScanningVC_SwiftUI { result, onError in
                        self.result = result
                        continueAction?(onError)
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
            } else {
                VStack(
                    alignment: .center,
                    spacing: Values.mediumSpacing
                ) {
                    Spacer()
                    
                    Text(
                        "cameraGrantAccessQr"
                            .put(key: "app_name", value: Singleton.appName)
                            .localized()
                    )
                    .font(.system(size: Values.smallFontSize))
                    .foregroundColor(themeColor: .textPrimary)
                    .multilineTextAlignment(.center)
                    
                    Button {
                        requestCameraAccess()
                    } label: {
                        Text("theContinue".localized())
                            .bold()
                            .font(.system(size: Values.mediumFontSize))
                            .foregroundColor(themeColor: .primary)
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, Values.massiveSpacing)
                .padding(.bottom, Values.massiveSpacing)
            }
        }
        .toastView(message: $error)
    }
    
    private func requestCameraAccess() {
        Permissions.requestCameraPermissionIfNeeded {
            hasCameraAccess.toggle()
        }
    }
}
