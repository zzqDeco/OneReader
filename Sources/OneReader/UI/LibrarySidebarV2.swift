import SwiftUI

struct LibrarySidebarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var spaceRenameDraft = ""
    @State private var sourceRenameDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            brandHeader
            Divider()
            List {
                Section("资料库") {
                    Button(action: model.openNotesCenter) {
                        Label("笔记", systemImage: "note.text")
                    }
                    .accessibilityIdentifier("library-notes")
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
                        ForEach(model.spaces.filter { $0.organizationState != .archived }) { space in
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
                                Button("重命名空间…") {
                                    model.requestSpaceRename(space)
                                }
                                Divider()
                                SpaceOrganizationMenu(spaceIDs: [space.id])
                                Divider()
                                Button("删除空间…", role: .destructive) {
                                    model.requestSpaceDeletion(space)
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
        .onChange(of: model.spacePendingRename) { _, space in
            spaceRenameDraft = space?.title ?? ""
        }
        .onChange(of: model.sourcePendingRename) { _, source in
            sourceRenameDraft = source?.displayName ?? ""
        }
        .alert(
            "重命名空间",
            isPresented: Binding(
                get: { model.spacePendingRename != nil },
                set: { if !$0 { model.spacePendingRename = nil } }
            ),
            presenting: model.spacePendingRename
        ) { space in
            TextField("空间名称", text: $spaceRenameDraft)
            Button("保存") {
                model.renameSpace(space.id, title: spaceRenameDraft)
            }
            Button("取消", role: .cancel) {
                model.spacePendingRename = nil
            }
        } message: { space in
            Text("为“\(space.title)”输入新的空间名称。")
        }
        .alert(
            "重命名来源",
            isPresented: Binding(
                get: { model.sourcePendingRename != nil },
                set: { if !$0 { model.sourcePendingRename = nil } }
            ),
            presenting: model.sourcePendingRename
        ) { source in
            TextField("来源名称", text: $sourceRenameDraft)
            Button("保存") {
                model.renameSource(source.id, displayName: sourceRenameDraft)
            }
            Button("取消", role: .cancel) {
                model.sourcePendingRename = nil
            }
        } message: { source in
            Text("为“\(source.displayName)”输入新的显示名称。")
        }
        .confirmationDialog(
            "删除阅读空间？",
            isPresented: Binding(
                get: { model.spacePendingDeletion != nil },
                set: { if !$0 { model.spacePendingDeletion = nil } }
            ),
            presenting: model.spacePendingDeletion
        ) { _ in
            Button("删除空间", role: .destructive) {
                model.confirmSpaceDeletion()
            }
            Button("取消", role: .cancel) {
                model.spacePendingDeletion = nil
            }
        } message: { space in
            Text("将删除“\(space.title)”及其仅属于该空间的来源；与其他空间共享的来源会继续保留。")
        }
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
        case .allSpaces: model.spaces.filter { $0.organizationState != .archived }.count
        case .recent: model.spaces.filter { $0.lastOpenedAt != nil && $0.organizationState != .archived }.count
        case .processing: model.activePendingImportCount + model.agentRuns.filter {
            $0.state == .queued || $0.state == .running
        }.count
        case .favorites: model.spaces.filter { $0.isFavorite && $0.organizationState != .archived }.count
        case .inbox: model.spaces.filter { $0.organizationState == .inbox }.count
            + model.captureJobs.filter { $0.phase != .ready && $0.sourceID == nil }.count
        case .reading: model.spaces.filter { $0.organizationState == .reading }.count
        case .read: model.spaces.filter { $0.organizationState == .read }.count
        case .archived: model.spaces.filter { $0.organizationState == .archived }.count
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
