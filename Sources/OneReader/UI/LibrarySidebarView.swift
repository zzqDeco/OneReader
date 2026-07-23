import SwiftUI

struct LibrarySidebarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var searchText = ""

    private var filteredUnits: [ReadingUnit] {
        guard !searchText.isEmpty else { return model.graph.units }
        return model.graph.units.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.summary.localizedCaseInsensitiveContains(searchText)
                || $0.fragments.contains {
                    $0.label.localizedCaseInsensitiveContains(searchText)
                }
        }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { model.selectedUnitID },
            set: { value in
                guard let value else { return }
                model.selectUnit(value)
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            collectionHeader
            Divider()
            List(selection: selection) {
                Section("材料") {
                    ForEach(model.sources) { source in
                        SourceRow(source: source)
                    }
                }

                Section("阅读单元 · \(filteredUnits.count)") {
                    ForEach(filteredUnits) { unit in
                        UnitSidebarRow(
                            unit: unit,
                            state: model.progress.state(for: unit.id)
                        )
                        .tag(unit.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $searchText, placement: .sidebar, prompt: "搜索标题或证据")
        }
        .navigationTitle("OneReader")
        .background(.ultraThinMaterial)
    }

    private var collectionHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(ReaderTheme.teal.gradient)
                    Image(systemName: "books.vertical.fill")
                        .foregroundStyle(.white)
                        .font(.system(size: 17, weight: .semibold))
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.graph.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text("可定位的内容空间")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                ProgressView(value: model.completionFraction)
                    .tint(ReaderTheme.teal)
                Text("\(model.completedCount)/\(model.graph.units.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }
}

private struct SourceRow: View {
    let source: ReadingSource

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: source.kind == .pdf ? "doc.richtext" : "point.3.connected.trianglepath.dotted")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(source.kind == .pdf ? ReaderTheme.orange : ReaderTheme.teal)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(source.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Image(systemName: availabilitySymbol)
                .font(.caption)
                .foregroundStyle(availabilityColor)
                .accessibilityLabel(availabilityLabel)
        }
        .padding(.vertical, 3)
    }

    private var availabilitySymbol: String {
        switch source.availability {
        case .ready: "checkmark.circle.fill"
        case .resolving: "clock.fill"
        case .offline: "exclamationmark.triangle.fill"
        case .stale: "arrow.triangle.2.circlepath.circle.fill"
        }
    }

    private var availabilityColor: Color {
        switch source.availability {
        case .ready: ReaderTheme.teal
        case .resolving: .orange
        case .offline: .red
        case .stale: .yellow
        }
    }

    private var availabilityLabel: String {
        switch source.availability {
        case .ready: "已就绪"
        case .resolving: "正在解析"
        case .offline: "暂时离线"
        case .stale: "版本已变化"
        }
    }
}

private struct UnitSidebarRow: View {
    let unit: ReadingUnit
    let state: UnitProgressState

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: stateSymbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(stateColor)
                .frame(width: 16, height: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(unit.title)
                    .font(.subheadline)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text("\(unit.estimatedMinutes) 分钟")
                    if unit.fragments.count > 1 {
                        Text("·")
                        Text("双源")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(unit.title)，\(stateLabel)，预计 \(unit.estimatedMinutes) 分钟")
    }

    private var stateSymbol: String {
        switch state {
        case .completed: "checkmark.circle.fill"
        case .reading: "circle.lefthalf.filled"
        case .previewed: "eye.circle.fill"
        case .skipped: "forward.circle.fill"
        case .needsReview: "arrow.clockwise.circle.fill"
        case .unseen: "circle"
        }
    }

    private var stateColor: Color {
        switch state {
        case .completed: ReaderTheme.teal
        case .reading: ReaderTheme.orange
        case .needsReview: .yellow
        default: .secondary
        }
    }

    private var stateLabel: String {
        switch state {
        case .completed: "已完成"
        case .reading: "阅读中"
        case .previewed: "已预览"
        case .skipped: "已跳过"
        case .needsReview: "需要复习"
        case .unseen: "未开始"
        }
    }
}

