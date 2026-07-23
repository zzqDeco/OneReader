import SwiftUI

struct RouteInspectorView: View {
    @EnvironmentObject private var model: AppModel

    private var goalBinding: Binding<ReadingGoal> {
        Binding(
            get: { model.progress.activeGoal },
            set: { goal in
                model.changeGoal(goal)
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            routeHeader
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.plan.orderedUnits.enumerated()), id: \.element.id) { index, planned in
                        if let unit = model.unit(for: planned) {
                            RouteStepRow(
                                position: index + 1,
                                total: model.plan.orderedUnits.count,
                                unit: unit,
                                planned: planned,
                                state: model.progress.state(for: unit.id),
                                isSelected: model.selectedUnitID == unit.id,
                                onSelect: { model.selectUnit(unit.id) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .background(.ultraThinMaterial)
    }

    private var routeHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("阅读路线", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.headline)
                Spacer()
                Text("\(model.completedCount)/\(model.graph.units.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Picker("阅读目标", selection: goalBinding) {
                ForEach(ReadingGoal.allCases) { goal in
                    Text(goal.displayName).tag(goal)
                }
            }
            .pickerStyle(.menu)

            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: model.completionFraction)
                    .tint(ReaderTheme.teal)
                Text(model.progress.activeGoal.compactDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}

private struct RouteStepRow: View {
    let position: Int
    let total: Int
    let unit: ReadingUnit
    let planned: PlannedUnit
    let state: UnitProgressState
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 11) {
                timeline

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(unit.title)
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 6)
                        Text("\(unit.estimatedMinutes)m")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }

                    if isSelected {
                        Text(planned.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 9)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .background(
                isSelected ? ReaderTheme.teal.opacity(0.11) : .clear,
                in: RoundedRectangle(cornerRadius: 9)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "第 \(position) 步，共 \(total) 步，\(unit.title)，\(stateLabel)"
        )
    }

    private var timeline: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(circleFill)
                    .frame(width: 22, height: 22)
                if state == .completed {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(position)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(isSelected ? .white : .secondary)
                }
            }
            if position < total {
                Rectangle()
                    .fill(.separator)
                    .frame(width: 1, height: isSelected ? 48 : 31)
            }
        }
        .padding(.top, 8)
    }

    private var circleFill: Color {
        if state == .completed {
            return ReaderTheme.teal
        }
        if isSelected {
            return ReaderTheme.orange
        }
        return ReaderTheme.mutedFill
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
