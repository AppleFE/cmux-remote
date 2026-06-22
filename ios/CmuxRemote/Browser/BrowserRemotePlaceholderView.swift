import SwiftUI
import UIKit

struct BrowserRemotePlaceholderView: View {
    @Bindable var store: BrowserRemoteStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer(minLength: 96)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(CmuxTheme.accentGreen)
                    Text(store.title ?? "Browser")
                        .cmuxDisplay(18)
                        .foregroundStyle(CmuxTheme.ink)
                        .lineLimit(1)
                }

                Text(store.url ?? "Loading remote browser...")
                    .cmuxMono(12)
                    .foregroundStyle(CmuxTheme.muted)
                    .lineLimit(2)

                if store.isLoading {
                    ProgressView()
                        .tint(CmuxTheme.accentGreen)
                        .accessibilityLabel("Loading browser surface")
                }

                if let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .cmuxMono(12)
                        .foregroundStyle(CmuxTheme.accentRed)
                        .lineLimit(3)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CmuxTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(CmuxTheme.divider, lineWidth: 1)
            }

            if let image = store.screenshotImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .background(CmuxTheme.surfaceSunken)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(CmuxTheme.divider, lineWidth: 1)
                    }
            } else {
                Rectangle()
                    .fill(CmuxTheme.surfaceSunken)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        Text("Remote browser preview")
                            .cmuxMono(12)
                            .foregroundStyle(CmuxTheme.muted)
                    }
            }

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 18)
        .background(CmuxTheme.canvas.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("BrowserRemoteViewport")
    }
}
