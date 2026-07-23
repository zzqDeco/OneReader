import SwiftUI

@main
struct OneReaderApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            WorkspaceView()
                .environmentObject(model)
                .frame(minWidth: 700, minHeight: 560)
        }
        .defaultSize(width: 1_440, height: 900)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            SidebarCommands()
            CommandGroup(after: .newItem) {
                Button("导入 GitHub Repo…") {
                    model.isImportSheetPresented = true
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("打开 PDF…") {
                    model.presentLocalPDFImporter()
                }
                .keyboardShortcut("o", modifiers: [.command, .option])
            }
            CommandMenu("阅读") {
                Button("上一个阅读单元") {
                    model.selectPreviousUnit()
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

                Button("下一个阅读单元") {
                    model.selectNextUnit()
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])

                Divider()

                Button("标记当前单元已完成") {
                    model.markCurrentUnitCompleted(advance: false)
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
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
    }
}
