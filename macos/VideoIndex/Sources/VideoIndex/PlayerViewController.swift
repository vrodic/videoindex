import Cocoa
import AVFoundation

/// Custom table row view that draws a subtle background highlight for played / viewed videos
final class CustomTableRowView: NSTableRowView {
    var isViewed: Bool = false {
        didSet {
            if oldValue != isViewed {
                needsDisplay = true
            }
        }
    }

    var isSessionPlayed: Bool = false {
        didSet {
            if oldValue != isSessionPlayed {
                needsDisplay = true
            }
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isSessionPlayed {
            // Distinct, pleasant green tint for videos played during the active session
            let sessionPlayedBackgroundColor = NSColor.systemGreen.withAlphaComponent(0.18)
            sessionPlayedBackgroundColor.setFill()
            dirtyRect.fill()
        } else if isViewed {
            // Subtle blue tint for previously viewed videos
            let viewedBackgroundColor = NSColor.systemBlue.withAlphaComponent(0.12)
            viewedBackgroundColor.setFill()
            dirtyRect.fill()
        }
    }
}

final class PlayerViewController: NSViewController, NSMenuItemValidation, NSComboBoxDelegate {

    private let rootDir: String
    private let db: Database

    private var items: [MediaItem] = []
    private var searchTerm: String = ""
    private var conditionExpression: String

    private let defaultConditions: [String] = [
        "AND like > 2 ORDER BY viewed_time, random() -- (Default: Highly liked, oldest viewed first)",
        "ORDER BY view_count ASC, file_size DESC -- (Least viewed first)",
        "ORDER BY view_count DESC -- (Most viewed)",
        "ORDER BY file_size DESC -- (Largest files)",
        "ORDER BY viewed_time DESC -- (Recently viewed)",
        "ORDER BY id DESC -- (Recently added)",
        "AND (like IS NULL OR like >= 0) ORDER BY random() -- (Unrated & liked, shuffled)",
        "AND like > 0 ORDER BY like DESC -- (Liked videos)"
    ]

    private let customConditionsKey = "CustomConditions"
    private var savedCustomConditions: [String] {
        get {
            UserDefaults.standard.stringArray(forKey: customConditionsKey) ?? []
        }
        set {
            UserDefaults.standard.set(newValue, forKey: customConditionsKey)
        }
    }

    private var lastQuerySucceeded: Bool = false
    private var hasAddedCurrentConditionToHistory: Bool = true

    private let tableView = ShortcutTableView()
    private let scrollView = NSScrollView()
    private let searchField = NSTextField()
    private let wordCloudButton = NSButton(title: "Word Cloud", target: nil, action: nil)
    private let conditionField = NSComboBox()
    private let statusLabel = NSTextField(labelWithString: "")

    private var wordCloudWindowController: WordCloudWindowController?

    private let splitViewAutosaveName = "VideoIndexMainSplit"
    private let splitView = NSSplitView()
    private let previewContainer = NSView()
    private let previewLabel = NSTextField(labelWithString: "")
    /// Points along the video's duration to grab a frame from. The preview
    /// panel is a vertical, scrollable filmstrip of these — widen the split
    /// pane and each thumbnail grows with it (they're pinned to 16:9).
    private let previewPercentages = [15, 30, 45, 60, 75, 90]
    private var previewImageViews: [Int: ClickableThumbnailView] = [:]
    private let previewScrollView = NSScrollView()
    private let upNextScrollView = NSScrollView()
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private var didSetInitialSplitPosition = false

    private var thumbnailGenerationTask: Task<Void, Never>?
    private var sessionPlayedIDs: Set<Int> = []
    private var missingFileIDs: Set<Int> = []

    private let saveThumbnailsToDiskKey = "SaveThumbnailsToDisk"
    private var saveThumbnailsToDisk: Bool {
        get {
            if UserDefaults.standard.object(forKey: saveThumbnailsToDiskKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: saveThumbnailsToDiskKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: saveThumbnailsToDiskKey)
        }
    }

    private var thumbsDirectoryURL: URL {
        URL(fileURLWithPath: rootDir).appendingPathComponent("Thumbs", isDirectory: true)
    }

    private func ensureThumbsDirectoryExists() {
        try? FileManager.default.createDirectory(at: thumbsDirectoryURL, withIntermediateDirectories: true, attributes: nil)
    }

    private func diskThumbURL(id: Int, percent: Int) -> URL {
        thumbsDirectoryURL.appendingPathComponent("\(id)_\(percent).jpg")
    }

    private func loadDiskThumbnail(id: Int, percent: Int) -> NSImage? {
        let fileURL = diskThumbURL(id: id, percent: percent)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return NSImage(contentsOf: fileURL)
    }

    private func saveDiskThumbnail(_ image: NSImage, id: Int, percent: Int) {
        guard saveThumbnailsToDisk else { return }
        ensureThumbsDirectoryExists()
        let fileURL = diskThumbURL(id: id, percent: percent)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            try? data.write(to: fileURL)
        }
    }

