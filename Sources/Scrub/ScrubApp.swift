import ScrubCore
import SwiftUI

@main
struct ScrubApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("Scrub", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 540)
                .onAppear { delegate.model = model }
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Choose File…") { model.choose() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Paste") { model.paste() }.keyboardShortcut("v")
                Button("Copy Result") { model.viaShortcut(.copy) }.keyboardShortcut("c", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save…") { model.viaShortcut(.save) }.keyboardShortcut("s")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor func applicationWillTerminate(_ notification: Notification) {
        model?.releaseClipboard()
    }
}
