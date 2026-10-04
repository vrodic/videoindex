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
        let wordCloudItem = NSMenuItem(title: "Word Cloud Search...", action: Selector(("openWordCloud:")), keyEquivalent: "k")
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
        editMenu.addItem(wordCloudItem)
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

        // Options Menu
        let optionsMenuItem = NSMenuItem()
        let optionsMenu = NSMenu(title: "Options")
        let saveThumbnailsItem = NSMenuItem(title: "Save Thumbnails to Disk", action: Selector(("toggleSaveThumbnailsToDisk:")), keyEquivalent: "")
        optionsMenu.addItem(saveThumbnailsItem)
        optionsMenuItem.submenu = optionsMenu
        mainMenu.addItem(optionsMenuItem)

        // MPV Options Menu
        let mpvMenuItem = NSMenuItem()
        let mpvMenu = NSMenu(title: "MPV")

        let volumeMaxItem = NSMenuItem(title: "Max Volume 1000 (--volume-max=1000)", action: Selector(("toggleMpvVolumeMax1000:")), keyEquivalent: "")
        let muteItem = NSMenuItem(title: "Mute (--mute=yes)", action: Selector(("toggleMpvMute:")), keyEquivalent: "")
        let loopItem = NSMenuItem(title: "Loop Video (--loop-file=inf)", action: Selector(("toggleMpvLoop:")), keyEquivalent: "")
        let noAudioItem = NSMenuItem(title: "No Audio (--no-audio)", action: Selector(("toggleMpvNoAudio:")), keyEquivalent: "")
        let keepOpenItem = NSMenuItem(title: "Keep Open After Playback (--keep-open=yes)", action: Selector(("toggleMpvKeepOpen:")), keyEquivalent: "")
        let ontopItem = NSMenuItem(title: "Always On Top (--ontop)", action: Selector(("toggleMpvOntop:")), keyEquivalent: "")
        let hwdecItem = NSMenuItem(title: "Hardware Decoding (--hwdec=auto)", action: Selector(("toggleMpvHwdec:")), keyEquivalent: "")

        // Window size submenu
        let windowSizeMenuItem = NSMenuItem(title: "Autofit Window Size", action: nil, keyEquivalent: "")
        let windowSizeSubmenu = NSMenu(title: "Autofit Window Size")
        let size50Item = NSMenuItem(title: "50%", action: Selector(("setMpvAutofit50:")), keyEquivalent: "")
        let size75Item = NSMenuItem(title: "75% (Default)", action: Selector(("setMpvAutofit75:")), keyEquivalent: "")
        let size100Item = NSMenuItem(title: "100%", action: Selector(("setMpvAutofit100:")), keyEquivalent: "")
        let sizeFullscreenItem = NSMenuItem(title: "Fullscreen", action: Selector(("setMpvAutofitFullscreen:")), keyEquivalent: "")
        windowSizeSubmenu.addItem(size50Item)
        windowSizeSubmenu.addItem(size75Item)
        windowSizeSubmenu.addItem(size100Item)
        windowSizeSubmenu.addItem(sizeFullscreenItem)
        windowSizeMenuItem.submenu = windowSizeSubmenu

        // Volume submenu
        let volumeMenuItem = NSMenuItem(title: "Default Volume", action: nil, keyEquivalent: "")
        let volumeSubmenu = NSMenu(title: "Default Volume")
        let vol10Item = NSMenuItem(title: "10%", action: Selector(("setMpvVolume10:")), keyEquivalent: "")
        let vol25Item = NSMenuItem(title: "25%", action: Selector(("setMpvVolume25:")), keyEquivalent: "")
        let vol33Item = NSMenuItem(title: "33% (Default)", action: Selector(("setMpvVolume33:")), keyEquivalent: "")
        let vol50Item = NSMenuItem(title: "50%", action: Selector(("setMpvVolume50:")), keyEquivalent: "")
        let vol75Item = NSMenuItem(title: "75%", action: Selector(("setMpvVolume75:")), keyEquivalent: "")
        let vol100Item = NSMenuItem(title: "100%", action: Selector(("setMpvVolume100:")), keyEquivalent: "")
        volumeSubmenu.addItem(vol10Item)
        volumeSubmenu.addItem(vol25Item)
        volumeSubmenu.addItem(vol33Item)
        volumeSubmenu.addItem(vol50Item)
        volumeSubmenu.addItem(vol75Item)
        volumeSubmenu.addItem(vol100Item)
        volumeMenuItem.submenu = volumeSubmenu

        // Speed submenu
        let speedMenuItem = NSMenuItem(title: "Playback Speed", action: nil, keyEquivalent: "")
        let speedSubmenu = NSMenu(title: "Playback Speed")
        let speed1Item = NSMenuItem(title: "1.0x (Normal)", action: Selector(("setMpvSpeed1:")), keyEquivalent: "")
        let speed125Item = NSMenuItem(title: "1.25x", action: Selector(("setMpvSpeed125:")), keyEquivalent: "")
        let speed15Item = NSMenuItem(title: "1.5x", action: Selector(("setMpvSpeed15:")), keyEquivalent: "")
        let speed20Item = NSMenuItem(title: "2.0x", action: Selector(("setMpvSpeed20:")), keyEquivalent: "")
        speedSubmenu.addItem(speed1Item)
        speedSubmenu.addItem(speed125Item)
        speedSubmenu.addItem(speed15Item)
        speedSubmenu.addItem(speed20Item)
        speedMenuItem.submenu = speedSubmenu

        mpvMenu.addItem(volumeMaxItem)
        mpvMenu.addItem(volumeMenuItem)
        mpvMenu.addItem(NSMenuItem.separator())
        mpvMenu.addItem(muteItem)
        mpvMenu.addItem(loopItem)
        mpvMenu.addItem(noAudioItem)
        mpvMenu.addItem(keepOpenItem)
        mpvMenu.addItem(ontopItem)
        mpvMenu.addItem(hwdecItem)
        mpvMenu.addItem(NSMenuItem.separator())
        mpvMenu.addItem(windowSizeMenuItem)
        mpvMenu.addItem(speedMenuItem)

        mpvMenuItem.submenu = mpvMenu
        mainMenu.addItem(mpvMenuItem)

        NSApp.mainMenu = mainMenu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
