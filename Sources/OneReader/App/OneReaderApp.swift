import SwiftUI

public struct OneReaderScene: Scene {
    @StateObject private var model = AppModel()

    public init() {}

    public var body: some Scene {
#if os(macOS)
        WindowGroup {
            WorkspaceView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 650)
        }
        .defaultSize(width: 1_440, height: 900)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            SidebarCommands()
            CommandGroup(after: .newItem) {
                Button("打开材料…") {
                    model.presentLocalSourceImporter()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("添加 URL…") {
                    model.isImportSheetPresented = true
                }
                .keyboardShortcut("l", modifiers: [.command])

                if model.isReadingWorkspaceOpen {
                    Button("加入当前 Reading Space…") {
                        model.presentLocalSourceImporter(destination: .currentSpace)
                    }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                }
            }
            CommandMenu("阅读") {
                Button("上一项") {
                    model.selectPreviousNode()
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

                Button("下一项") {
                    model.selectNextNode()
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])

                Divider()

                Button("添加书签") {
                    model.addBookmark()
                }
                .keyboardShortcut("d", modifiers: [.command])

                Button("高亮所选文本") {
                    model.addHighlight()
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(!model.canCreateHighlight)

                Divider()

                Button("搜索 Reading Space") {
                    model.navigationTab = .search
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            CommandMenu("窗口布局") {
                Button("紧凑窗口") {
                    model.resizeMainWindow(width: 900, height: 650)
                }
                .keyboardShortcut("1", modifiers: [.control, .option])

                Button("专注阅读窗口") {
                    model.resizeMainWindow(width: 1_440, height: 900)
                }
                .keyboardShortcut("2", modifiers: [.control, .option])
            }
        }

        Settings {
            ReaderSettingsView()
                .environmentObject(model)
        }
#else
        WindowGroup {
            WorkspaceView()
                .environmentObject(model)
        }
#endif
    }
}
