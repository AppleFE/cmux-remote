import SwiftUI
import SharedKit

extension WorkspaceView {
    func terminalAccessory() -> some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        toggleInputMode()
                    } label: {
                        Text(inputMode.label)
                            .cmuxDisplay(10)
                            .foregroundStyle(inputMode == .live ? CmuxTheme.canvas : CmuxTheme.accentGreen)
                            .frame(width: 42, height: 26)
                            .background(inputMode == .live ? CmuxTheme.accentGreen : CmuxTheme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(CmuxTheme.divider, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("InputModeToggleButton")
                    .accessibilityLabel(inputMode == .live ? "Switch to command input mode" : "Switch to live input mode")

                    Text("$")
                        .cmuxDisplay(14)
                        .foregroundStyle(CmuxTheme.accentGreen)

                    if inputMode == .command {
                        TextField("type a command…", text: $composer.draft, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($commandFieldFocused)
                            .cmuxMono(14)
                            .foregroundStyle(CmuxTheme.ink)
                            .submitLabel(.send)
                            .lineLimit(1...3)
                            .disabled(composer.isSending)
                            .onSubmit { submitCommand() }
                            .onTapGesture { commandFieldFocused = true }
                            .accessibilityIdentifier("CommandComposerField")
                    } else {
                        ZStack(alignment: .leading) {
                            LiveTerminalInputView(
                                displayText: liveInputEcho,
                                isFocused: $liveInputFocused,
                                onText: { text in
                                    rememberLiveInputText(text)
                                    sendText(text)
                                },
                                onKey: { key in
                                    rememberLiveInputKey(key)
                                    sendKey(key)
                                }
                            )
                            .accessibilityIdentifier("LiveInputField")
                            .accessibilityLabel("Live terminal input")

                            if liveInputEcho.isEmpty {
                                Text("입력하면 바로 전송됩니다…")
                                    .cmuxMono(14)
                                    .foregroundStyle(CmuxTheme.muted)
                                    .lineLimit(1)
                                    .allowsHitTesting(false)
                                    .accessibilityIdentifier("LiveInputPlaceholder")
                            }
                        }
                        .frame(minHeight: 26, maxHeight: 34)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(CmuxTheme.surfaceSunken)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(commandFieldFocused ? CmuxTheme.accentGreen : CmuxTheme.divider, lineWidth: 1)
                )
            }

            HStack(spacing: 8) {
                IconKey(systemName: "keyboard.chevron.compact.down",
                        accessibilityLabel: "Dismiss keyboard",
                        identifier: "CommandKeyboardDismissButton") { dismissKeyboard() }

                IconKey(systemName: "delete.left",
                        accessibilityLabel: "Send terminal backspace",
                        identifier: "CommandBackspaceButton") { sendKey(.backspace) }

                IconKey(systemName: "doc.on.clipboard",
                        accessibilityLabel: "Paste clipboard into command field",
                        identifier: "CommandPasteButton") { pasteClipboard() }

                PhotoAttachButton(isBusy: attachmentInFlight, selection: $selectedPhotoItem)

                Spacer(minLength: 4)

                Button { submitCommand() } label: {
                    HStack(spacing: 6) {
                        if composer.isSending {
                            ProgressView().tint(CmuxTheme.canvas).scaleEffect(0.7)
                        } else {
                            Text("[ ENTER ]")
                                .cmuxDisplay(12)
                        }
                    }
                    .foregroundStyle(CmuxTheme.canvas)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(composer.isSending ? CmuxTheme.muted : CmuxTheme.accentGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(composer.isSending)
                .accessibilityIdentifier("CommandSubmitButton")
                .accessibilityLabel("Send terminal input")
            }

            if let message = inputFeedbackMessage {
                HStack(spacing: 6) {
                    Text(inputFeedbackIsError ? "!" : "›")
                        .cmuxDisplay(11)
                    Text(message)
                        .cmuxMono(11)
                        .lineLimit(2)
                }
                .foregroundStyle(inputFeedbackIsError ? CmuxTheme.accentRed : CmuxTheme.accentGreen)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(message)
                .accessibilityIdentifier("InputStatusMessage")
            }

            HStack(spacing: 4) {
                KeyButton(label: "esc") { sendKey(.esc) }
                KeyButton(label: "OK", accessibilityLabel: "send OK and enter") { sendOK() }
                KeyButton(label: "/") { sendSymbol("/") }
                KeyButton(label: "$") { sendSymbol("$") }
                KeyButton(label: "tab") { sendKey(.tab) }
                KeyButton(label: "←", accessibilityLabel: "send left arrow") { sendKey(.left) }
                KeyButton(label: "↑", accessibilityLabel: "send up arrow") { sendKey(.up) }
                KeyButton(label: "↓", accessibilityLabel: "send down arrow") { sendKey(.down) }
                KeyButton(label: "→", accessibilityLabel: "send right arrow") { sendKey(.right) }
                KeyButton(label: "/new", accessibilityLabel: "send slash new shortcut") { sendText("/new") }
                KeyButton(label: "space", accessibilityLabel: "send space for omx selection") { sendText(" ") }
            }
        }
        .padding(12)
        .background(CmuxTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(CmuxTheme.divider, lineWidth: 1)
        }
        .shadow(color: CmuxTheme.hardShadow, radius: 20, x: 0, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("TerminalAccessoryPanel")
    }

    var inputFeedbackMessage: String? {
        composer.errorMessage ?? surfaceStore.inputStatus.message
    }

    var inputFeedbackIsError: Bool {
        composer.errorMessage != nil || surfaceStore.inputStatus.isError
    }
}
