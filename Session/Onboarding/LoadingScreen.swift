// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Combine
import SessionUIKit
import SessionSnodeKit
import SessionMessagingKit
import SignalUtilitiesKit
import SessionUtilitiesKit

struct LoadingScreen: View {
    public class ViewModel {
        fileprivate let dependencies: Dependencies
        fileprivate let preview: Bool
        fileprivate var profileRetrievalCancellable: AnyCancellable?
        
        init(preview: Bool, using dependencies: Dependencies) {
            self.preview = preview
            self.dependencies = dependencies
        }
        
        deinit {
            profileRetrievalCancellable?.cancel()
        }
        
        fileprivate func observeProfileRetrieving(onComplete: @escaping (Bool) -> ()) {
            profileRetrievalCancellable = dependencies[cache: .onboarding].displayNamePublisher
                .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                .timeout(.seconds(15), scheduler: DispatchQueue.main, customError: { NetworkError.timeout(error: "", rawData: nil) })
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { _ in },
                    receiveValue: { displayName in onComplete(displayName?.isEmpty == false) }
                )
        }
        
        fileprivate func completeRegistration(onComplete: @escaping () -> ()) {
            dependencies.mutate(cache: .onboarding) { [dependencies] onboarding in
                let shouldSyncPushTokens: Bool = onboarding.useAPNS
                
                onboarding.completeRegistration {
                    // Trigger the 'SyncPushTokensJob' directly as we don't want to wait for paths to build
                    // before requesting the permission from the user
                    if shouldSyncPushTokens { SyncPushTokensJob.run(uploadOnlyIfStale: false, using: dependencies) }
                    
                    onComplete()
                }
            }
        }
    }
    
    @EnvironmentObject var host: HostWrapper
    private let viewModel: ViewModel
    
    @State var percentage: Double = 0.0
    @State var animationTimer: Timer?
    
    // MARK: - Initialization
    
    public init(preview: Bool = false, using dependencies: Dependencies) {
        self.viewModel = ViewModel(preview: preview, using: dependencies)
    }
    
    // MARK: - UI
    
    var body: some View {
        ZStack(alignment: .center) {
            ThemeManager.currentTheme.colorSwiftUI(for: .backgroundPrimary).ignoresSafeArea()
            
            VStack(
                alignment: .center,
                spacing: Values.mediumSpacing
            ) {
                Spacer()
                
                CircularProgressView($percentage)
                    .accessibility(
                        Accessibility(
                            identifier: "Loading animation",
                            label: "Loading animation"
                        )
                    )
                    .padding(.horizontal, Values.massiveSpacing)
                    .padding(.bottom, Values.mediumSpacing)
                    .onAppear {
                        progress()
                        viewModel.observeProfileRetrieving { finishLoading(success: $0) }
                    }
                
                Text("waitOneMoment".localized())
                    .bold()
                    .font(.system(size: Values.mediumLargeFontSize))
                    .foregroundColor(themeColor: .textPrimary)
                
                Text("loadAccountProgressMessage".localized())
                    .font(.system(size: Values.smallFontSize))
                    .foregroundColor(themeColor: .textPrimary)
                
                Spacer()
            }
            .padding(.horizontal, Values.veryLargeSpacing)
            .padding(.bottom, Values.massiveSpacing + Values.largeButtonHeight)
        }
    }
    
    private func progress() {
        animationTimer = Timer.scheduledTimerOnMainThread(
            withTimeInterval: 0.15,
            repeats: true,
            using: viewModel.dependencies
        ) { timer in
            self.percentage += 0.01
            if percentage >= 1 {
                self.percentage = 1
                timer.invalidate()
                if !viewModel.preview { finishLoading(success: false) }
            }
        }
    }
    
    private func finishLoading(success: Bool) {
        viewModel.profileRetrievalCancellable?.cancel()
        animationTimer?.invalidate()
        animationTimer = nil
        
        guard success else {
            let viewController: SessionHostingViewController = SessionHostingViewController(
                rootView: DisplayNameScreen(using: viewModel.dependencies)
            )
            viewController.setUpNavBarSessionIcon(using: viewModel.dependencies)
            if let navigationController = self.host.controller?.navigationController {
                let updatedViewControllers: [UIViewController] = navigationController.viewControllers
                    .filter { !$0.isKind(of: SessionHostingViewController<LoadingScreen>.self) }
                    .appending(viewController)
                navigationController.setViewControllers(updatedViewControllers, animated: true)
            }
            return
        }
        
        // Complete the animation and then complete the registration
        withAnimation(.linear(duration: 0.3)) {
            self.percentage = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            viewModel.completeRegistration {
                // Go to the home screen
                let homeVC: HomeVC = HomeVC(using: viewModel.dependencies)
                viewModel.dependencies[singleton: .app].setHomeViewController(homeVC)
                self.host.controller?.navigationController?.setViewControllers([ homeVC ], animated: true)
            }
        }
    }
}

struct AnimatableNumberModifier: AnimatableModifier {
    var number: Double
    
    var animatableData: Double {
        get { number }
        set { number = newValue }
    }
    
    func body(content: Content) -> some View {
        content
            .overlay(
                Text(String(format: "%.0f%%", number))  // stringlint:ignore
                    .bold()
                    .font(.system(size: Values.superLargeFontSize))
                    .foregroundColor(themeColor: .textPrimary)
            )
    }
}

struct CircularProgressView: View {
    @Binding var percentage: Double
    
    private var progress: Double {
        return $percentage.wrappedValue * 0.85
    }
    
    init(_ percentage: Binding<Double>) {
        self._percentage = percentage
    }
    
    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.85)
                .stroke(
                    themeColor: .borderSeparator,
                    style: StrokeStyle(
                        lineWidth: 20,
                        lineCap: .round
                    )
                )
                .rotationEffect(.degrees(117))
            
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    themeColor: .primary,
                    style: StrokeStyle(
                        lineWidth: 20,
                        lineCap: .round
                    )
                )
                .rotationEffect(.degrees(117))
                .animation(.easeOut, value: progress)
        }
        .modifier(AnimatableNumberModifier(number: $percentage.wrappedValue * 100))
    }
}

struct LoadingView_Previews: PreviewProvider {
    static var previews: some View {
        LoadingScreen(preview: true, using: Dependencies.createEmpty())
    }
}
