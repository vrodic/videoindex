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
        setupMainMenu()

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

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App Menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let appName = "videoindex"
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File Menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")

        let reloadItem = NSMenuItem(title: "Reload", action: Selector(("reloadQuery:")), keyEquivalent: "r")
        let playItem = NSMenuItem(title: "Play Selected", action: Selector(("playSelectedMedia:")), keyEquivalent: "\r")
        playItem.keyEquivalentModifierMask = [] // Plain Return
        let closeWindowItem = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        fileMenu.addItem(reloadItem)
        fileMenu.addItem(playItem)
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(closeWindowItem)

        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit Menu (Required for Cmd+Z, Cmd+Shift+Z, Cmd+X, Cmd+C, Cmd+V, Cmd+A and context menu Undo/Redo)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")

        let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        let cutItem = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let findItem = NSMenuItem(title: "Find...", action: Selector(("focusSearchField:")), keyEquivalent: "f")
        let editConditionItem = NSMenuItem(title: "Edit Condition...", action: Selector(("focusConditionField:")), keyEquivalent: "l")

        editMenu.addItem(undoItem)
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(cutItem)
        editMenu.addItem(copyItem)
        editMenu.addItem(pasteItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(selectAllItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(findItem)
        editMenu.addItem(editConditionItem)

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Controls Menu
        let controlsMenuItem = NSMenuItem()
        let controlsMenu = NSMenu(title: "Controls")

        let likeItem = NSMenuItem(title: "Like (+1)", action: Selector(("likeSelectedMedia:")), keyEquivalent: "+")
        likeItem.keyEquivalentModifierMask = []
        let dislikeItem = NSMenuItem(title: "Dislike / Delete", action: Selector(("deleteOrDislikeSelectedMedia:")), keyEquivalent: "\u{7F}")
        dislikeItem.keyEquivalentModifierMask = []

        let firstItem = NSMenuItem(title: "First Item", action: Selector(("selectFirstItem:")), keyEquivalent: "")
        let lastItem = NSMenuItem(title: "Last Item", action: Selector(("selectLastItem:")), keyEquivalent: "")

        controlsMenu.addItem(likeItem)
        controlsMenu.addItem(dislikeItem)
        controlsMenu.addItem(NSMenuItem.separator())
        controlsMenu.addItem(firstItem)
        controlsMenu.addItem(lastItem)

        controlsMenuItem.submenu = controlsMenu
        mainMenu.addItem(controlsMenuItem)

        NSApp.mainMenu = mainMenu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
