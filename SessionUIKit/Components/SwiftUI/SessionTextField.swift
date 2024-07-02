// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Combine
import UIKit

public struct SessionTextField<ExplanationView>: View where ExplanationView: View {
    @Binding var text: String
    @Binding var error: String?
    @State var previousError: String = ""
    @State var textThemeColor: ThemeValue = .textPrimary
    
    let explanationView: () -> ExplanationView
    let placeholder: String
    let accessibility: Accessibility
    var isErrorMode: Bool {
        guard previousError.isEmpty else { return true }
        if error?.isEmpty == false { return true }
        return false
    }
    
    let height: CGFloat = isIPhone5OrSmaller ? CGFloat(48) : CGFloat(80)
    let cornerRadius: CGFloat = 13
    
    public init(
        _ text: Binding<String>,
        placeholder: String,
        error: Binding<String?>,
        accessibility: Accessibility = Accessibility(),
        @ViewBuilder explanationView: @escaping () -> ExplanationView = {
            EmptyView()
        }
    ) {
        self._text = text
        self.placeholder = placeholder
        self.accessibility = accessibility
        self._error = error
        self.explanationView = explanationView
        UITextView.appearance().backgroundColor = .clear
    }
    
    public var body: some View {
        VStack (
            alignment: .center,
            spacing: Values.smallSpacing
        ) {
            // Text input
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: Values.smallFontSize))
                        .foregroundColor(themeColor: isErrorMode ? .danger : .textSecondary)
                }
                
                if #available(iOS 16.0, *) {
                    SwiftUI.TextField(
                        "",
                        text: $text.onChange{ value in
                            if error?.isEmpty == false && text != value {
                                previousError = error!
                                error = nil
                            }
                        },
                        axis: .vertical
                    )
                    .font(.system(size: Values.smallFontSize))
                    .foregroundColor(themeColor: textThemeColor)
                    .accessibility(self.accessibility)
                } else if #available(iOS 14.0, *) {
                    ZStack {
                        TextEditor(
                            text: $text.onChange{ value in
                                if error?.isEmpty == false && text != value {
                                    previousError = error!
                                    error = nil
                                }
                            }
                        )
                        .font(.system(size: Values.smallFontSize))
                        .foregroundColor(themeColor: textThemeColor)
                        .textViewTransparentScrolling()
                        .accessibility(self.accessibility)
                        .frame(maxHeight: self.height)
                        .padding(.all, -4)
                        
                        // FIXME: This is a workaround for dynamic height of the TextEditor.
                        Text(text.isEmpty ? placeholder : text)
                            .font(.system(size: Values.smallFontSize))
                            .opacity(0)
                            .padding(.all, 4)
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: self.height
                            )
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    SwiftUI.TextField(
                        "",
                        text: $text.onChange{ value in
                            if error?.isEmpty == false && text != value {
                                previousError = error!
                                error = nil
                            }
                        }
                    )
                    .font(.system(size: Values.smallFontSize))
                    .foregroundColor(themeColor: textThemeColor)
                    .accessibility(self.accessibility)
                }
            }
            .padding(.horizontal, Values.largeSpacing)
            .frame(maxWidth: .infinity)
            .frame(height: self.height)
            .overlay(
                RoundedRectangle(
                    cornerSize: CGSize(
                        width: self.cornerRadius,
                        height: self.cornerRadius
                    )
                )
                .stroke(themeColor: isErrorMode ? .danger : .borderSeparator)
            )
            .onReceive(Just(error)) { newValue in
                textThemeColor = (newValue?.isEmpty == false) ? .danger : .textPrimary
            }
            
            // Error message
            ZStack {
                if isErrorMode {
                    Text(error ?? previousError)
                        .bold()
                        .font(.system(size: Values.smallFontSize))
                        .foregroundColor(themeColor: .danger)
                        .multilineTextAlignment(.center)
                        .accessibility(
                            Accessibility(
                                identifier: "Error message",
                                label: "Error message"
                            )
                        )
                } else {
                    explanationView()
                }
            }
            .frame(
                height: 54,
                alignment: .top
            )
        }
    }
}

struct SessionTextField_Previews: PreviewProvider {
    @State static var text: String = "test"
    @State static var error: String? = "test error"
    @State static var emptyText: String = ""
    @State static var emptyError: String? = nil
    static var previews: some View {
        VStack {
            SessionTextField($text, placeholder: "Placeholder", error: $error) {}
            SessionTextField($emptyText, placeholder: "Placeholder", error: $emptyError) {}
        }
        
    }
}
