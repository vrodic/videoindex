import Cocoa
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var viewModel: VideoIndexViewModel!

    private let rootDir: String
    private let indexFile: String

    init(rootDir: String, indexFile: String) {
        self.rootDir = rootDir
        self.indexFile = indexFile
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        viewModel = VideoIndexViewModel(rootDir: rootDir, indexFile: indexFile)
        let contentView = ContentView(viewModel: viewModel)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1550, height: 1000),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "videoindex"
        window.contentViewController = NSHostingController(rootView: contentView)

        let restoredFrame = window.setFrameAutosaveName("VideoIndexMainWindow")
        if !restoredFrame {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
