import SwiftUI

struct LibrarySidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            brandHeader
            Divider()
            List {
                Section("资料库") {
                    ForEach(LibraryCollection.allCases) { collection in
                        Button {
                            model.selectCollection(collection)
                        } label: {
                            HStack {
                                Label(collection.title, systemImage: collection.systemImage)
                                Spacer()
                                if count(for: collection) > 0 {
                                    Text("\(count(for: collection))")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            model.selectedCollection == collection && !model.isReadingWorkspaceOpen
                                ? ReaderTheme.teal.opacity(0.12)
                                : Color.clear
                        )
                        .accessibilityAddTraits(
                            model.selectedCollection == collection ? .isSelected : []
                        )
                    }
                }

                if !model.spaces.isEmpty {
                    Section("阅读空间") {
                        ForEach(model.spaces) { space in
                            Button {
                                model.openSpace(space.id)
                            } label: {
                                SpaceSidebarRow(
                                    space: space,
                                    sourceCount: model.sourceIDs(in: space.id).count,
                                    progress: model.progressFraction(for: space.id)
                                )
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(
                                model.selectedSpaceID == space.id && model.isReadingWorkspaceOpen
                                    ? ReaderTheme.teal.opacity(0.12)
                                    : Color.clear
                            )
                            .contextMenu {
                                Button(space.isFavorite ? "取消收藏" : "收藏") {
                                    model.toggleSpaceFavorite(space.id)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            Button {
                model.isImportSheetPresented = true
            } label: {
                Label("添加材料", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("o", modifiers: [.command])
            .accessibilityHint("打开统一来源导入器")
        }
        .navigationTitle("OneReader")
        .background(ReaderTheme.window)
    }

    private var brandHeader: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(ReaderTheme.accent)
                Image(systemName: "books.vertical.fill")
                    .foregroundStyle(.white)
                    .font(.system(size: 18, weight: .semibold))
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("OneReader")
                    .font(.headline)
                Text("你的统一阅读资料库")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .accessibilityElement(children: .combine)
    }

    private func count(for collection: LibraryCollection) -> Int {
        switch collection {
        case .allSpaces: model.spaces.count
        case .recent: model.spaces.filter { $0.lastOpenedAt != nil }.count
        case .processing: model.activePendingImportCount + model.agentRuns.filter {
            $0.state == .queued || $0.state == .running
        }.count
        case .favorites: model.spaces.filter(\.isFavorite).count
        }
    }
}

private struct SpaceSidebarRow: View {
    let space: ReadingSpace
    let sourceCount: Int
    let progress: Double

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: space.isFavorite ? "star.fill" : "book.closed")
                .foregroundStyle(space.isFavorite ? ReaderTheme.orange : ReaderTheme.teal)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(space.title)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(sourceCount) 个来源")
                    if progress > 0 {
                        Text("·")
                        Text("\(Int(progress * 100))%")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(space.title)，\(sourceCount) 个来源，进度 \(Int(progress * 100))%")
    }
}
