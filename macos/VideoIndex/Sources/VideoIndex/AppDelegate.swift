import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var playerViewController: PlayerViewController!

    private let rootDir: String
    private let indexFile: String

    init(rootDir: String, indexFile: String) {
        self.rootDir = rootDir
        self.indexFile = indexFile
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        playerViewController = PlayerViewController(rootDir: rootDir, indexFile: indexFile)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1550, height: 1000),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "videoindex"
        window.contentViewController = playerViewController
        // Remembers size/position across launches on its own; only center
        // it manually the first time there's nothing saved yet to restore.
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
