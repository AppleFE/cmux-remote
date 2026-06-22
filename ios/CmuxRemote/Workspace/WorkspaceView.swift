import SwiftUI
import UIKit
import PhotosUI
import SharedKit

struct WorkspaceView: View {
    static let attachmentMaxDimension: CGFloat = 2048
    static let preferredAttachmentMaxBytes = 6 * 1024 * 1024
    static let attachmentJPEGQualities: [CGFloat] = [0.78, 0.68, 0.56]

    @Bindable var workspaceStore: WorkspaceStore
    @Bindable var surfaceStore: SurfaceStore
    @Bindable var browserStore: BrowserRemoteStore
    @Bindable var notifStore: NotificationStore
    @Bindable var hostStatusStore: HostStatusStore
    @Binding var preferredSurfaceId: String?
    let onBack: () -> Void
    @State var showDrawer = false
    @State var activeWorkspaceId: String?
    @State var activeSurfaceId: String?
    @State var composer = CommandComposer()
    @State var inputMode: TerminalInputMode = .command
    @State var liveInputFocused = false
    @State var liveInputEcho = ""
    @State var headerHeight: CGFloat = 128
    @State var accessoryHeight: CGFloat = 172
    @State var keyboardHeight: CGFloat = 0
    @State var scrollToBottomRequest = 0
    @State var pendingCloseSurface: Surface?
    @State var surfaceActionInFlight = false
    @State var surfaceActionError: String?
    @State var selectedPhotoItem: PhotosPickerItem?
    @State var attachmentInFlight = false
    @AppStorage("cmux.demoMode") var demoMode: Bool = false
    @FocusState var commandFieldFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let keyboardVisible = keyboardHeight > proxy.safeAreaInsets.bottom + 20
            let keyboardControlsActive = keyboardVisible || commandFieldFocused || liveInputFocused
            let keyboardAccessoryOffset: CGFloat = keyboardControlsActive ? -112 : 0
            let bottomObstruction = keyboardVisible ? 0 : proxy.safeAreaInsets.bottom
            let accessoryBottomPadding: CGFloat = keyboardVisible ? keyboardAccessoryOffset + 12 : 0
            let terminalBottomInset = max(0, accessoryHeight + keyboardAccessoryOffset + 10)
            let terminalTopInset = keyboardControlsActive
                ? proxy.safeAreaInsets.top + 20
                : proxy.safeAreaInsets.top + headerHeight + 10
            let browserActive = routedSurface?.kind == .browser
            ZStack(alignment: .bottom) {
                if browserActive {
                    BrowserRemoteView(store: browserStore)
                        .ignoresSafeArea(.container, edges: .all)
                } else {
                    TerminalView(
                        store: surfaceStore,
                        topContentInset: terminalTopInset,
                        bottomContentInset: terminalBottomInset,
                        scrollToBottomRequest: scrollToBottomRequest
                    )
                    .ignoresSafeArea(.container, edges: .all)
                }

                VStack(spacing: 0) {
                    terminalHeader
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .readHeight($headerHeight)
                    Spacer()
                    if browserActive {
                        Color.clear
                            .frame(height: 0)
                            .readHeight($accessoryHeight)
                    } else {
                        terminalAccessory()
                            .padding(.horizontal, 16)
                            .padding(.bottom, accessoryBottomPadding)
                            .readHeight($accessoryHeight)
                    }
                }

                if !browserActive {
                    scrollToBottomButton
                        .padding(.trailing, 24)
                        .padding(.bottom, bottomObstruction + keyboardAccessoryOffset + accessoryHeight + 22)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .background(CmuxTheme.terminal.ignoresSafeArea())
        }
        .sheet(isPresented: $showDrawer) {
            WorkspaceDrawer(store: workspaceStore) { workspaceId, surfaceId in
                workspaceStore.selectedId = workspaceId
                notifStore.markWorkspaceSeen(workspaceId)
                surfaceActionError = nil
                showDrawer = false
                Task { await activateSurface(workspaceId: workspaceId, surfaceId: surfaceId) }
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            "Close surface?",
            isPresented: Binding(
                get: { pendingCloseSurface != nil },
                set: { isPresented in
                    if !isPresented { pendingCloseSurface = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            if let surface = pendingCloseSurface {
                Button("Close \(surface.title)", role: .destructive) {
                    pendingCloseSurface = nil
                    closeSurface(surface)
                }
            }
            Button("Cancel", role: .cancel) { pendingCloseSurface = nil }
        } message: {
            Text("This closes the terminal surface in cmux.")
        }
        .task {
            await subscribeFirstSurfaceIfNeeded()
            await consumePreferredSurfaceIfNeeded()
            await hostStatusStore.refreshBattery()
        }
        .onChange(of: workspaceStore.selectedId) { _, newValue in
            Task {
                await switchWorkspace(to: newValue)
                await consumePreferredSurfaceIfNeeded()
            }
        }
        .onChange(of: preferredSurfaceId) { _, _ in
            Task { await consumePreferredSurfaceIfNeeded() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            updateKeyboardHeight(from: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { notification in
            updateKeyboardHeight(from: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            updateKeyboardHeight(from: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { notification in
            updateKeyboardHeight(from: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            Task { await attachPhoto(item) }
        }
    }

}
