import Cocoa
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var viewModel: VideoIndexViewModel?

    private let rootDir: String
    private let indexFile: String

    init(rootDir: String, indexFile: String) {
        self.rootDir = rootDir
        self.indexFile = indexFile
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let vm = VideoIndexViewModel(rootDir: rootDir, indexFile: indexFile)
        self.viewModel = vm
        let contentView = ContentView(viewModel: vm)

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
