import SharedKit

extension WorkspaceView {
    func selectSurface(_ surface: Surface, in workspace: Workspace) {
        surfaceActionError = nil
        Task { await activateSurface(surface, in: workspace) }
    }

    func createSurface(in workspace: Workspace) {
        guard !surfaceActionInFlight else { return }
        surfaceActionError = nil
        surfaceActionInFlight = true
        Task { @MainActor in
            defer { surfaceActionInFlight = false }
            do {
                let surface = try await workspaceStore.createSurface(workspaceId: workspace.id)
                workspaceStore.selectedId = workspace.id
                preferredSurfaceId = nil
                await activateSurface(surface, in: workspace)
            } catch {
                surfaceActionError = String(describing: error)
            }
        }
    }

    func createBrowserSurface(in workspace: Workspace) {
        guard !surfaceActionInFlight else { return }
        surfaceActionError = nil
        surfaceActionInFlight = true
        Task { @MainActor in
            defer { surfaceActionInFlight = false }
            do {
                let surface = try await workspaceStore.createBrowserSurface(workspaceId: workspace.id)
                workspaceStore.selectedId = workspace.id
                preferredSurfaceId = nil
                await activateSurface(surface, in: workspace)
            } catch {
                surfaceActionError = String(describing: error)
            }
        }
    }

    func closeSurface(_ surface: Surface) {
        guard !surfaceActionInFlight, let workspace = currentWorkspace else { return }
        let surfaces = workspaceStore.surfaces(for: workspace.id)
        guard surfaces.count > 1 else {
            surfaceActionError = "Cannot close the last surface."
            return
        }

        let closingActiveSurface = activeWorkspaceId == workspace.id && activeSurfaceId == surface.id
        let fallback = fallbackSurface(afterClosing: surface.id, in: surfaces)
        surfaceActionError = nil
        surfaceActionInFlight = true

        Task { @MainActor in
            defer { surfaceActionInFlight = false }
            do {
                try await workspaceStore.closeSurface(workspaceId: workspace.id, surfaceId: surface.id)

                if surfaceStore.subscribed == surface.id {
                    await surfaceStore.unsubscribe(surfaceId: surface.id)
                }

                if closingActiveSurface {
                    let refreshedSurfaces = workspaceStore.surfaces(for: workspace.id)
                    let nextSurface = fallback.flatMap { fallback in
                        refreshedSurfaces.first { $0.id == fallback.id }
                    } ?? refreshedSurfaces.first

                    if let nextSurface {
                        preferredSurfaceId = nil
                        await activateSurface(nextSurface, in: workspace)
                    } else {
                        activeSurfaceId = nil
                        browserStore.reset()
                    }
                }
            } catch {
                surfaceActionError = String(describing: error)
            }
        }
    }

    func fallbackSurface(afterClosing surfaceId: String, in surfaces: [Surface]) -> Surface? {
        guard let index = surfaces.firstIndex(where: { $0.id == surfaceId }) else {
            return surfaces.first(where: { $0.id != surfaceId })
        }
        let fallbackIndex = index < surfaces.count - 1 ? index + 1 : index - 1
        guard surfaces.indices.contains(fallbackIndex) else { return nil }
        let candidate = surfaces[fallbackIndex]
        return candidate.id == surfaceId ? surfaces.first(where: { $0.id != surfaceId }) : candidate
    }

    var currentWorkspace: Workspace? {
        guard let id = workspaceStore.selectedId else { return nil }
        return workspaceStore.workspaces.first { $0.id == id }
    }

    var routedSurface: Surface? {
        guard let workspaceId = activeWorkspaceId, let surfaceId = activeSurfaceId else { return nil }
        return workspaceStore.surfaces(for: workspaceId).first { $0.id == surfaceId }
    }

    func switchWorkspace(to workspaceId: String?) async {
        if let current = activeSurfaceId { await surfaceStore.unsubscribe(surfaceId: current) }
        browserStore.reset()
        activeWorkspaceId = workspaceId
        activeSurfaceId = nil
        await subscribeFirstSurfaceIfNeeded()
    }

    func subscribeFirstSurfaceIfNeeded() async {
        guard let workspace = currentWorkspace else { return }
        if activeWorkspaceId == workspace.id, activeSurfaceId != nil { return }
        let surfaces = workspaceStore.surfaces(for: workspace.id)
        guard let first = surfaces.first else { return }
        await activateSurface(first, in: workspace)
    }

    func consumePreferredSurfaceIfNeeded() async {
        guard let workspace = currentWorkspace, let surfaceId = preferredSurfaceId else { return }
        let surfaces = workspaceStore.surfaces(for: workspace.id)
        guard surfaces.contains(where: { $0.id == surfaceId }) else {
            preferredSurfaceId = nil
            return
        }
        if activeWorkspaceId == workspace.id, activeSurfaceId == surfaceId {
            preferredSurfaceId = nil
            return
        }
        guard let surface = surfaces.first(where: { $0.id == surfaceId }) else {
            preferredSurfaceId = nil
            return
        }
        preferredSurfaceId = nil
        await activateSurface(surface, in: workspace)
    }

    func activateSurface(workspaceId: String, surfaceId: String) async {
        guard let workspace = workspaceStore.workspaces.first(where: { $0.id == workspaceId }) else { return }
        guard let surface = workspaceStore.surfaces(for: workspaceId).first(where: { $0.id == surfaceId }) else {
            return
        }
        await activateSurface(surface, in: workspace)
    }

    func activateSurface(_ surface: Surface, in workspace: Workspace) async {
        if surface.kind == .browser {
            if let subscribed = surfaceStore.subscribed {
                await surfaceStore.unsubscribe(surfaceId: subscribed)
            }
            dismissKeyboard()
            liveInputEcho = ""
            composer.clearError()
            activeWorkspaceId = workspace.id
            activeSurfaceId = surface.id
            await browserStore.selectBrowserSurface(workspaceId: workspace.id, surfaceId: surface.id)
            return
        }

        browserStore.reset()
        activeWorkspaceId = workspace.id
        activeSurfaceId = surface.id
        await subscribeAndPinToBottom(workspaceId: workspace.id, surfaceId: surface.id)
    }

    func subscribeAndPinToBottom(workspaceId: String, surfaceId: String) async {
        await surfaceStore.subscribe(workspaceId: workspaceId, surfaceId: surfaceId)
        scrollToBottomRequest &+= 1
    }
}
