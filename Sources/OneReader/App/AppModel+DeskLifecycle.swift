import Foundation

extension AppModel {
    func requestSpaceRename(_ space: ReadingSpace) {
        spacePendingRename = space
    }

    func requestSpaceRename(_ spaceID: String) {
        spacePendingRename = spaces.first(where: { $0.id == spaceID })
    }

    func requestSpaceDeletion(_ space: ReadingSpace) {
        spacePendingDeletion = space
    }

    func requestSpaceDeletion(_ spaceID: String) {
        spacePendingDeletion = spaces.first(where: { $0.id == spaceID })
    }

    func requestSourceRename(_ source: Source) {
        sourcePendingRename = source
    }

    func requestSourceRename(_ sourceID: String) {
        sourcePendingRename = source(id: sourceID)
    }

    func renameSpace(_ spaceID: String, title: String) {
        guard let database else { return }
        do {
            try database.renameSpace(id: spaceID, title: title)
            try reloadLibraryState(preservingSelection: true)
            spacePendingRename = nil
            notesCenter?.invalidate()
        } catch {
            notice = AppNotice(title: "无法重命名空间", message: error.localizedDescription)
        }
    }

    func renameSource(_ sourceID: String, displayName: String) {
        guard let database else { return }
        do {
            try database.renameSource(id: sourceID, displayName: displayName)
            try reloadLibraryState(preservingSelection: true)
            sourcePendingRename = nil
            notesCenter?.invalidate()
        } catch {
            notice = AppNotice(title: "无法重命名来源", message: error.localizedDescription)
        }
    }

    func canDetachSource(_ sourceID: String, fromSpaceID spaceID: String? = nil) -> Bool {
        guard let targetSpaceID = spaceID ?? selectedSpaceID else { return false }
        let sourcesInSpace = sourceIDs(in: targetSpaceID)
        guard sourcesInSpace.contains(sourceID) else { return false }
        if sourcesInSpace.count > 1 {
            return true
        }
        if let database, let containingSpaces = try? database.spaceIDs(containing: sourceID) {
            return containingSpaces.count > 1
        }
        let containingCount = spaces.filter { sourceIDs(in: $0.id).contains(sourceID) }.count
        return containingCount > 1
    }

    func detachSourceFromSpace(sourceID: String, spaceID: String? = nil) {
        guard let targetSpaceID = spaceID ?? selectedSpaceID,
              let database else { return }
        let wasReadingWorkspaceOpen = isReadingWorkspaceOpen
        do {
            let newGeneration = try database.detachSourceFromSpace(
                sourceID: sourceID,
                spaceID: targetSpaceID
            )
            if let agentRuntime {
                Task {
                    if let newGeneration,
                       let session = try? await agentRuntime.session(forSpaceID: targetSpaceID) {
                        await session.completeSourceRevisionRefresh(durableGeneration: newGeneration)
                    } else {
                        await agentRuntime.cancelSession(forSpaceID: targetSpaceID)
                    }
                }
            }
            try reloadLibraryState(preservingSelection: true)
            setReadingProgress(
                try database.fetchReadingProgress(spaceID: targetSpaceID),
                for: targetSpaceID
            )
            notesCenter?.invalidate()
            if selectedSpaceID == targetSpaceID {
                try loadSpaceState(spaceID: targetSpaceID)
                if selectedSourceID == sourceID {
                    contentTask?.cancel()
                    if let nextSourceID = sourceIDs(in: targetSpaceID).first {
                        if wasReadingWorkspaceOpen {
                            openSource(nextSourceID)
                        } else {
                            selectedSourceID = nextSourceID
                        }
                    } else {
                        openSpace(targetSpaceID)
                        if !wasReadingWorkspaceOpen {
                            isReadingWorkspaceOpen = false
                        }
                    }
                }
            }
        } catch {
            notice = AppNotice(title: "无法移出来源", message: error.localizedDescription)
        }
    }

    func confirmSpaceDeletion() {
        guard let space = spacePendingDeletion else { return }
        spacePendingDeletion = nil
        deleteSpace(space.id)
    }

    func deleteSpace(_ spaceID: String) {
        Task { [weak self] in
            await self?.performDeleteSpace(spaceID)
        }
    }

    func performDeleteSpace(_ spaceID: String) async {
        guard let database else { return }
        do {
            let exclusiveSourceIDs = try database.exclusivelyOwnedSourceIDs(inSpaceID: spaceID)
            if let managedLibrary {
                for sourceID in exclusiveSourceIDs {
                    if let agentRuntime {
                        let lease = try await agentRuntime.beginSourceRevisionRefresh(
                            sourceID: sourceID
                        )
                        do {
                            let generations = try await managedLibrary.removeSource(id: sourceID)
                            await agentRuntime.completeSourceRevisionRefresh(
                                lease: lease,
                                generations: generations
                            )
                        } catch {
                            await agentRuntime.abortSourceRevisionRefresh(lease: lease)
                            throw error
                        }
                    } else {
                        _ = try await managedLibrary.removeSource(id: sourceID)
                    }
                }
            }
            if let agentRuntime {
                await agentRuntime.cancelSession(forSpaceID: spaceID)
            }
            try database.deleteSpaceRecord(id: spaceID)
            if selectedSpaceID == spaceID {
                closeReadingWorkspace()
            }
            try reloadLibraryState(preservingSelection: selectedSpaceID != nil)
            if let selectedSpaceID {
                try loadSpaceState(spaceID: selectedSpaceID)
            }
            notesCenter?.invalidate()
        } catch {
            notice = AppNotice(title: "无法删除空间", message: error.localizedDescription)
        }
    }

    func sourceRole(for sourceID: String, in spaceID: String? = nil) -> SpaceSourceRole {
        guard let targetSpaceID = spaceID ?? selectedSpaceID else { return .primary }
        return (progressBySpace[targetSpaceID] ?? .empty).role(for: sourceID)
    }

    func setSourceRole(_ role: SpaceSourceRole, for sourceID: String, in spaceID: String? = nil) {
        guard let targetSpaceID = spaceID ?? selectedSpaceID,
              let database else { return }
        var progress = progressBySpace[targetSpaceID]
            ?? (try? database.fetchReadingProgress(spaceID: targetSpaceID))
            ?? .empty
        progress.sourceRoles[sourceID] = (role == .primary ? nil : role)
        progress.lastActiveAt = .now
        do {
            try database.saveReadingProgress(progress, spaceID: targetSpaceID)
            setReadingProgress(progress, for: targetSpaceID)
        } catch {
            notice = AppNotice(title: "无法更新来源角色", message: error.localizedDescription)
        }
    }
}
