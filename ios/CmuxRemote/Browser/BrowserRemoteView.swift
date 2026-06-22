import SwiftUI

struct BrowserRemoteView: View {
    @Bindable var store: BrowserRemoteStore
    @State private var addressText = ""

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 94)

            VStack(alignment: .leading, spacing: 10) {
                BrowserPageSummary(title: store.title, url: store.url, isLoading: store.isLoading)
                BrowserAddressBar(addressText: $addressText, submit: submitAddress)
                BrowserControls(
                    back: { Task { await store.back() } },
                    forward: { Task { await store.forward() } },
                    reload: { Task { await store.reload() } },
                    refreshScreenshot: { Task { await store.refreshScreenshot() } }
                )

                if let errorMessage = store.errorMessage {
                    BrowserErrorBanner(message: errorMessage)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(CmuxTheme.surface)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(CmuxTheme.divider)
                    .frame(height: 1)
            }

            BrowserScreenshotViewport(image: store.screenshotImage, isLoading: store.isRefreshingScreenshot)
        }
        .background(CmuxTheme.canvas.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("BrowserRemoteViewport")
        .onAppear { addressText = store.url ?? "" }
        .onChange(of: store.url) { _, newValue in
            addressText = newValue ?? ""
        }
    }

    private func submitAddress() {
        let destination = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else { return }
        Task { await store.navigate(to: destination) }
    }
}

private struct BrowserPageSummary: View {
    let title: String?
    let url: String?
    let isLoading: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(CmuxTheme.accentGreen)

            VStack(alignment: .leading, spacing: 3) {
                Text(titleText)
                    .cmuxDisplay(16)
                    .foregroundStyle(CmuxTheme.ink)
                    .lineLimit(1)

                Text(urlText)
                    .cmuxMono(11)
                    .foregroundStyle(CmuxTheme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(CmuxTheme.accentGreen)
                    .accessibilityLabel("브라우저 로딩 중")
            }
        }
    }

    private var titleText: String {
        guard let title, !title.isEmpty else { return "브라우저" }
        return title
    }

    private var urlText: String {
        guard let url, !url.isEmpty else { return "주소 대기 중" }
        return url
    }
}

private struct BrowserAddressBar: View {
    @Binding var addressText: String
    let submit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("주소 입력", text: $addressText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .cmuxMono(12)
                .foregroundStyle(CmuxTheme.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(CmuxTheme.surfaceSunken)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(CmuxTheme.divider, lineWidth: 1)
                }
                .accessibilityIdentifier("BrowserAddressField")
                .onSubmit(submit)

            Button(action: submit) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(CmuxTheme.terminal)
            .background(CmuxTheme.accentGreen)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityLabel("이동")
        }
    }
}

private struct BrowserControls: View {
    let back: () -> Void
    let forward: () -> Void
    let reload: () -> Void
    let refreshScreenshot: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            BrowserToolbarButton(
                systemName: "chevron.left",
                label: "뒤로",
                identifier: "BrowserBackButton",
                action: back
            )
            BrowserToolbarButton(
                systemName: "chevron.right",
                label: "앞으로",
                identifier: "BrowserForwardButton",
                action: forward
            )
            BrowserToolbarButton(
                systemName: "arrow.clockwise",
                label: "새로고침",
                identifier: "BrowserReloadButton",
                action: reload
            )
            BrowserToolbarButton(
                systemName: "camera.viewfinder",
                label: "화면 갱신",
                identifier: "BrowserRefreshScreenshotButton",
                action: refreshScreenshot
            )
        }
    }
}

private struct BrowserToolbarButton: View {
    let systemName: String
    let label: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: systemName)
                .labelStyle(.iconOnly)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 32)
        }
        .buttonStyle(.plain)
        .foregroundStyle(CmuxTheme.ink)
        .background(CmuxTheme.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(CmuxTheme.divider, lineWidth: 1)
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

struct BrowserErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(CmuxTheme.accentRed)
            Text(message)
                .cmuxMono(12)
                .foregroundStyle(CmuxTheme.ink)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(CmuxTheme.accentRed.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(CmuxTheme.accentRed.opacity(0.55), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        .accessibilityIdentifier("BrowserErrorMessage")
    }
}

struct BrowserScreenshotViewport: View {
    let image: UIImage?
    let isLoading: Bool

    var body: some View {
        ZStack {
            CmuxTheme.surfaceSunken
                .ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
                    .accessibilityLabel("브라우저 화면")
                    .accessibilityIdentifier("BrowserScreenshotImage")
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 28, weight: .regular))
                    Text(isLoading ? "화면을 불러오는 중" : "화면 없음")
                        .cmuxMono(12)
                }
                .foregroundStyle(CmuxTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
