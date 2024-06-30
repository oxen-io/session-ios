// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit

enum QRCode {
    /// Generates a QRCode for the give string
    ///
    /// **Note:** If the `hasBackground` value is true then the QRCode will be black and white and
    /// the `withRenderingMode(.alwaysTemplate)` won't work correctly on some iOS versions (eg. iOS 16)
    static func generate(for string: String, hasBackground: Bool) -> UIImage {
        let data = string.data(using: .utf8)
        var qrCodeAsCIImage: CIImage
        let filter1 = CIFilter(name: "CIQRCodeGenerator")! // stringlint:disable
        filter1.setValue(data, forKey: "inputMessage")
        qrCodeAsCIImage = filter1.outputImage!
        
        guard !hasBackground else {
            let filter2 = CIFilter(name: "CIFalseColor")! // stringlint:disable
            filter2.setValue(qrCodeAsCIImage, forKey: "inputImage")
            filter2.setValue(CIColor(color: .black), forKey: "inputColor0")
            filter2.setValue(CIColor(color: .white), forKey: "inputColor1")
            qrCodeAsCIImage = filter2.outputImage!
            
            let scaledQRCodeAsCIImage = qrCodeAsCIImage.transformed(by: CGAffineTransform(scaleX: 6.4, y: 6.4))
            return UIImage(ciImage: scaledQRCodeAsCIImage)
        }
        
        let filter2 = CIFilter(name: "CIColorInvert")! // stringlint:disable
        filter2.setValue(qrCodeAsCIImage, forKey: "inputImage")
        qrCodeAsCIImage = filter2.outputImage!
        let filter3 = CIFilter(name: "CIMaskToAlpha")! // stringlint:disable
        filter3.setValue(qrCodeAsCIImage, forKey: "inputImage")
        qrCodeAsCIImage = filter3.outputImage!
        
        let scaledQRCodeAsCIImage = qrCodeAsCIImage.transformed(by: CGAffineTransform(scaleX: 6.4, y: 6.4))
        
        // Note: It looks like some internal method was changed in iOS 16.0 where images
        // generated from a CIImage don't have the same color information as normal images
        // as a result tinting using the `alwaysTemplate` rendering mode won't work - to
        // work around this we convert the image to data and then back into an image
        let imageData: Data = UIImage(ciImage: scaledQRCodeAsCIImage).pngData()!
        return UIImage(data: imageData)!
    }
}

import SwiftUI
import SessionUIKit

struct QRCodeView: View {
    let string: String
    let hasBackground: Bool
    let logo: String?
    let themeStyle: UIUserInterfaceStyle
    var backgroundThemeColor: ThemeValue {
        switch themeStyle {
            case .light:
                return .backgroundSecondary
            default:
                return .textPrimary
        }
    }
    var qrCodeThemeColor: ThemeValue {
        switch themeStyle {
            case .light:
                return .textPrimary
            default:
                return .backgroundPrimary
        }
    }
    
    static private var cornerRadius: CGFloat = 10
    static private var logoSize: CGFloat = 66
    
    var body: some View {
        ZStack(alignment: .center) {
            ZStack(alignment: .center) {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .fill(themeColor: backgroundThemeColor)
                
                Image(uiImage: QRCode.generate(for: string, hasBackground: hasBackground))
                    .resizable()
                    .renderingMode(.template)
                    .foregroundColor(themeColor: qrCodeThemeColor)
                    .scaledToFit()
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
                    .padding(.vertical, Values.smallSpacing)
                
                if let logo = logo {
                    ZStack(alignment: .center) {
                        Rectangle()
                            .fill(themeColor: backgroundThemeColor)
                        
                        Image(logo)
                            .resizable()
                            .renderingMode(.template)
                            .foregroundColor(themeColor: qrCodeThemeColor)
                            .scaledToFit()
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity
                            )
                            .padding(.all, 4)
                    }
                    .frame(
                        width: Self.logoSize,
                        height: Self.logoSize
                    )
                }
            }
            .frame(
                maxWidth: 400,
                maxHeight: 400
            )
        }
        .frame(maxWidth: .infinity)
    }
}
