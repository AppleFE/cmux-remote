import PhotosUI
import SwiftUI
import UIKit
import SharedKit

struct IconKey: View {
    let systemName: String
    var accessibilityLabel: String? = nil
    var identifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(CmuxTheme.ink)
                .frame(width: 40, height: 36)
                .background(CmuxTheme.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(CmuxTheme.divider, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? systemName)
        .accessibilityIdentifier(identifier ?? "")
    }
}

struct PhotoAttachButton: View {
    let isBusy: Bool
    @Binding var selection: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $selection, matching: .images) {
            Group {
                if isBusy {
                    ProgressView()
                        .tint(CmuxTheme.ink)
                        .scaleEffect(0.65)
                } else {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 13, weight: .bold))
                }
            }
            .foregroundStyle(CmuxTheme.ink)
            .frame(width: 40, height: 36)
            .background(CmuxTheme.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(CmuxTheme.divider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityIdentifier("CommandPhotoAttachButton")
        .accessibilityLabel("Attach photo from iPhone")
    }
}

struct KeyButton: View {
    let label: String
    var accessibilityLabel: String?
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .cmuxDisplay(12)
                .multilineTextAlignment(.center)
                .foregroundStyle(isActive ? CmuxTheme.accentGreen : CmuxTheme.ink)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(isActive ? CmuxTheme.surfaceRaised : CmuxTheme.surfaceSunken)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(isActive ? CmuxTheme.accentGreen : CmuxTheme.divider, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? label.replacingOccurrences(of: "\n", with: " "))
    }
}

enum TerminalInputMode: Equatable {
    case command
    case live

    var label: String {
        switch self {
        case .command: return "CMD"
        case .live: return "LIVE"
        }
    }
}

struct LiveTerminalInputView: UIViewRepresentable {
    var displayText: String
    @Binding var isFocused: Bool
    var onText: (String) -> Void
    var onKey: (Key) -> Void

    func makeUIView(context: Context) -> LiveTerminalTextView {
        let view = LiveTerminalTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textColor = UIColor(CmuxTheme.ink)
        view.tintColor = UIColor(CmuxTheme.accentGreen)
        view.font = UIFont(name: "GeistMono-Regular", size: 14) ?? UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardType = .default
        view.returnKeyType = .default
        view.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 0, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.accessibilityIdentifier = "LiveInputField"
        view.accessibilityLabel = "Live terminal input"
        return view
    }

    func updateUIView(_ uiView: LiveTerminalTextView, context: Context) {
        context.coordinator.parent = self
        uiView.accessibilityIdentifier = "LiveInputField"
        uiView.accessibilityLabel = "Live terminal input"
        let currentText = uiView.text ?? ""
        let hasLocalHangulInput = LiveTerminalInputTranslator.containsHangul(currentText)
        uiView.accessibilityValue = hasLocalHangulInput ? currentText : displayText
        if !hasLocalHangulInput, uiView.text != displayText {
            uiView.text = displayText
        }
        if !hasLocalHangulInput {
            uiView.selectedRange = NSRange(location: (uiView.text as NSString).length, length: 0)
        }
        uiView.onDeleteWhenEmpty = { [weak coordinator = context.coordinator] in
            coordinator?.handle(actions: LiveTerminalInputTranslator.interpretDeletion())
        }
        if isFocused, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFocused, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LiveTerminalInputView

        init(parent: LiveTerminalInputView) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            if LiveTerminalInputTranslator.shouldUseLocalEditing(
                currentText: textView.text ?? "",
                replacementText: text
            ) {
                return true
            }
            if text.isEmpty, range.length > 0 {
                handle(actions: LiveTerminalInputTranslator.interpretDeletion(count: range.length))
            } else {
                handle(actions: LiveTerminalInputTranslator.interpret(replacementText: text))
            }
            return false
        }

        func handle(actions: [LiveTerminalInputAction]) {
            for action in actions {
                switch action {
                case .text(let text): parent.onText(text)
                case .key(let key): parent.onKey(key)
                }
            }
        }
    }
}

final class LiveTerminalTextView: UITextView {
    var onDeleteWhenEmpty: (() -> Void)?

    override func deleteBackward() {
        if text.isEmpty {
            onDeleteWhenEmpty?()
        } else {
            super.deleteBackward()
        }
    }
}