    private func getOrLoadThumbnail(id: Int, percent: Int) -> NSImage? {
        let key = cacheKey(id: id, percent: percent)
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }
        if let diskImage = loadDiskThumbnail(id: id, percent: percent) {
            thumbnailCache.setObject(diskImage, forKey: key)
            return diskImage
        }
        return nil
    }

    private func markMissingFile(id: Int) {
        if !missingFileIDs.contains(id) {
            missingFileIDs.insert(id)
            if let row = items.firstIndex(where: { $0.id == id }) {
                reloadRow(row)
            }
        }
    }

    // MPV options state
    private var mpvVolumeMax1000 = true
    private var mpvVolume = "33"           // default volume 33%
    private var mpvMute = false
    private var mpvLoop = false
    private var mpvNoAudio = false
    private var mpvKeepOpen = false
    private var mpvOntop = false
    private var mpvHwdec = false
    private var mpvAutofitSize = "75%x75%" // options: "50%x50%", "75%x75%", "100%x100%", "fullscreen"
    private var mpvSpeed = "1.0"           // options: "1.0", "1.25", "1.5", "2.0"

    // "Up Next" strip: current video + 9 upcoming videos (10 total),
    // displayed in a scrollable column.
    private let upNextContainer = NSView()
    private let upNextLabel = NSTextField(labelWithString: "Up Next")
    private let upNextRowAspect: CGFloat = 9.0 / 16.0
    private let upNextRowSpacing: CGFloat = 8
    private let upNextMaxSlots = 10 // current video + 9 next videos
    private let upNextPercent = 45  // shares a cache bucket with the 45% filmstrip row
    private var upNextImageViews: [ClickableThumbnailView] = []
    private var upNextAssignedItemIDs: [Int?] = []

    private let columnDefinitions: [(id: String, title: String, width: CGFloat)] = [
        ("id", "ID", 60),
        ("filename", "Filename", 520),
        ("views", "Views", 60),
        ("likes", "Likes", 60),
        ("size", "Size (MB)", 90),
        ("viewed", "Last Viewed", 150),
        ("width", "Width", 70),
        ("density", "Density", 80),
    ]

    init(rootDir: String, indexFile: String) {
        self.rootDir = rootDir
        self.db = Database(path: indexFile)
        self.conditionExpression = "AND like > 2 ORDER BY viewed_time, random() -- (Default: Highly liked, oldest viewed first)"
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1550, height: 1000))
        buildUI()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        conditionField.stringValue = conditionExpression
        reload()
        view.window?.makeFirstResponder(tableView)
    }

    override func viewDidLayout() {
        super.viewDidLayout()

        // Give the preview pane a sensible default width the first time we
        // have real bounds to work with — but only if NSSplitView's own
        // autosave didn't already restore a position from a previous launch.
        if !didSetInitialSplitPosition, splitView.bounds.width > 0 {
            didSetInitialSplitPosition = true
            let autosaveKey = "NSSplitView Subview Frames \(splitViewAutosaveName)"
            if UserDefaults.standard.object(forKey: autosaveKey) == nil {
                splitView.setPosition(splitView.bounds.width - 480, ofDividerAt: 0)
            }
        }

    }

    // MARK: - UI construction

    private func buildUI() {
        for column in columnDefinitions {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.resizingMask = column.id == "filename" ? .autoresizingMask : .userResizingMask
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.id, ascending: true)
            tableView.addTableColumn(tableColumn)
        }
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.shortcutHandler = self
        tableView.autosaveName = "VideoIndexTableColumns"
        tableView.autosaveTableColumns = true

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search filename…"
        searchField.delegate = self
        searchField.allowsEditingTextAttributes = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        wordCloudButton.bezelStyle = .rounded
        wordCloudButton.target = self
        wordCloudButton.action = #selector(openWordCloud(_:))
        wordCloudButton.translatesAutoresizingMaskIntoConstraints = false

        conditionField.placeholderString = "SQL condition / ORDER BY…"
        conditionField.delegate = self
        conditionField.allowsEditingTextAttributes = true
        conditionField.hasVerticalScroller = true
        conditionField.completes = true
        conditionField.translatesAutoresizingMaskIntoConstraints = false
        populateConditionComboBox()

        buildPreviewPanel()

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(scrollView)
        splitView.addArrangedSubview(previewContainer)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.dragThatCannotResizeWindow, forSubviewAt: 1)
        // NOTE: deliberately no fixed-width constraint on previewContainer —
        // a required-priority width constraint fights NSSplitView's own
        // layout on every drag, which is why the divider previously
        // wouldn't move. viewDidLayout() sets an initial width once instead;
        // the delegate below sets min/max but otherwise lets drags happen.
        // autosaveName makes NSSplitView remember the divider position
        // across launches on its own; viewDidLayout() only applies a
        // default the first time there's nothing to restore.
        splitView.autosaveName = NSSplitView.AutosaveName(splitViewAutosaveName)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(searchField)
        view.addSubview(wordCloudButton)
        view.addSubview(splitView)
        view.addSubview(conditionField)
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: wordCloudButton.leadingAnchor, constant: -8),

            wordCloudButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            wordCloudButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            wordCloudButton.widthAnchor.constraint(equalToConstant: 110),

            splitView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),

            conditionField.topAnchor.constraint(equalTo: splitView.bottomAnchor, constant: 10),
            conditionField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            conditionField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),

            statusLabel.topAnchor.constraint(equalTo: conditionField.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            statusLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])
    }

    /// Right-hand panel: an "Up Next" column (scrollable pool of 10 thumbnails)
    /// to the left of a scrollable filmstrip of frames from the *selected* file,
    /// both grabbed with AVFoundation (AVAssetImageGenerator, ffmpeg as fallback).
    private func buildPreviewPanel() {
        buildUpNextColumn()

        previewLabel.font = .boldSystemFont(ofSize: 12)
        previewLabel.textColor = .labelColor
        previewLabel.lineBreakMode = .byTruncatingMiddle
        previewLabel.isSelectable = true
        previewLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(previewLabel)
        previewLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        for percent in previewPercentages {
            let (row, imageView) = makeThumbnailRow(percent: percent)
            previewImageViews[percent] = imageView
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        previewScrollView.hasVerticalScroller = true
        previewScrollView.hasHorizontalScroller = false
        previewScrollView.drawsBackground = false
        previewScrollView.translatesAutoresizingMaskIntoConstraints = false
        previewScrollView.documentView = stack

        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(previewScrollView)
        previewContainer.addSubview(upNextContainer)

        NSLayoutConstraint.activate([
            // PREVIEW — left column
            previewScrollView.topAnchor.constraint(
                equalTo: previewContainer.topAnchor,
                constant: 8
            ),

            previewScrollView.leadingAnchor.constraint(
                equalTo: previewContainer.leadingAnchor,
                constant: 8
            ),

            previewScrollView.bottomAnchor.constraint(
                equalTo: previewContainer.bottomAnchor,
                constant: -8
            ),

            // UP NEXT — right column
            upNextContainer.topAnchor.constraint(
                equalTo: previewContainer.topAnchor,
                constant: 8
            ),

            upNextContainer.leadingAnchor.constraint(
                equalTo: previewScrollView.trailingAnchor,
                constant: 10
            ),

            upNextContainer.trailingAnchor.constraint(
                equalTo: previewContainer.trailingAnchor,
                constant: -8
            ),

            upNextContainer.bottomAnchor.constraint(
                equalTo: previewContainer.bottomAnchor,
                constant: -8
            ),

            // Equal widths
            upNextContainer.widthAnchor.constraint(
                equalTo: previewScrollView.widthAnchor
            ),

            // Filmstrip follows preview scroll view width
            stack.topAnchor.constraint(
                equalTo: previewScrollView.contentView.topAnchor
            ),

            stack.leadingAnchor.constraint(
                equalTo: previewScrollView.contentView.leadingAnchor
            ),

            stack.widthAnchor.constraint(
                equalTo: previewScrollView.contentView.widthAnchor
            )
        ])
    }

    /// Builds the "Up Next" column: a fixed header label at the top, plus
    /// a scrollable pool of `upNextMaxSlots` (10) thumbnail image views.
    private func buildUpNextColumn() {
        upNextLabel.font = .boldSystemFont(ofSize: 12)
        upNextLabel.textColor = .labelColor
        upNextLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = upNextRowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        upNextAssignedItemIDs = Array(repeating: nil, count: upNextMaxSlots)
        for slot in 0..<upNextMaxSlots {
            let imageView = ClickableThumbnailView()
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
            imageView.layer?.cornerRadius = 4
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.isHidden = false
            imageView.onClick = { [weak self] in self?.selectUpNextSlot(slot) }
            if slot == 0 {
                // Slot 0 always shows the current selection (see
                // refreshUpNext) — a permanent border marks it as "current"
                // rather than "next", since otherwise it'd look identical
                // to the rest of the column.
                imageView.layer?.borderWidth = 2
                imageView.layer?.borderColor = NSColor.controlAccentColor.cgColor
            }
            upNextImageViews.append(imageView)
            stack.addArrangedSubview(imageView)
            imageView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: upNextRowAspect).isActive = true
        }

        upNextScrollView.hasVerticalScroller = true
        upNextScrollView.hasHorizontalScroller = false
        upNextScrollView.drawsBackground = false
        upNextScrollView.translatesAutoresizingMaskIntoConstraints = false
        upNextScrollView.documentView = stack

        upNextContainer.translatesAutoresizingMaskIntoConstraints = false
        upNextContainer.addSubview(upNextLabel)
        upNextContainer.addSubview(upNextScrollView)

        NSLayoutConstraint.activate([
            upNextLabel.topAnchor.constraint(equalTo: upNextContainer.topAnchor),
            upNextLabel.leadingAnchor.constraint(equalTo: upNextContainer.leadingAnchor),
            upNextLabel.trailingAnchor.constraint(equalTo: upNextContainer.trailingAnchor),

            upNextScrollView.topAnchor.constraint(equalTo: upNextLabel.bottomAnchor, constant: 6),
            upNextScrollView.leadingAnchor.constraint(equalTo: upNextContainer.leadingAnchor),
            upNextScrollView.trailingAnchor.constraint(equalTo: upNextContainer.trailingAnchor),
            upNextScrollView.bottomAnchor.constraint(equalTo: upNextContainer.bottomAnchor),

            stack.topAnchor.constraint(equalTo: upNextScrollView.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: upNextScrollView.contentView.leadingAnchor),
            stack.widthAnchor.constraint(equalTo: upNextScrollView.contentView.widthAnchor)
        ])
    }

    /// One filmstrip row: a 16:9 image view (grows with the pane's width)
    /// plus a small "NN%" caption underneath.
    private func makeThumbnailRow(percent: Int) -> (NSView, ClickableThumbnailView) {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let imageView = ClickableThumbnailView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        imageView.layer?.cornerRadius = 4
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.onClick = { [weak self] in self?.playSelected(startPercent: percent) }

        let caption = NSTextField(labelWithString: "\(percent)%")
        caption.font = .systemFont(ofSize: 10)
        caption.textColor = .secondaryLabelColor
        caption.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(imageView)
        container.addSubview(caption)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: 9.0 / 16.0),

            caption.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 2),
            caption.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            caption.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return (container, imageView)
    }

    // MARK: - Data

    private func populateConditionComboBox() {
        conditionField.removeAllItems()
        var allConditions = defaultConditions
        for custom in savedCustomConditions {
            if !allConditions.contains(custom) {
                allConditions.append(custom)
            }
        }
        conditionField.addItems(withObjectValues: allConditions)
        conditionField.stringValue = conditionExpression
    }

    private func checkAndSaveCustomCondition() {
        guard lastQuerySucceeded, !hasAddedCurrentConditionToHistory else { return }
        let trimmed = conditionExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var currentItems: [String] = defaultConditions
        currentItems.append(contentsOf: savedCustomConditions)
        if !currentItems.contains(trimmed) {
            var updated = savedCustomConditions
            updated.append(trimmed)
            savedCustomConditions = updated
            populateConditionComboBox()
            conditionField.stringValue = trimmed
        }
        hasAddedCurrentConditionToHistory = true
    }

    private func reload() {
        let result = db.loadItems(search: searchTerm, conditionExpression: conditionExpression)
        items = result.items
        lastQuerySucceeded = (result.errorMessage == nil)
        updateStatusLabel(itemCount: items.count, errorMessage: result.errorMessage)

        if tableView.sortDescriptors.isEmpty {
            tableView.reloadData()
        } else {
            applySort()
        }
        if selectedRow == nil, !items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        // Explicit, since the selected row's *index* may be unchanged even
        // though the underlying list (and so "what's after it") is new —
        // selectRowIndexes above won't reliably notify in that case.
        refreshUpNext()
    }

    /// Shows either the result count or, if the condition field's free-form
    /// SQL was malformed, the actual error — the Python version only ever
    /// printed this to the console, leaving a bad query looking identical
    /// to "no matches".
    private func updateStatusLabel(itemCount: Int, errorMessage: String?) {
        if let errorMessage {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "Query error: \(errorMessage)"
        } else {
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = itemCount == 1 ? "1 item" : "\(itemCount) items"
        }
    }

    /// Re-sorts `items` by the table's current sort descriptor (set when the
    /// user clicks a column header) and reloads, keeping the same row
    /// selected by id rather than by index.
    private func applySort() {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
        let ascending = descriptor.ascending
        let selectedID = selectedRow.flatMap { items.indices.contains($0) ? items[$0].id : nil }

        items.sort { ascending ? isLess($0, $1, key: key) : isLess($1, $0, key: key) }
        tableView.reloadData()

        if let id = selectedID, let newRow = items.firstIndex(where: { $0.id == id }) {
            tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(newRow)
        }
        refreshUpNext() // "what's after the selection" changed even if its row index didn't
    }

    /// True if `lhs` sorts before `rhs` for the given column key. Optional
    /// numeric/text fields treat `nil` as the lowest value (same as the
    /// Python version's `NumericTableWidgetItem.__lt__`, which put items
    /// with no data at the front of an ascending sort).
    private func isLess(_ lhs: MediaItem, _ rhs: MediaItem, key: String) -> Bool {
        switch key {
        case "id": return lhs.id < rhs.id
        case "filename": return lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
        case "views": return isLessOptional(lhs.viewCount, rhs.viewCount)
        case "likes": return isLessOptional(lhs.like, rhs.like)
        case "size": return lhs.fileSizeMB < rhs.fileSizeMB
        case "viewed": return isLessOptional(lhs.viewedTime, rhs.viewedTime)
        case "width": return isLessOptional(lhs.width, rhs.width)
        case "density": return isLessOptional(lhs.density, rhs.density)
        default: return false
        }
    }

    private func isLessOptional<T: Comparable>(_ a: T?, _ b: T?) -> Bool {
        switch (a, b) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case let (x?, y?): return x < y
        }
    }

    private var selectedRow: Int? {
        let row = tableView.selectedRow
        return row >= 0 ? row : nil
    }

    private func moveSelection(by amount: Int) {
        let current = selectedRow ?? -1
        let target = current + amount
        guard items.indices.contains(target) else { return }
        tableView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        tableView.scrollRowToVisible(target)
    }

    private func reloadRow(_ row: Int) {
        tableView.reloadData(forRowIndexes: IndexSet(integer: row),
                              columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }

    // MARK: - Up Next & Preview Sequential Thumbnail Generation

    private func selectUpNextSlot(_ slot: Int) {
        guard slot < upNextAssignedItemIDs.count, let itemID = upNextAssignedItemIDs[slot] else { return }
        guard let targetRow = items.firstIndex(where: { $0.id == itemID }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
        tableView.scrollRowToVisible(targetRow)
        view.window?.makeFirstResponder(tableView)
    }

    private func refreshUpNext() {
        refreshThumbnails()
    }

    /// Fully sequential generation for IO-bound/network-drive scenarios:
    /// First generates preview thumbnails for the selected video in order (15%, 30%, 45%, 60%, 75%, 90%),
    /// then sequentially generates "Up Next" preview thumbnails in order for upcoming items.
    private func refreshThumbnails() {
        thumbnailGenerationTask?.cancel()
        thumbnailGenerationTask = nil

        // Scroll both preview and Up Next scroll views back to the top on selection changes
        previewScrollView.contentView.scroll(to: .zero)
        previewScrollView.reflectScrolledClipView(previewScrollView.contentView)
        upNextScrollView.contentView.scroll(to: .zero)
        upNextScrollView.reflectScrolledClipView(upNextScrollView.contentView)

        let row = selectedRow
        let selectedItem = (row != nil && items.indices.contains(row!)) ? items[row!] : nil

        guard let selectedItem else {
            previewLabel.stringValue = ""
            for imageView in previewImageViews.values { imageView.image = nil }
            for imageView in upNextImageViews { imageView.image = nil }
            upNextAssignedItemIDs = Array(repeating: nil, count: upNextMaxSlots)
            return
        }

        previewLabel.stringValue = selectedItem.filename

        // Apply instant cached images to Preview and Up Next
        var filmstripPercentsToLoad: [Int] = []
        for percent in previewPercentages {
            if let cached = getOrLoadThumbnail(id: selectedItem.id, percent: percent) {
                previewImageViews[percent]?.image = cached
            } else {
                previewImageViews[percent]?.image = nil
                filmstripPercentsToLoad.append(percent)
            }
        }

        let selectedIndex = row!
        let visibleUpNextRows = Array(Array(selectedIndex..<items.count).prefix(upNextMaxSlots))

        for slot in 0..<upNextMaxSlots {
            if slot < visibleUpNextRows.count {
                let itemIndex = visibleUpNextRows[slot]
                let item = items[itemIndex]
                upNextAssignedItemIDs[slot] = item.id
                upNextImageViews[slot].toolTip = item.filename
                upNextImageViews[slot].isHidden = false
                if let cached = getOrLoadThumbnail(id: item.id, percent: upNextPercent) {
                    upNextImageViews[slot].image = cached
                } else {
                    upNextImageViews[slot].image = nil
                }
            } else {
                upNextImageViews[slot].image = nil
                upNextImageViews[slot].toolTip = nil
                upNextImageViews[slot].isHidden = true
                upNextAssignedItemIDs[slot] = nil
            }
        }

        thumbnailGenerationTask = Task { [weak self] in
            guard let self else { return }
            var pendingDiskSaves: [(image: NSImage, id: Int, percent: Int)] = []

            // 1. Generate preview thumbnails for the SELECTED video sequentially in order
            if !filmstripPercentsToLoad.isEmpty {
                let fullPath = selectedItem.fullPath(root: self.rootDir)
                if !FileManager.default.fileExists(atPath: fullPath) {
                    await MainActor.run {
                        self.markMissingFile(id: selectedItem.id)
                    }
                } else {
                    let url = URL(fileURLWithPath: fullPath)
                    let asset = AVURLAsset(url: url)
                    if let durationSeconds = await self.loadDuration(asset: asset, url: url), !Task.isCancelled {
                        let generator = AVAssetImageGenerator(asset: asset)
                        generator.appliesPreferredTrackTransform = true
                        generator.requestedTimeToleranceBefore = .zero
                        generator.requestedTimeToleranceAfter = .zero

                        for percent in filmstripPercentsToLoad {
                            if Task.isCancelled { return }
                            let key = self.cacheKey(id: selectedItem.id, percent: percent)
                            if self.thumbnailCache.object(forKey: key) != nil { continue }
                            if let diskImage = self.loadDiskThumbnail(id: selectedItem.id, percent: percent) {
                                self.thumbnailCache.setObject(diskImage, forKey: key)
                                await MainActor.run {
                                    guard let currentRow = self.selectedRow,
                                          self.items.indices.contains(currentRow),
                                          self.items[currentRow].id == selectedItem.id else { return }
                                    self.previewImageViews[percent]?.image = diskImage
                                }
                                continue
                            }

                            let seconds = durationSeconds * Double(percent) / 100
                            if let image = await self.generateFrame(generator: generator, url: url, atSeconds: seconds) {
                                if Task.isCancelled { return }
                                pendingDiskSaves.append((image: image, id: selectedItem.id, percent: percent))
                                self.thumbnailCache.setObject(image, forKey: key)
                                await MainActor.run {
                                    guard let currentRow = self.selectedRow,
                                          self.items.indices.contains(currentRow),
                                          self.items[currentRow].id == selectedItem.id else { return }
                                    self.previewImageViews[percent]?.image = image
                                }
                            }
                        }
                    }
                }
            }


            // 2. Generate UP NEXT thumbnails sequentially in order for up to 10 slots
            for slot in 0..<visibleUpNextRows.count {
                if Task.isCancelled { return }
                let itemIndex = visibleUpNextRows[slot]
                guard self.items.indices.contains(itemIndex) else { continue }
                let item = self.items[itemIndex]

                if let cached = self.getOrLoadThumbnail(id: item.id, percent: self.upNextPercent) {
                    await MainActor.run {
                        guard slot < self.upNextAssignedItemIDs.count,
                              self.upNextAssignedItemIDs[slot] == item.id else { return }
                        self.upNextImageViews[slot].image = cached
                    }
                    continue
                }

                let fullPath = item.fullPath(root: self.rootDir)
                if !FileManager.default.fileExists(atPath: fullPath) {
                    await MainActor.run {
                        self.markMissingFile(id: item.id)
                    }
                    continue
                }

                let url = URL(fileURLWithPath: fullPath)
                let asset = AVURLAsset(url: url)
                guard let durationSeconds = await self.loadDuration(asset: asset, url: url) else { continue }
                if Task.isCancelled { return }

                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero

                let seconds = durationSeconds * Double(self.upNextPercent) / 100
                if let image = await self.generateFrame(generator: generator, url: url, atSeconds: seconds) {
                    if Task.isCancelled { return }
                    pendingDiskSaves.append((image: image, id: item.id, percent: self.upNextPercent))
                    self.thumbnailCache.setObject(image, forKey: self.cacheKey(id: item.id, percent: self.upNextPercent))
                    await MainActor.run {
                        guard slot < self.upNextAssignedItemIDs.count,
                              self.upNextAssignedItemIDs[slot] == item.id else { return }
                        self.upNextImageViews[slot].image = image
                    }
                }
            }

            // 3. Pre-generate full set of filmstrip thumbnails in advance for the IMMEDIATELY NEXT video (AFTER Up Next completes)
            let nextIndex = selectedIndex + 1
            if self.items.indices.contains(nextIndex) {
                if Task.isCancelled { return }
                let nextItem = self.items[nextIndex]
                let fullPath = nextItem.fullPath(root: self.rootDir)
                if !FileManager.default.fileExists(atPath: fullPath) {
                    await MainActor.run {
                        self.markMissingFile(id: nextItem.id)
                    }
                } else {
                    let url = URL(fileURLWithPath: fullPath)
                    let asset = AVURLAsset(url: url)
                    if let durationSeconds = await self.loadDuration(asset: asset, url: url), !Task.isCancelled {
                        let generator = AVAssetImageGenerator(asset: asset)
                        generator.appliesPreferredTrackTransform = true
                        generator.requestedTimeToleranceBefore = .zero
                        generator.requestedTimeToleranceAfter = .zero

                        for percent in self.previewPercentages {
                            if Task.isCancelled { return }
                            let key = self.cacheKey(id: nextItem.id, percent: percent)
                            if self.thumbnailCache.object(forKey: key) != nil { continue }
                            if let diskImage = self.loadDiskThumbnail(id: nextItem.id, percent: percent) {
                                self.thumbnailCache.setObject(diskImage, forKey: key)
                                continue
                            }

                            let seconds = durationSeconds * Double(percent) / 100
                            if let image = await self.generateFrame(generator: generator, url: url, atSeconds: seconds) {
                                if Task.isCancelled { return }
                                pendingDiskSaves.append((image: image, id: nextItem.id, percent: percent))
                                self.thumbnailCache.setObject(image, forKey: key)
                            }
                        }
                    }
                }
            }

            // Save all generated thumbnails to disk AFTER generation finishes
            for save in pendingDiskSaves {
                if Task.isCancelled { return }
                self.saveDiskThumbnail(save.image, id: save.id, percent: save.percent)
            }
        }
    }

    private func cacheKey(id: Int, percent: Int) -> NSString {
        "\(id)-\(percent)" as NSString
    }

    /// AVFoundation first (fast, no subprocess); if it can't even parse the
    /// file — which is simply the case for every WMV, since macOS ships no
    /// Windows Media decoder — falls back to `ffprobe`.
    private func loadDuration(asset: AVURLAsset, url: URL) async -> Double? {
        if let duration = try? await asset.load(.duration),
           duration.isValid, duration.seconds.isFinite, duration.seconds > 0 {
            return duration.seconds
        }
        return await probeDurationViaFFmpeg(url: url)
    }

    /// One frame via AVFoundation; if that fails (unsupported codec inside
    /// an AVI, a WMV whose container AVFoundation couldn't open, etc.),
    /// falls back to invoking `ffmpeg` directly on the file.
    private func generateFrame(generator: AVAssetImageGenerator, url: URL, atSeconds seconds: Double) async -> NSImage? {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        if let (cgImage, _) = try? await generator.image(at: time) {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        return await extractFrameViaFFmpeg(url: url, atSeconds: seconds)
    }

    /// Reads a video's duration with `ffprobe` (part of the ffmpeg suite —
    /// already on most machines that have `mpv` installed via Homebrew,
    /// since its formula depends on ffmpeg). Returns nil if ffprobe isn't
    /// installed or the file is unreadable.
    private func probeDurationViaFFmpeg(url: URL) async -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffprobe", "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path,
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return nil }

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                guard finished.terminationStatus == 0,
                      let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let seconds = Double(text), seconds.isFinite, seconds > 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: seconds)
            }
        }
    }

    /// Grabs a single frame at `atSeconds` with `ffmpeg` into a temp PNG,
    /// loads it, and cleans the file up. Returns nil if ffmpeg isn't
    /// installed or the frame couldn't be extracted.
    private func extractFrameViaFFmpeg(url: URL, atSeconds seconds: Double) async -> NSImage? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoindex-preview-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg", "-nostdin", "-loglevel", "error",
            "-ss", String(seconds), "-i", url.path,
            "-frames:v", "1", "-q:v", "3", "-y", outputURL.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return nil }

        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }
        return NSImage(contentsOf: outputURL)
    }

    // MARK: - Actions & Responder Chain Menu Handlers

    @objc func openWordCloud(_ sender: Any?) {
        let wordFrequencies = db.fetchWordFrequencies()
        let nameFrequencies = db.fetchNameFrequencies()
        let controller = WordCloudWindowController(wordFrequencies: wordFrequencies, nameFrequencies: nameFrequencies)
        controller.onSelectWord = { [weak self] selectedWord in
            guard let self else { return }
            self.searchField.stringValue = selectedWord
            self.searchTerm = selectedWord
            self.reload()
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.wordCloudWindowController = controller
    }

    @objc func reloadQuery(_ sender: Any?) {
        tableView.sortDescriptors = []
        reload()
    }

    @objc func focusSearchField(_ sender: Any?) {
        view.window?.makeFirstResponder(searchField)
    }

    @objc func focusConditionField(_ sender: Any?) {
        view.window?.makeFirstResponder(conditionField)
    }

    @objc func playSelectedMedia(_ sender: Any?) {
        playSelected()
    }

    @objc func likeSelectedMedia(_ sender: Any?) {
        handleLikeIncrement()
    }

    @objc func deleteOrDislikeSelectedMedia(_ sender: Any?) {
        handleDeleteOrDislike()
    }

    @objc func selectFirstItem(_ sender: Any?) {
        handleHome()
    }

    @objc func selectLastItem(_ sender: Any?) {
        handleEnd()
    }

    // Options Menu Actions
    @objc func toggleSaveThumbnailsToDisk(_ sender: Any?) {
        saveThumbnailsToDisk.toggle()
    }

    // MPV Menu Toggle Actions
    @objc func toggleMpvVolumeMax1000(_ sender: Any?) { mpvVolumeMax1000.toggle() }
    @objc func toggleMpvMute(_ sender: Any?) { mpvMute.toggle() }
    @objc func toggleMpvLoop(_ sender: Any?) { mpvLoop.toggle() }
    @objc func toggleMpvNoAudio(_ sender: Any?) { mpvNoAudio.toggle() }
    @objc func toggleMpvKeepOpen(_ sender: Any?) { mpvKeepOpen.toggle() }
    @objc func toggleMpvOntop(_ sender: Any?) { mpvOntop.toggle() }
    @objc func toggleMpvHwdec(_ sender: Any?) { mpvHwdec.toggle() }

    @objc func setMpvAutofit50(_ sender: Any?) { mpvAutofitSize = "50%x50%" }
    @objc func setMpvAutofit75(_ sender: Any?) { mpvAutofitSize = "75%x75%" }
    @objc func setMpvAutofit100(_ sender: Any?) { mpvAutofitSize = "100%x100%" }
    @objc func setMpvAutofitFullscreen(_ sender: Any?) { mpvAutofitSize = "fullscreen" }

    @objc func setMpvVolume10(_ sender: Any?) { mpvVolume = "10" }
    @objc func setMpvVolume25(_ sender: Any?) { mpvVolume = "25" }
    @objc func setMpvVolume33(_ sender: Any?) { mpvVolume = "33" }
    @objc func setMpvVolume50(_ sender: Any?) { mpvVolume = "50" }
    @objc func setMpvVolume75(_ sender: Any?) { mpvVolume = "75" }
    @objc func setMpvVolume100(_ sender: Any?) { mpvVolume = "100" }

    @objc func setMpvSpeed1(_ sender: Any?) { mpvSpeed = "1.0" }
    @objc func setMpvSpeed125(_ sender: Any?) { mpvSpeed = "1.25" }
    @objc func setMpvSpeed15(_ sender: Any?) { mpvSpeed = "1.5" }
    @objc func setMpvSpeed20(_ sender: Any?) { mpvSpeed = "2.0" }

    private func isTableViewFocused() -> Bool {
        guard let firstResponder = view.window?.firstResponder as? NSView else { return false }
        return firstResponder.isDescendant(of: tableView) || firstResponder === tableView
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let action = menuItem.action

        // Table controls should only work when the list/table is focused
        if action == Selector(("playSelectedMedia:")) ||
            action == Selector(("likeSelectedMedia:")) ||
            action == Selector(("deleteOrDislikeSelectedMedia:")) ||
            action == Selector(("selectFirstItem:")) ||
            action == Selector(("selectLastItem:")) {
            return isTableViewFocused()
        }

        if action == Selector(("toggleSaveThumbnailsToDisk:")) {
            menuItem.state = saveThumbnailsToDisk ? .on : .off
        }

        // Validate checkmarks and state for MPV menu items
        if action == Selector(("toggleMpvVolumeMax1000:")) {
            menuItem.state = mpvVolumeMax1000 ? .on : .off
        } else if action == Selector(("toggleMpvMute:")) {
            menuItem.state = mpvMute ? .on : .off
        } else if action == Selector(("toggleMpvLoop:")) {
            menuItem.state = mpvLoop ? .on : .off
        } else if action == Selector(("toggleMpvNoAudio:")) {
            menuItem.state = mpvNoAudio ? .on : .off
        } else if action == Selector(("toggleMpvKeepOpen:")) {
            menuItem.state = mpvKeepOpen ? .on : .off
        } else if action == Selector(("toggleMpvOntop:")) {
            menuItem.state = mpvOntop ? .on : .off
        } else if action == Selector(("toggleMpvHwdec:")) {
            menuItem.state = mpvHwdec ? .on : .off
        } else if action == Selector(("setMpvAutofit50:")) {
            menuItem.state = mpvAutofitSize == "50%x50%" ? .on : .off
        } else if action == Selector(("setMpvAutofit75:")) {
            menuItem.state = mpvAutofitSize == "75%x75%" ? .on : .off
        } else if action == Selector(("setMpvAutofit100:")) {
            menuItem.state = mpvAutofitSize == "100%x100%" ? .on : .off
        } else if action == Selector(("setMpvAutofitFullscreen:")) {
            menuItem.state = mpvAutofitSize == "fullscreen" ? .on : .off
        } else if action == Selector(("setMpvVolume10:")) {
            menuItem.state = mpvVolume == "10" ? .on : .off
        } else if action == Selector(("setMpvVolume25:")) {
            menuItem.state = mpvVolume == "25" ? .on : .off
        } else if action == Selector(("setMpvVolume33:")) {
            menuItem.state = mpvVolume == "33" ? .on : .off
        } else if action == Selector(("setMpvVolume50:")) {
            menuItem.state = mpvVolume == "50" ? .on : .off
        } else if action == Selector(("setMpvVolume75:")) {
            menuItem.state = mpvVolume == "75" ? .on : .off
        } else if action == Selector(("setMpvVolume100:")) {
            menuItem.state = mpvVolume == "100" ? .on : .off
        } else if action == Selector(("setMpvSpeed1:")) {
            menuItem.state = mpvSpeed == "1.0" ? .on : .off
        } else if action == Selector(("setMpvSpeed125:")) {
            menuItem.state = mpvSpeed == "1.25" ? .on : .off
        } else if action == Selector(("setMpvSpeed15:")) {
            menuItem.state = mpvSpeed == "1.5" ? .on : .off
        } else if action == Selector(("setMpvSpeed20:")) {
            menuItem.state = mpvSpeed == "2.0" ? .on : .off
        }

        return true
    }

    private func playSelected(startPercent: Int? = nil) {
        guard let row = selectedRow, items.indices.contains(row) else { return }
        var item = items[row]
        let path = item.fullPath(root: rootDir)

        var args = ["mpv"]
        if let startPercent {
            args.append("--start=\(startPercent)%")
        }
        if mpvVolumeMax1000 {
            args.append("--volume-max=1000")
        }
        args.append("--volume=\(mpvVolume)")
        if mpvMute {
            args.append("--mute=yes")
        }
        if mpvLoop {
            args.append("--loop-file=inf")
        }
        if mpvNoAudio {
            args.append("--no-audio")
        }
        if mpvKeepOpen {
            args.append("--keep-open=yes")
        }
        if mpvOntop {
            args.append("--ontop")
        }
        if mpvHwdec {
            args.append("--hwdec=auto")
        }
        if mpvAutofitSize == "fullscreen" {
            args.append("--fullscreen")
        } else {
            args.append("--autofit=\(mpvAutofitSize)")
        }
        if mpvSpeed != "1.0" {
            args.append("--speed=\(mpvSpeed)")
        }
        args.append(path)

        // Fire-and-forget, like the trailing "&" in `os.system('mpv ... &')`.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        try? process.run()

        // The database's `viewed_time = datetime('now')` (in Database.updateViewCount)
        // already updates on every play; this line keeps the in-memory row —
        // and so the visible "Last Viewed" column — in sync with it immediately,
        // rather than only on the next full reload.
        sessionPlayedIDs.insert(item.id)
        let newCount = (item.viewCount ?? 0) + 1
        item.viewCount = newCount
        item.viewedTime = Self.sqliteNowString()
        items[row] = item
        db.updateViewCount(id: item.id, viewCount: newCount)
        reloadRow(row)
        if let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? CustomTableRowView {
            rowView.isViewed = true
            rowView.isSessionPlayed = true
        }
    }

    /// Matches SQLite's `datetime('now')`: UTC, "yyyy-MM-dd HH:mm:ss". Used
    /// so the in-memory row's `viewedTime` sorts/displays consistently with
    /// what's actually written to the database.
    private static func sqliteNowString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    @discardableResult
    private func adjustLike(by amount: Int) -> Int? {
        guard let row = selectedRow, items.indices.contains(row) else { return nil }
        var item = items[row]
        let resolvedLike: Int
        if let current = item.like {
            resolvedLike = current + amount
        } else {
            resolvedLike = amount
        }
        item.like = resolvedLike
        items[row] = item
        db.updateLike(id: item.id, like: resolvedLike)
        reloadRow(row)
        return resolvedLike
    }

    /// Mirrors the Python `delete()`: refuses when the (just-adjusted) like
    /// value is still >= -1, so pressing the delete shortcut once only
    /// registers a dislike, and a second press actually removes the file.
    private func deleteSelectedIfAllowed() -> Bool {
        guard let row = selectedRow, items.indices.contains(row) else { return false }
        let item = items[row]
        if let like = item.like, like >= -1 {
            print("can't delete liked")
            return false
        }
        let path = item.fullPath(root: rootDir)
        try? FileManager.default.removeItem(atPath: path)
        db.deleteMedia(id: item.id)
        items.remove(at: row)
        tableView.removeRows(at: IndexSet(integer: row), withAnimation: [])
        if !items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: min(row, items.count - 1)), byExtendingSelection: false)
        }
        refreshUpNext() // the file after the (possibly same-index) selection just shifted
        return true
    }
}

