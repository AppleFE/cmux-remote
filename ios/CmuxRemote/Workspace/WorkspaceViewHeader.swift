import SwiftUI
import SharedKit

extension WorkspaceView {
    var terminalHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HeaderSquare(systemName: "chevron.left", action: onBack)
                    .accessibilityIdentifier("WorkspaceBackButton")
                    .accessibilityLabel("Back to workspaces")

                HStack(spacing: 8) {
                    Text("●")
                        .cmuxDisplay(11)
                        .foregroundStyle(demoMode ? CmuxTheme.accentYellow : CmuxTheme.accentGreen)
                    Text(currentWorkspace?.name ?? "no workspace")
                        .cmuxMono(13, weight: .medium)
                        .foregroundStyle(CmuxTheme.ink)
                        .lineLimit(1)
                    if demoMode {
                        Text("DEMO")
                            .cmuxDisplay(9)
                            .foregroundStyle(CmuxTheme.canvas)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(CmuxTheme.accentYellow)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                            .accessibilityLabel("Demo mode active")
                    }
                    BatteryBadge(battery: hostStatusStore.battery) {
                        Task { await hostStatusStore.refreshBattery() }
                    }
                    Spacer()
                    Text("×")
                        .cmuxDisplay(16)
                        .foregroundStyle(CmuxTheme.muted)
                        .onTapGesture { onBack() }
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(CmuxTheme.surfaceSunken)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(CmuxTheme.divider, lineWidth: 1)
                )

                HeaderSquare(systemName: "square.grid.2x2") { showDrawer = true }
                    .accessibilityIdentifier("WorkspaceDrawerButton")
                    .accessibilityLabel("Open workspace drawer")
            }

            if !commandFieldFocused, keyboardHeight <= 20, let workspace = currentWorkspace {
                let surfaces = workspaceStore.surfaces(for: workspace.id)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(surfaces) { surface in
                            SurfaceChip(
                                title: surface.title,
                                isSelected: activeSurfaceId == surface.id,
                                canClose: surfaces.count > 1,
                                isBusy: surfaceActionInFlight,
                                onSelect: { selectSurface(surface, in: workspace) },
                                onClose: { pendingCloseSurface = surface }
                            )
                        }

                        NewSurfaceChip(isBusy: surfaceActionInFlight) {
                            createSurface(in: workspace)
                        }

                        NewBrowserSurfaceChip(isBusy: surfaceActionInFlight) {
                            createBrowserSurface(in: workspace)
                        }
                    }
                }

                if let surfaceActionError {
                    HStack(spacing: 6) {
                        Text("!")
                            .cmuxDisplay(11)
                        Text(surfaceActionError)
                            .cmuxMono(11)
                            .lineLimit(2)
                    }
                    .foregroundStyle(CmuxTheme.accentRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("SurfaceActionError")
                }
            }
        }
    }

    var scrollToBottomButton: some View {
        Button {
            scrollToBottomRequest &+= 1
        } label: {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(CmuxTheme.ink)
                .frame(width: 40, height: 40)
                .background(CmuxTheme.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(CmuxTheme.divider, lineWidth: 1)
                )
                .shadow(color: CmuxTheme.hardShadow, radius: 12, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("TerminalScrollToBottomButton")
        .accessibilityLabel("Scroll terminal to bottom")
    }
}
