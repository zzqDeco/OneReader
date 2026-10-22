import Foundation

extension AppModel {
    var effectiveReadingGoalPrompt: String {
        let trimmed = customReadingGoalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return selectedReadingGoal.rawValue
        }
        return "custom:\(trimmed)"
    }

    var currentEvidenceQA: CompletedEvidenceQA? {
        if let answer = evidenceAnswer {
            if let matched = evidenceQAHistory.first(where: { $0.answer == answer }) {
                return matched
            }
            guard let spaceID = selectedSpaceID else { return nil }
            return CompletedEvidenceQA(
                id: "live-evidence-answer",
                runID: "live-evidence-answer",
                spaceID: spaceID,
                question: "当前问答",
                answer: answer
            )
        }
        return evidenceQAHistory.first
    }

    func selectReadingGoal(_ goal: ReadingGoal) {
        selectedReadingGoal = goal
        updateProgress { $0.activeGoal = goal }
    }

    func launchIntentAgentPipeline(skipHighConfidenceRouting: Bool = true) {
        guard spaceSupportsAgentEvidence else {
            notice = AppNotice(
                title: "当前空间没有可引用正文",
                message: "系统预览材料只支持整份材料的书签和笔记，暂时不能生成阅读结构。"
            )
            return
        }
        guard activeProvider != nil else {
            inspectorTab = .activity
            isInspectorPresented = true
            notice = AppNotice(
                title: "尚未配置模型",
                message: "基础阅读不需要模型；若要生成阅读结构与路线，请先在设置中配置并测试模型服务。"
            )
            return
        }
        agentTask?.cancel()
        guard let spaceID = selectedSpaceID else { return }
        let generation = workspaceGeneration
        let goal = effectiveReadingGoalPrompt
        updateProgress { $0.activeGoal = selectedReadingGoal }
        agentTask = Task { [weak self] in
            await self?.executeIntentAgentPipeline(
                spaceID: spaceID,
                generation: generation,
                goal: goal,
                skipHighConfidenceRouting: skipHighConfidenceRouting
            )
        }
    }

    func reprojectReadingRouteForSelectedGoal() {
        guard spaceSupportsAgentEvidence else {
            notice = AppNotice(
                title: "当前空间没有可引用正文",
                message: "系统预览材料只支持整份材料的书签和笔记，暂时不能生成阅读结构。"
            )
            return
        }
        guard activeProvider != nil else {
            inspectorTab = .activity
            isInspectorPresented = true
            notice = AppNotice(
                title: "尚未配置模型",
                message: "基础阅读不需要模型；若要生成阅读结构与路线，请先在设置中配置并测试模型服务。"
            )
            return
        }
        agentTask?.cancel()
        guard let spaceID = selectedSpaceID else { return }
        let generation = workspaceGeneration
        let goal = effectiveReadingGoalPrompt
        updateProgress { $0.activeGoal = selectedReadingGoal }
        agentTask = Task { [weak self] in
            guard let self, let database else { return }
            let manifest = (try? database.currentSnapshotManifest(spaceID: spaceID)) ?? [:]
            if let graph = self.currentGraph,
               !manifest.isEmpty,
               Set(graph.sourceSnapshots.map(\.id)) == Set(manifest.values) {
                await self.executeAgentPipelineAfterMaterialize(
                    spaceID: spaceID,
                    generation: generation,
                    goal: goal
                )
            } else {
                await self.executeIntentAgentPipeline(
                    spaceID: spaceID,
                    generation: generation,
                    goal: goal,
                    skipHighConfidenceRouting: true
                )
            }
        }
    }

    func executeIntentAgentPipeline(
        spaceID: String,
        generation: UUID,
        goal: String,
        skipHighConfidenceRouting: Bool = true,
        routingAfterSourceID: String? = nil
    ) async {
        guard selectedSpaceID == spaceID,
              workspaceGeneration == generation,
              let database else { return }
        let manifest: [String: String]
        do {
            manifest = try database.currentSnapshotManifest(spaceID: spaceID)
        } catch {
            if selectedSpaceID == spaceID, workspaceGeneration == generation {
                notice = AppNotice(title: "阅读辅助无法启动", message: error.localizedDescription)
            }
            return
        }

        let orderedSourceIDs = manifest.keys.sorted()
        let sourceIDsToRoute: ArraySlice<String>
        if let routingAfterSourceID,
           let index = orderedSourceIDs.firstIndex(of: routingAfterSourceID) {
            sourceIDsToRoute = orderedSourceIDs[orderedSourceIDs.index(after: index)...]
        } else {
            sourceIDsToRoute = orderedSourceIDs[...]
        }
        var routedAnySource = false
        for sourceID in sourceIDsToRoute {
            guard selectedSpaceID == spaceID,
                  workspaceGeneration == generation,
                  let snapshotID = manifest[sourceID] else { return }
            let installed = try? database.fetchAdapterPlan(snapshotID: snapshotID)
            if Self.shouldSkipAdapterRouting(
                installedPlan: installed,
                skipHighConfidenceRouting: skipHighConfidenceRouting
            ) {
                continue
            }
            let state = await runAgentTask(
                .routeAdapters,
                spaceID: spaceID,
                pipeline: .readingStructure,
                goal: goal,
                targetSourceID: sourceID,
                targetSnapshotID: snapshotID,
                generation: generation
            )
            guard state == .completed else { return }
            routedAnySource = true
        }

        if routedAnySource,
           selectedSpaceID == spaceID,
           workspaceGeneration == generation,
           let selectedSourceID,
           manifest[selectedSourceID] != nil {
            openSource(selectedSourceID)
        }

        guard selectedSpaceID == spaceID,
              workspaceGeneration == generation else { return }
        guard await runAgentTask(
            .scoutSpace,
            spaceID: spaceID,
            pipeline: .readingStructure,
            goal: goal,
            generation: generation
        ) == .completed else { return }

        guard selectedSpaceID == spaceID,
              workspaceGeneration == generation else { return }
        guard await runAgentTask(
            .materializeGraph,
            spaceID: spaceID,
            pipeline: .readingStructure,
            goal: goal,
            generation: generation
        ) == .completed else { return }

        guard selectedSpaceID == spaceID,
              workspaceGeneration == generation else { return }
        await executeAgentPipelineAfterMaterialize(
            spaceID: spaceID,
            generation: generation,
            goal: goal
        )
    }

    static func shouldSkipAdapterRouting(
        installedPlan: AdapterPlan?,
        skipHighConfidenceRouting: Bool
    ) -> Bool {
        guard let installedPlan else { return false }
        if installedPlan.isUserOverride || installedPlan.id.hasPrefix("agent-adapter-plan:") {
            return true
        }
        return skipHighConfidenceRouting && installedPlan.confidence >= 0.85
    }

    func saveEvidenceQAAsNote(_ qa: CompletedEvidenceQA, citationIndex: Int = 0) {
        let citation: EvidenceCitation?
        if qa.answer.citations.indices.contains(citationIndex) {
            citation = qa.answer.citations[citationIndex]
        } else {
            citation = qa.answer.citations.first
        }
        guard let database, let citation else { return }
        let spaceID = selectedSpaceID ?? qa.spaceID
        let locator = citation.locator
        let quote = citation.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        let questionText = qa.question.trimmingCharacters(in: .whitespacesAndNewlines)
        let answerText = qa.answer.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteBody = questionText.isEmpty
            ? "【研读问答】\n\(answerText)"
            : "【研读问答】\(questionText)\n\(answerText)"
        let annotation = Annotation(
            id: UUID().uuidString.lowercased(),
            spaceID: spaceID,
            sourceID: locator.sourceID,
            snapshotID: locator.snapshotID,
            kind: .note,
            locator: locator,
            anchorState: .current,
            selectedText: quote.isEmpty ? nil : quote,
            note: noteBody,
            color: nil,
            createdAt: .now,
            updatedAt: .now
        )
        do {
            try database.saveAnnotation(annotation)
            loadAnnotations()
            notesCenter?.invalidate()
            notice = AppNotice(
                title: "已存为证据笔记",
                message: "问答结论与原文引证已保存到当前空间笔记。"
            )
        } catch {
            notice = AppNotice(title: "无法保存标注", message: error.localizedDescription)
        }
    }
}
