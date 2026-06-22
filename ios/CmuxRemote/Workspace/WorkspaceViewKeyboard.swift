import SwiftUI
import UIKit

extension WorkspaceView {
    func updateKeyboardHeight(from notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let screenHeight = UIScreen.main.bounds.height
        updateKeyboardHeight(max(0, screenHeight - frame.minY))
    }

    func updateKeyboardHeight(_ nextHeight: CGFloat) {
        let screenHeight = UIScreen.main.bounds.height
        let clampedHeight = min(max(0, nextHeight), screenHeight * 0.58)
        guard abs(keyboardHeight - clampedHeight) > 0.5 else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            keyboardHeight = clampedHeight
        }
    }
}

extension View {
    func readHeight(_ height: Binding<CGFloat>) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { height.wrappedValue = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, newValue in
                        guard newValue > 0, abs(height.wrappedValue - newValue) > 0.5 else { return }
                        height.wrappedValue = newValue
                    }
            }
        }
    }
}
