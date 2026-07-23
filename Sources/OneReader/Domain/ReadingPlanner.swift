import Foundation

struct ReadingPlanner: Sendable {
    func makePlan(
        graph: ReadingGraph,
        goal: ReadingGoal,
        progress: ReadingProgress
    ) -> ReadingPlan {
        let ordered: [ReadingUnit]
        switch goal {
        case .systematic:
            ordered = graph.units.sorted { $0.sourceOrder < $1.sourceOrder }

        case .quickOverview:
            let sourceOrder = graph.units.sorted { $0.sourceOrder < $1.sourceOrder }
            let introduction = sourceOrder.first
            let remainder = sourceOrder
                .dropFirst()
                .sorted { left, right in
                    let leftScore = left.importance / Double(max(left.estimatedMinutes, 1))
                    let rightScore = right.importance / Double(max(right.estimatedMinutes, 1))
                    if leftScore == rightScore {
                        return left.sourceOrder < right.sourceOrder
                    }
                    return leftScore > rightScore
                }
            ordered = [introduction].compactMap { $0 } + remainder

        case .review:
            ordered = graph.units.sorted { left, right in
                let leftComplete = progress.state(for: left.id) == .completed
                let rightComplete = progress.state(for: right.id) == .completed
                if leftComplete != rightComplete {
                    return !leftComplete
                }
                return left.sourceOrder < right.sourceOrder
            }
        }

        let plannedUnits = ordered.enumerated().map { index, unit in
            PlannedUnit(
                unitID: unit.id,
                position: index,
                reason: reason(for: unit, goal: goal, progress: progress)
            )
        }
        let planVersion = DeterministicSemanticMapper.stableDigest(
            "\(graph.version)::\(goal.rawValue)::\(plannedUnits.map(\.unitID).joined(separator: "|"))"
        )
        return ReadingPlan(
            id: "plan:\(planVersion)",
            graphVersion: graph.version,
            goal: goal,
            orderedUnits: plannedUnits,
            createdAt: .now
        )
    }

    private func reason(
        for unit: ReadingUnit,
        goal: ReadingGoal,
        progress: ReadingProgress
    ) -> String {
        switch goal {
        case .systematic:
            return "保持原书结构，承接前一单元的上下文。"
        case .quickOverview:
            if unit.sourceOrder == 0 {
                return "先建立全局定位，再进入高价值章节。"
            }
            return "重要度 \(Int(unit.importance * 100))%，预计 \(unit.estimatedMinutes) 分钟。"
        case .review:
            return progress.state(for: unit.id) == .completed
                ? "已完成，放在路线末尾供回顾。"
                : "尚未完成，优先补齐。"
        }
    }
}

