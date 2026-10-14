import SwiftUI

struct SpaceOrganizationMenu: View {
    @EnvironmentObject private var model: AppModel
    let spaceIDs: Set<String>

    var body: some View {
        ForEach(SpaceOrganizationState.allCases) { state in
            Button {
                model.setOrganization(state, for: spaceIDs)
            } label: {
                Label(state == .archived ? "归档（保留内容）" : "标记为\(state.title)", systemImage: state.systemImage)
            }
        }
    }
}

struct CaptureInboxSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: Set<String> = []
    @State private var isSelecting = false
    @State private var showCompleted = false
    private var pending: [CaptureJob] { model.visibleCaptureJobs.filter { $0.phase != .ready } }
    private var completed: [CaptureJob] { model.visibleCaptureJobs.filter { $0.phase == .ready } }
    private var selectedJobs: [CaptureJob] { model.captureJobs.filter { selection.contains($0.id) } }
    private var selectedSpaceIDs: Set<String> { Set(selectedJobs.compactMap(\.spaceID)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    ReaderSectionHeading(title: "收集任务", systemImage: "tray.and.arrow.down", count: model.visibleCaptureJobs.count)
                    Spacer()
                    headerActions
                }
                VStack(alignment: .leading, spacing: 8) {
                    ReaderSectionHeading(title: "收集任务", systemImage: "tray.and.arrow.down", count: model.visibleCaptureJobs.count)
                    headerActions
                }
            }
            Text("“已接收”只表示内容已保存。链接需要联网取回；文件和完成的快照可离线阅读。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if model.isReceivingCaptures > 0 {
                HStack { ProgressView(); Text("正在接收并保存副本…") }
                    .font(.callout)
            }
            if isSelecting, !selection.isEmpty {
                ReaderAdaptiveActions {
                    Text("已选 \(selection.count) 项").font(.caption)
                    Menu("整理状态") { SpaceOrganizationMenu(spaceIDs: selectedSpaceIDs) }
                        .disabled(selectedSpaceIDs.isEmpty)
                    destinationMenu
                    Button("取消任务") {
                        selection.forEach(model.cancelCapture)
                        selection.removeAll()
                    }
                    .disabled(selectedJobs.allSatisfy { $0.phase == .ready })
                }
                .buttonStyle(.borderless)
            }
            ForEach(pending) { job in row(job) }
            if !completed.isEmpty {
                DisclosureGroup("已完成 \(completed.count) 项", isExpanded: $showCompleted) {
                    ForEach(completed) { job in row(job) }
                }
                .font(.callout)
            }
        }
        .onChange(of: model.captureJobs.map(\.id)) { _, ids in
            selection.formIntersection(ids)
        }
        .accessibilityIdentifier("capture-inbox-section")
    }

    private var headerActions: some View {
        ReaderAdaptiveActions {
            Button {
                isSelecting.toggle()
                if !isSelecting { selection.removeAll() }
            } label: {
                ReaderActionLabel(title: isSelecting ? "完成" : "选择", systemImage: "checkmark.circle")
            }
            .accessibilityLabel(isSelecting ? "完成选择任务" : "选择任务")
            Button { model.resumeCaptures() } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(minWidth: ReaderChromeMetrics.actionHeight, minHeight: ReaderChromeMetrics.actionHeight)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("检查分享并继续等待导入的任务")
            .help("检查分享并继续等待导入的任务")
        }
        .buttonStyle(.borderless)
    }

    private var destinationMenu: some View {
        Menu("整理到空间") {
            Text("保留原空间及阅读记录，将来源加入目标空间。")
            ForEach(model.spaces.filter { $0.organizationState != .archived }) { space in
                Button(space.title) {
                    model.organizeCaptures(selection, intoSpaceID: space.id)
                    selection.removeAll()
                }
            }
        }
        .disabled(selectedJobs.contains { $0.phase != .ready })
    }

    private func row(_ job: CaptureJob) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if isSelecting {
                Button {
                    if !selection.insert(job.id).inserted { selection.remove(job.id) }
                } label: {
                    Image(systemName: selection.contains(job.id) ? "checkmark.circle.fill" : "circle")
                        .frame(minWidth: ReaderChromeMetrics.actionHeight, minHeight: ReaderChromeMetrics.actionHeight)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("选择 \(job.receipt.displayName)")
                .accessibilityAddTraits(selection.contains(job.id) ? .isSelected : [])
            } else if job.phase.isActive {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: job.phase == .ready ? "checkmark.circle" : (job.phase == .failed ? "exclamationmark.circle" : "tray"))
                    .foregroundStyle(job.phase == .failed ? Color.red : ReaderTheme.accent)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(job.receipt.displayName).font(.subheadline.weight(.medium))
                    .lineLimit(2)
                ReaderStatusBadge(title: job.phase.title,
                    systemImage: job.phase == .ready ? "checkmark.circle" : "tray",
                    tint: job.phase == .failed ? .red : ReaderTheme.accent)
                Text(job.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                ReaderAdaptiveActions {
                    actions(job)
                }
                .buttonStyle(.borderless)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(ReaderTheme.raised, in: RoundedRectangle(cornerRadius: ReaderTheme.panelRadius))
        .overlay { RoundedRectangle(cornerRadius: ReaderTheme.panelRadius).stroke(.separator.opacity(0.4), lineWidth: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capture-job-\(job.id)")
    }

    @ViewBuilder
    private func actions(_ job: CaptureJob) -> some View {
        if job.phase == .ready, let spaceID = job.spaceID {
            if job.sourceID.flatMap(model.source(id:)) != nil {
                Button {
                    model.openSpace(spaceID, preferredSourceID: job.sourceID)
                } label: {
                    ReaderActionLabel(title: "直接阅读", systemImage: "book")
                }
            } else {
                Text("来源已移除，需重新收集").font(.caption).foregroundStyle(.secondary)
            }
            Menu("整理") {
                SpaceOrganizationMenu(spaceIDs: [spaceID])
                Divider()
                ForEach(model.spaces.filter { $0.id != spaceID && $0.organizationState != .archived }) { space in
                    Button("加入“\(space.title)”") {
                        model.organizeCaptures([job.id], intoSpaceID: space.id)
                    }
                }
            }
        } else if job.phase.canRetry || job.phase == .waitingForImport {
            if job.requiresLargeImportConfirmation {
                Button("确认大型导入并重试") { model.retryCapture(job.id, confirmLargeImport: true) }
            } else {
                Button(job.phase == .waitingForImport ? "继续导入" : "重试") {
                    model.retryCapture(job.id)
                }
            }
        }
        if job.phase != .ready && job.phase != .cancelled {
            Button("取消任务") { model.cancelCapture(job.id) }
        }
    }
}
