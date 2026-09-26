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
                // The palette is light only; system chrome (popovers, menus,
                // panels) must match it rather than the system appearance.
                .preferredColorScheme(.light)
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
                Button("Copy") { model.copyCommand() }.keyboardShortcut("c")
                Button("Paste") { model.paste() }.keyboardShortcut("v")
                Button("Select All") { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }.keyboardShortcut("a")
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
