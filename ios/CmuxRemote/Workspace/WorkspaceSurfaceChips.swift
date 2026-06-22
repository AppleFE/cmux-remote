import SwiftUI
import SharedKit

struct SurfaceChip: View {
    let title: String
    let isSelected: Bool
    let canClose: Bool
    let isBusy: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                Text(title)
                    .cmuxMono(11, weight: isSelected ? .medium : .regular)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? CmuxTheme.accentGreen : CmuxTheme.muted)
                    .padding(.leading, 10)
                    .padding(.trailing, canClose ? 6 : 10)
                    .frame(height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)

            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isSelected ? CmuxTheme.accentGreen : CmuxTheme.muted)
                        .frame(width: 24, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .accessibilityLabel("Close surface \(title)")
            }
        }
        .background(isSelected ? CmuxTheme.surfaceRaised : CmuxTheme.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(isSelected ? CmuxTheme.accentGreen : CmuxTheme.divider, lineWidth: 1)
        )
        .opacity(isBusy && !isSelected ? 0.72 : 1)
    }
}

struct NewSurfaceChip: View {
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView()
                        .tint(CmuxTheme.accentGreen)
                        .scaleEffect(0.6)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                }
                Text("new")
                    .cmuxDisplay(10)
            }
            .foregroundStyle(CmuxTheme.accentGreen)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(CmuxTheme.surfaceSunken)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(CmuxTheme.accentGreen.opacity(0.75), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityIdentifier("NewSurfaceButton")
        .accessibilityLabel("New surface")
    }
}

struct NewBrowserSurfaceChip: View {
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView()
                        .tint(CmuxTheme.accentYellow)
                        .scaleEffect(0.6)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 10, weight: .bold))
                }
                Text("브라우저")
                    .cmuxDisplay(10)
            }
            .foregroundStyle(CmuxTheme.accentYellow)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(CmuxTheme.surfaceSunken)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(CmuxTheme.accentYellow.opacity(0.75), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityIdentifier("NewBrowserSurfaceButton")
        .accessibilityLabel("새 브라우저")
    }
}

struct HeaderSquare: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(CmuxTheme.ink)
                .frame(width: 40, height: 40)
                .background(CmuxTheme.surfaceSunken)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(CmuxTheme.divider, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

struct BatteryBadge: View {
    let battery: HostBatteryState
    let refresh: () -> Void

    var body: some View {
        Button(action: refresh) {
            HStack(spacing: 4) {
                Image(systemName: batteryIcon)
                    .font(.system(size: 10, weight: .bold))
                Text(battery.displayText)
                    .cmuxDisplay(9)
            }
            .foregroundStyle(battery.available ? CmuxTheme.accentGreen : CmuxTheme.muted)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(CmuxTheme.surfaceRaised.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(CmuxTheme.divider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("HostBatteryBadge")
        .accessibilityLabel(battery.accessibilityText)
    }

    private var batteryIcon: String {
        if battery.isCharging == true { return "battery.100.bolt" }
        guard let percent = battery.percent else { return "battery.0" }
        switch percent {
        case 75...100: return "battery.100"
        case 35..<75: return "battery.50"
        default: return "battery.25"
        }
    }
}