// MARK: - NSSplitViewDelegate

extension PlayerViewController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        600 // keep the table usably wide
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView.bounds.width - 380 // room for the Up Next column plus a usable filmstrip column
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension PlayerViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    /// Fired by AppKit whenever the user clicks a column header (it toggles
    /// that column's descriptor between ascending/descending and puts it
    /// first in `tableView.sortDescriptors`).
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        applySort()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        checkAndSaveCustomCondition()
        refreshThumbnails()
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowViewId = NSUserInterfaceItemIdentifier("videoRowView")
        let rowView = (tableView.makeView(withIdentifier: rowViewId, owner: self) as? CustomTableRowView) ?? CustomTableRowView()
        rowView.identifier = rowViewId

        if items.indices.contains(row) {
            let item = items[row]
            let isViewed = (item.viewCount ?? 0) > 0 || (item.viewedTime != nil && !item.viewedTime!.isEmpty)
            rowView.isViewed = isViewed
            rowView.isSessionPlayed = sessionPlayedIDs.contains(item.id)
        } else {
            rowView.isViewed = false
            rowView.isSessionPlayed = false
        }
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, items.indices.contains(row) else { return nil }
        let item = items[row]

        let text: String
        switch identifier.rawValue {
        case "id": text = String(item.id)
        case "filename": text = item.filename
        case "views": text = item.viewCount.map(String.init) ?? ""
        case "likes": text = item.like.map(String.init) ?? ""
        case "size": text = String(item.fileSizeMB)
        case "viewed": text = item.viewedTime ?? ""
        case "width": text = item.width.map(String.init) ?? ""
        case "density": text = item.density.map(String.init) ?? ""
        default: text = ""
        }

        let cellId = NSUserInterfaceItemIdentifier("cell-\(identifier.rawValue)")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellId
            let textField = NSTextField(labelWithString: "")
            textField.isSelectable = true
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = text
        let isMissing = missingFileIDs.contains(item.id)
        if isMissing {
            cell.textField?.textColor = .systemRed
        } else if identifier.rawValue == "likes" {
            switch item.like {
            case .some(let like) where like < 0:
                cell.textField?.textColor = .systemRed
            case .some(1):
                cell.textField?.textColor = .systemOrange
            case .some(2):
                cell.textField?.textColor = .systemYellow
            case .some(3):
                cell.textField?.textColor = .systemGreen
            case .some(4):
                cell.textField?.textColor = .systemTeal
            case .some(let like) where like >= 5:
                cell.textField?.textColor = .systemPurple
            default:
                cell.textField?.textColor = .labelColor
            }
        } else {
            cell.textField?.textColor = .labelColor
        }
        return cell
    }
}

