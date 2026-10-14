import SwiftUI

/// Presentation-only completion receipt for the debounced query in the sheet.
/// Neither its state nor the localized labels are written to the Library.
struct NotesRefreshKey: Equatable, Sendable {
    let query: NotesQuery
    let revision: UUID
}

enum NotesResultsPhase: Equatable {
    case loading, results, empty, failed
}

struct NotesRefreshPresentation {
    private(set) var settledKey: NotesRefreshKey?
    private(set) var settledLoadError: String?

    @discardableResult
    mutating func complete(_ requested: NotesRefreshKey, current: NotesRefreshKey,
        cancelled: Bool, outcome: NotesReloadOutcome = .loaded) -> Bool {
        guard !cancelled, requested == current, outcome != .superseded else { return false }
        settledKey = requested
        if case .failed(let error) = outcome { settledLoadError = error }
        else { settledLoadError = nil }
        return true
    }

    func phase(current: NotesRefreshKey, isLoading: Bool, entryCount: Int) -> NotesResultsPhase {
        guard settledKey == current else { return .loading }
        if entryCount > 0 { return .results }
        if isLoading { return .loading }
        if settledLoadError != nil { return .failed }
        return .empty
    }

    func loadError(current: NotesRefreshKey) -> String? {
        settledKey == current ? settledLoadError : nil
    }

    func visibleTotalCount(current: NotesRefreshKey, totalCount: Int) -> Int {
        guard settledKey == current, settledLoadError == nil else { return 0 }
        return max(0, totalCount)
    }

    func isUpdating(current: NotesRefreshKey, isLoading: Bool) -> Bool {
        settledKey != current || isLoading
    }
}

struct NotesResultsPlaceholder: View {
    let phase: NotesResultsPhase
    let onRetry: () -> Void

    var body: some View {
        Group {
            switch phase {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在载入笔记…").font(.callout)
                    Text("仅搜索已保存的摘录与用户笔记")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("notes-results-loading")
            case .empty:
                ContentUnavailableView("没有匹配的标注", systemImage: "note.text",
                    description: Text("搜索仅包含摘录与用户笔记，不会搜索或外发来源正文。"))
                    .accessibilityIdentifier("notes-results-empty")
            case .failed:
                ContentUnavailableView {
                    Label("笔记暂未载入", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("已有笔记未被更改。请重试，或调整筛选条件。")
                } actions: {
                    Button(action: onRetry) {
                        ReaderActionLabel(title: "重新载入", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("notes-results-retry")
                }
                .accessibilityIdentifier("notes-results-failed")
            case .results:
                EmptyView()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Localized chrome keeps revision and anchor state as independent facts.
struct ReaderAnnotationStatus: Equatable {
    let title: String
    let systemImage: String
    let isWarning: Bool

    init(anchorState: AnnotationAnchorState, sourceAvailable: Bool = true,
        isLatestSnapshot: Bool = true) {
        if !sourceAvailable {
            title = "来源不可用"
            systemImage = "exclamationmark.triangle"
            isWarning = true
        } else if !isLatestSnapshot {
            switch anchorState {
            case .current: title = "历史版本"
            case .relocated: title = "历史版本 · 已重定位"
            case .orphaned: title = "历史版本 · 位置待恢复"
            }
            systemImage = "clock.arrow.circlepath"
            isWarning = true
        } else {
            switch anchorState {
            case .current:
                title = "当前版本"
                systemImage = "checkmark.circle"
                isWarning = false
            case .relocated:
                title = "已重定位"
                systemImage = "arrow.triangle.branch"
                isWarning = false
            case .orphaned:
                title = "位置待恢复"
                systemImage = "exclamationmark.triangle"
                isWarning = true
            }
        }
    }
}

struct ReaderAnnotationStatusLabel: View {
    let status: ReaderAnnotationStatus

    var body: some View {
        Label(status.title, systemImage: status.systemImage)
            .font(.caption)
            .foregroundStyle(status.isWarning ? ReaderTheme.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension NotesEntry {
    var presentationStatus: ReaderAnnotationStatus {
        ReaderAnnotationStatus(anchorState: annotation.anchorState,
            sourceAvailable: sourceAvailable, isLatestSnapshot: isLatestSnapshot)
    }
}
