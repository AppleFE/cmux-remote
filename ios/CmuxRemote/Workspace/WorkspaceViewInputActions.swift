import UIKit
import SharedKit

extension WorkspaceView {
    func dismissKeyboard() {
        commandFieldFocused = false
        liveInputFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    func toggleInputMode() {
        switch inputMode {
        case .command:
            inputMode = .live
            composer.draft = ""
            liveInputEcho = ""
            commandFieldFocused = false
            liveInputFocused = true
        case .live:
            inputMode = .command
            liveInputEcho = ""
            liveInputFocused = false
            commandFieldFocused = true
        }
    }

    func pasteClipboard() {
        composer.paste(UIPasteboard.general.string)
        commandFieldFocused = true
    }

    func submitCommand() {
        if composer.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dismissKeyboard()
            Task {
                do {
                    let (workspaceId, surfaceId) = try activeSurface()
                    try await surfaceStore.sendKey(workspaceId: workspaceId, surfaceId: surfaceId, key: .enter)
                    await MainActor.run {
                        composer.clearError()
                        dismissKeyboard()
                    }
                } catch {
                    await MainActor.run { composer.failSubmit(error) }
                }
            }
            return
        }
        guard let command = composer.beginSubmit() else { return }
        dismissKeyboard()
        Task {
            do {
                let (workspaceId, surfaceId) = try activeSurface()
                try await surfaceStore.submitCommand(workspaceId: workspaceId, surfaceId: surfaceId, command: command)
                await MainActor.run {
                    composer.completeSubmit(command)
                    dismissKeyboard()
                }
            } catch {
                await MainActor.run { composer.failSubmit(error) }
            }
        }
    }

    func sendSymbol(_ symbol: String) {
        if composer.activeModifiers.isEmpty {
            sendText(symbol)
        } else {
            sendKey(composer.key(symbol))
        }
    }

    func sendText(_ text: String) {
        Task {
            do {
                let (workspaceId, surfaceId) = try activeSurface()
                try await surfaceStore.sendText(workspaceId: workspaceId, surfaceId: surfaceId, text: text)
                await MainActor.run {
                    composer.clearError()
                }
            } catch {
                await MainActor.run { composer.failSubmit(error) }
            }
        }
    }

    func sendKey(_ key: Key) {
        Task {
            do {
                let (workspaceId, surfaceId) = try activeSurface()
                try await surfaceStore.sendKey(workspaceId: workspaceId, surfaceId: surfaceId, key: key)
                await MainActor.run {
                    composer.clearError()
                }
            } catch {
                await MainActor.run { composer.failSubmit(error) }
            }
        }
    }

    func rememberLiveInputText(_ text: String) {
        guard inputMode == .live, !text.isEmpty else { return }
        let visible = text.replacingOccurrences(of: " ", with: "␠")
        liveInputEcho = String((liveInputEcho + visible).suffix(48))
    }

    func rememberLiveInputKey(_ key: Key) {
        guard inputMode == .live else { return }
        switch key {
        case .backspace:
            if !liveInputEcho.isEmpty {
                liveInputEcho.removeLast()
            } else {
                liveInputEcho = "⌫"
            }
        case .enter:
            liveInputEcho = "↵"
        case .tab:
            liveInputEcho = String((liveInputEcho + "⇥").suffix(48))
        case .esc:
            liveInputEcho = "esc"
        default:
            liveInputEcho = KeyEncoder.encode(key)
        }
    }

    func sendOK() {
        Task {
            do {
                let (workspaceId, surfaceId) = try activeSurface()
                try await surfaceStore.sendText(workspaceId: workspaceId, surfaceId: surfaceId, text: "OK")
                try await surfaceStore.sendKey(workspaceId: workspaceId, surfaceId: surfaceId, key: .enter)
                await MainActor.run { composer.clearError() }
            } catch {
                await MainActor.run { composer.failSubmit(error) }
            }
        }
    }

    func activeSurface() throws -> (workspaceId: String, surfaceId: String) {
        guard let workspaceId = activeWorkspaceId, let surfaceId = activeSurfaceId else {
            throw TerminalInputError.noActiveSurface
        }
        return (workspaceId, surfaceId)
    }
}

enum TerminalInputError: Error, CustomStringConvertible {
    case noActiveSurface

    var description: String {
        switch self {
        case .noActiveSurface: return "Select a workspace surface before sending input."
        }
    }
}