// MARK: - NSTextFieldDelegate (search & condition boxes)

extension PlayerViewController: NSTextFieldDelegate {
    func controlTextDidBeginEditing(_ obj: Notification) {
        if let fieldEditor = obj.userInfo?["NSFieldEditor"] as? NSTextView {
            fieldEditor.allowsUndo = true
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        textView.allowsUndo = true
        return false
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let comboBox = notification.object as? NSComboBox, comboBox === conditionField else { return }
        let selectedIndex = comboBox.indexOfSelectedItem
        guard selectedIndex >= 0, selectedIndex < comboBox.numberOfItems else { return }
        if let selectedValue = comboBox.itemObjectValue(at: selectedIndex) as? String {
            conditionExpression = selectedValue
            conditionField.stringValue = selectedValue
            hasAddedCurrentConditionToHistory = true
            reload()
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSControl else { return }
        if field === searchField {
            searchTerm = searchField.stringValue
            reload()
        } else if field === conditionField {
            conditionExpression = conditionField.stringValue
            hasAddedCurrentConditionToHistory = false
            reload() // a bad fragment now shows its error in statusLabel instead of just an empty table
        }
    }
}

// MARK: - ShortcutTableViewDelegateActions

extension PlayerViewController: ShortcutTableViewDelegateActions {
    func handlePlay() {
        playSelected()
    }

    func handleLikeIncrement() {
        adjustLike(by: 1)
        moveSelection(by: 1)
    }

    func handleDeleteOrDislike() {
        adjustLike(by: -1)
        if !deleteSelectedIfAllowed() {
            moveSelection(by: 1)
        }
    }

    func handleHome() {
        guard !items.isEmpty else { return }
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.scrollRowToVisible(0)
    }

    func handleEnd() {
        guard !items.isEmpty else { return }
        let last = items.count - 1
        tableView.selectRowIndexes(IndexSet(integer: last), byExtendingSelection: false)
        tableView.scrollRowToVisible(last)
    }

    func handleEscape() {
        db.commit()
        NSApplication.shared.terminate(nil)
    }
}
