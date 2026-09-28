import Cocoa
import AVFoundation

final class PlayerViewController: NSViewController, NSMenuItemValidation {

    private let rootDir: String
    private let db: Database

    private var items: [MediaItem] = []
    private var searchTerm: String = ""
    private var conditionExpression: String

    private let tableView = ShortcutTableView()
    private let scrollView = NSScrollView()
    private let searchField = NSTextField()
    private let conditionField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")

    private let splitViewAutosaveName = "VideoIndexMainSplit"
    private let splitView = NSSplitView()
    private let previewContainer = NSView()
    private let previewLabel = NSTextField(labelWithString: "")
    /// Points along the video's duration to grab a frame from. The preview
    /// panel is a vertical, scrollable filmstrip of these — widen the split
    /// pane and each thumbnail grows with it (they're pinned to 16:9).
    private let previewPercentages = [15, 30, 45, 60, 75, 90]
    private var previewImageViews: [Int: NSImageView] = [:]
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private var didSetInitialSplitPosition = false

    private var previewTask: Task<Void, Never>?
    private var upNextTask: Task<Void, Never>?

    // MPV options state
    private var mpvVolumeMax1000 = true
    private var mpvMute = false
    private var mpvLoop = false
    private var mpvNoAudio = false
    private var mpvKeepOpen = false
    private var mpvOntop = false
    private var mpvHwdec = false
    private var mpvAutofitSize = "75%x75%" // options: "50%x50%", "75%x75%", "100%x100%", "fullscreen"
    private var mpvSpeed = "1.0"           // options: "1.0", "1.25", "1.5", "2.0"

    // "Up Next" strip: one thumbnail per upcoming file (after the current
    // selection), to the left of the percentage filmstrip. Non-scrolling —
    // it only ever shows as many rows as fit the pane's current height.
    private let upNextContainer = NSView()
    private let upNextLabel = NSTextField(labelWithString: "Up Next")
    private let upNextRowAspect: CGFloat = 9.0 / 16.0
    private let upNextRowSpacing: CGFloat = 8
    private let upNextMaxSlots = 24 // generous cap; real count is fit-to-height
    private let upNextPercent = 45  // shares a cache bucket with the 45% filmstrip row
    private var upNextImageViews: [ClickableThumbnailView] = []
    private var upNextAssignedItemIDs: [Int?] = []
    private var currentUpNextSlotCount = -1 // -1 = not computed yet

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
        // Mirrors the Python default: dislikes/likes-only shuffled queue,
        // most-recently-viewed last.
        self.conditionExpression = "AND like > 2 ORDER BY viewed_time, random()"
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

        // The window (or the divider) may have changed height/width since
        // the last pass, which can change how many "Up Next" rows fit.
        updateUpNextSlotCount()
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

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search filename…"
        searchField.delegate = self
        searchField.allowsEditingTextAttributes = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        conditionField.placeholderString = "SQL condition / ORDER BY…"
        conditionField.delegate = self
        conditionField.allowsEditingTextAttributes = true
        conditionField.translatesAutoresizingMaskIntoConstraints = false

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
        view.addSubview(splitView)
        view.addSubview(conditionField)
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),

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

    /// Right-hand panel: an "Up Next" column (one frame per upcoming file,
    /// non-scrolling — see updateUpNextSlotCount) to the left of a
    /// scrollable filmstrip of frames from the *selected* file, both grabbed
    /// with AVFoundation (AVAssetImageGenerator, ffmpeg as fallback).
    private func buildPreviewPanel() {
        buildUpNextColumn()

        previewLabel.font = .boldSystemFont(ofSize: 12)
        previewLabel.textColor = .labelColor
        previewLabel.lineBreakMode = .byTruncatingMiddle
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

        let previewScrollView = NSScrollView()
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

    /// Builds the fixed-width "Up Next" column: a heading plus a pool of
    /// `upNextMaxSlots` image views, all hidden until
    /// `updateUpNextSlotCount()` reveals however many actually fit.
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
            imageView.isHidden = true
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

        upNextContainer.translatesAutoresizingMaskIntoConstraints = false
        upNextContainer.addSubview(upNextLabel)
        upNextContainer.addSubview(stack)

        NSLayoutConstraint.activate([
            upNextLabel.topAnchor.constraint(equalTo: upNextContainer.topAnchor),
            upNextLabel.leadingAnchor.constraint(equalTo: upNextContainer.leadingAnchor),
            upNextLabel.trailingAnchor.constraint(equalTo: upNextContainer.trailingAnchor),

            // No bottom pin on the stack: hidden slots take no space, so it's
            // simply as tall as whatever's currently visible — shorter than
            // upNextContainer itself, which is fine, since upNextContainer's
            // own height comes from its own top/bottom pins, not this stack.
            stack.topAnchor.constraint(equalTo: upNextLabel.bottomAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: upNextContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: upNextContainer.trailingAnchor),
        ])
    }

    /// One filmstrip row: a 16:9 image view (grows with the pane's width)
    /// plus a small "NN%" caption underneath.
    private func makeThumbnailRow(percent: Int) -> (NSView, NSImageView) {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        imageView.layer?.cornerRadius = 4
        imageView.translatesAutoresizingMaskIntoConstraints = false

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

    private func reload() {
        let result = db.loadItems(search: searchTerm, conditionExpression: conditionExpression)
        items = result.items
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

    // MARK: - Up Next column

    /// Recomputes how many "Up Next" rows fit the column's current height
    /// and reveals exactly that many — no scrolling, so growing the window
    /// (or the divider, which doesn't change height, but a window resize
    /// does) can add rows and shrinking it removes them.
    private func updateUpNextSlotCount() {
        let availableHeight = upNextContainer.bounds.height - upNextLabel.fittingSize.height - 6
        guard availableHeight > 0 else {
            setUpNextSlotCount(0)
            return
        }
        // upNextContainer's own width now tracks the filmstrip's width (they
        // split the pane equally), so measure it live rather than assuming
        // a fixed value — it changes as the divider or window is resized.
        let rowHeight = upNextContainer.bounds.width * upNextRowAspect
        let slots = (availableHeight + upNextRowSpacing) / (rowHeight + upNextRowSpacing)
        setUpNextSlotCount(max(0, min(upNextMaxSlots, Int(slots.rounded(.down)))))
    }

    private func setUpNextSlotCount(_ count: Int) {
        guard count != currentUpNextSlotCount else { return }
        currentUpNextSlotCount = count
        for (index, imageView) in upNextImageViews.enumerated() {
            imageView.isHidden = index >= count
        }
        refreshUpNext()
    }

    /// Fills the currently-visible "Up Next" slots with the files that come
    /// right after the current selection, in list order. Cached frames (a
    /// file may already have been generated earlier, either as an Up Next
    /// row or as the 45% filmstrip row when it was itself selected — both
    /// share the same cache bucket) apply instantly; the rest generate
    /// in the background.
    ///
    /// Slot 0 is always the *current* selection (it gets a permanent accent
    /// border in buildUpNextColumn to mark it as such — and since it shares
    /// its cache key with the filmstrip's own 45% row, it's usually just
    /// showing the same image already visible there); slots 1+ are the
    /// files that come after it in the list.
    private func refreshUpNext() {
        upNextTask?.cancel()
        upNextTask = nil

        guard currentUpNextSlotCount > 0 else { return }
        guard let selected = selectedRow, items.indices.contains(selected) else {
            for imageView in upNextImageViews { imageView.image = nil }
            upNextAssignedItemIDs = Array(repeating: nil, count: upNextMaxSlots)
            return
        }

        let visibleRows = Array(selected..<items.count).prefix(currentUpNextSlotCount)

        upNextTask = Task { [weak self] in
            guard let self else { return }
            for slot in 0..<self.currentUpNextSlotCount {
                if Task.isCancelled { break }
                guard slot < visibleRows.count else {
                    await MainActor.run {
                        self.upNextImageViews[slot].image = nil
                        self.upNextImageViews[slot].toolTip = nil
                        self.upNextAssignedItemIDs[slot] = nil
                    }
                    continue
                }
                let itemRowIndex = visibleRows[visibleRows.index(visibleRows.startIndex, offsetBy: slot)]
                guard self.items.indices.contains(itemRowIndex) else { continue }
                let item = self.items[itemRowIndex]

                await MainActor.run {
                    self.upNextImageViews[slot].toolTip = item.filename
                }
                await self.loadUpNextThumbnail(item: item, slot: slot)
            }
        }
    }

    /// Clicking an "Up Next" thumbnail jumps the table's selection straight
    /// to that file — looked up by id (not the slot's list position) since
    /// the list could in principle have changed between generating the
    /// thumbnail and the click landing.
    private func selectUpNextSlot(_ slot: Int) {
        guard slot < upNextAssignedItemIDs.count, let itemID = upNextAssignedItemIDs[slot] else { return }
        guard let targetRow = items.firstIndex(where: { $0.id == itemID }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
        tableView.scrollRowToVisible(targetRow)
        view.window?.makeFirstResponder(tableView) // keep keyboard shortcuts working right after the click
    }

    private func loadUpNextThumbnail(item: MediaItem, slot: Int) async {
        upNextAssignedItemIDs[slot] = item.id
        let key = cacheKey(id: item.id, percent: upNextPercent)
        if let cached = thumbnailCache.object(forKey: key) {
            upNextImageViews[slot].image = cached
            return
        }

        upNextImageViews[slot].image = nil
        let requestedID = item.id
        let url = URL(fileURLWithPath: item.fullPath(root: rootDir))

        let asset = AVURLAsset(url: url)
        guard let durationSeconds = await self.loadDuration(asset: asset, url: url) else { return }
        if Task.isCancelled { return }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let seconds = durationSeconds * Double(self.upNextPercent) / 100
        guard let image = await self.generateFrame(generator: generator, url: url, atSeconds: seconds) else { return }
        if Task.isCancelled { return }

        self.thumbnailCache.setObject(image, forKey: key)

        await MainActor.run {
            // The slot may have been reassigned to a different file (list
            // re-sorted, selection moved, window shrank) while this ran.
            guard slot < self.upNextAssignedItemIDs.count,
                  self.upNextAssignedItemIDs[slot] == requestedID else { return }
            self.upNextImageViews[slot].image = image
        }
    }

    // MARK: - Preview (filmstrip via AVFoundation, with an ffmpeg fallback)

    /// Refreshes every row of the filmstrip for the newly selected item.
    /// Already-cached frames apply instantly; anything missing is generated
    /// (in parallel) and filled in as it completes.
    private func updatePreview(for item: MediaItem?) {
        previewTask?.cancel()
        previewTask = nil

        guard let item else {
            previewLabel.stringValue = ""
            for imageView in previewImageViews.values { imageView.image = nil }
            return
        }

        previewLabel.stringValue = item.filename
        let requestedID = item.id
        let url = URL(fileURLWithPath: item.fullPath(root: rootDir))

        var percentsNeeded: [Int] = []
        for percent in previewPercentages {
            guard let imageView = previewImageViews[percent] else { continue }
            if let cached = thumbnailCache.object(forKey: cacheKey(id: requestedID, percent: percent)) {
                imageView.image = cached
            } else {
                imageView.image = nil
                percentsNeeded.append(percent)
            }
        }
        guard !percentsNeeded.isEmpty else { return }

        previewTask = Task { [weak self] in
            guard let self else { return }
            let asset = AVURLAsset(url: url)
            guard let durationSeconds = await self.loadDuration(asset: asset, url: url) else {
                print("Preview generation failed for \(url.path): couldn't determine duration " +
                      "(AVFoundation can't parse this format, and ffprobe either isn't installed or failed too)")
                return
            }
            if Task.isCancelled { return }

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero

            await withTaskGroup(of: (Int, NSImage?).self) { group in
                for percent in percentsNeeded {
                    group.addTask {
                        if Task.isCancelled { return (percent, nil) }
                        let seconds = durationSeconds * Double(percent) / 100
                        let image = await self.generateFrame(generator: generator, url: url, atSeconds: seconds)
                        return (percent, image)
                    }
                }
                for await (percent, image) in group {
                    if Task.isCancelled { break }
                    guard let image else { continue }
                    self.thumbnailCache.setObject(image, forKey: self.cacheKey(id: requestedID, percent: percent))
                    await MainActor.run {
                        // Skip if the selection moved on while we were generating.
                        guard let row = self.selectedRow, self.items.indices.contains(row),
                              self.items[row].id == requestedID,
                              let imageView = self.previewImageViews[percent] else { return }
                        imageView.image = image
                    }
                }
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

    @objc func reloadQuery(_ sender: Any?) {
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

    private func playSelected() {
        guard let row = selectedRow, items.indices.contains(row) else { return }
        var item = items[row]
        let path = item.fullPath(root: rootDir)

        var args = ["mpv"]
        if mpvVolumeMax1000 {
            args.append("--volume-max=1000")
        }
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
        let newCount = (item.viewCount ?? 0) + 1
        item.viewCount = newCount
        item.viewedTime = Self.sqliteNowString()
        items[row] = item
        db.updateViewCount(id: item.id, viewCount: newCount)
        reloadRow(row)
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
        let row = tableView.selectedRow
        updatePreview(for: (row >= 0 && items.indices.contains(row)) ? items[row] : nil)
        refreshUpNext()
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
        // Visual cue for likes/dislikes with adequate contrast on light/dark modes:
        // 1 like: passable (orange)
        // 2 likes: fine (yellow)
        // 3 likes: good (green)
        // 4 likes: excellent (teal)
        // 5+ likes: best (purple)
        // dislikes (< 0): red
        if identifier.rawValue == "likes" {
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

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === searchField {
            searchTerm = field.stringValue
            reload()
        } else if field === conditionField {
            conditionExpression = field.stringValue
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
