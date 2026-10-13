import Cocoa

/// Window controller for the Library Analytics Dashboard.
final class DashboardWindowController: NSWindowController, NSWindowDelegate {

    private let db: Database
    private let activeSearch: String
    private let activeCondition: String

    private var allRecords: [Database.DashboardRecord] = []
    private var filteredRecords: [Database.DashboardRecord] = []

    private var activeRecords: [Database.DashboardRecord] {
        scopeControl.selectedSegment == 1 ? filteredRecords : allRecords
    }

    // UI Controls
    private let scopeControl = NSSegmentedControl(labels: ["All Media", "Current Filter"], trackingMode: .selectOne, target: nil, action: nil)
    private let treemapMetricControl = NSSegmentedControl(labels: ["By Likes", "By Resolutions", "By Durations", "By Views"], trackingMode: .selectOne, target: nil, action: nil)

    private let overviewCardsStack = NSStackView()
    private let treemapTitleLabel = NSTextField(labelWithString: "Squarified Treemap Visualization")
    private let treemapView = SquarifiedTreemapView()

    private let scrollView = NSScrollView()
    private let contentView = NSView()

    // Breakdown Tables
    private let likesTableView = NSTableView()
    private let resolutionsTableView = NSTableView()
    private let durationsTableView = NSTableView()
    private let viewsTableView = NSTableView()

    private var likesStats: [GroupStat] = []
    private var resolutionsStats: [GroupStat] = []
    private var durationsStats: [GroupStat] = []
    private var viewsStats: [GroupStat] = []

    struct GroupStat {
        let key: String
        let title: String
        let count: Int
        let totalSizeBytes: Int64
        let totalDurationSec: Double
        let color: NSColor
    }

    init(db: Database, search: String, condition: String) {
        self.db = db
        self.activeSearch = search
        self.activeCondition = condition

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let windowWidth = min(1100, screenFrame.width * 0.90)
        let windowHeight = min(850, screenFrame.height * 0.90)
        let windowRect = NSRect(
            x: screenFrame.minX + (screenFrame.width - windowWidth) / 2,
            y: screenFrame.minY + (screenFrame.height - windowHeight) / 2,
            width: windowWidth,
            height: windowHeight
        )

        let window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Library Analytics Dashboard"
        window.minSize = NSSize(width: 800, height: 600)

        super.init(window: window)
        window.delegate = self

        loadData()
        setupUI()
        updateDashboard()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func loadData() {
        allRecords = db.fetchDashboardRecords(filterByCondition: false)
        filteredRecords = db.fetchDashboardRecords(search: activeSearch, conditionExpression: activeCondition, filterByCondition: true)
    }

    private func setupUI() {
        guard let windowContentView = window?.contentView else { return }

        // Scope control
        scopeControl.selectedSegment = 0
        scopeControl.setLabel("All Media (\(allRecords.count))", forSegment: 0)
        scopeControl.setLabel("Current Filter (\(filteredRecords.count))", forSegment: 1)
        scopeControl.target = self
        scopeControl.action = #selector(scopeChanged(_:))
        scopeControl.translatesAutoresizingMaskIntoConstraints = false

        // Treemap metric selector
        treemapMetricControl.selectedSegment = 0
        treemapMetricControl.target = self
        treemapMetricControl.action = #selector(treemapMetricChanged(_:))
        treemapMetricControl.translatesAutoresizingMaskIntoConstraints = false

        // Top Header bar stack
        let headerStack = NSStackView(views: [
            NSTextField(labelWithString: "Filter Scope:"),
            scopeControl,
            NSView(), // Spacer
            NSTextField(labelWithString: "Treemap Metric:"),
            treemapMetricControl
        ])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 10
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        // Overview Stat Cards
        overviewCardsStack.orientation = .horizontal
        overviewCardsStack.distribution = .fillEqually
        overviewCardsStack.spacing = 12
        overviewCardsStack.translatesAutoresizingMaskIntoConstraints = false

        // Treemap Section
        treemapTitleLabel.font = .systemFont(ofSize: 14, weight: .bold)
        treemapTitleLabel.textColor = .labelColor
        treemapTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        treemapView.translatesAutoresizingMaskIntoConstraints = false
        treemapView.wantsLayer = true
        treemapView.layer?.cornerRadius = 6
        treemapView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        // Breakdown Tables Setup
        setupTable(likesTableView, columns: [("tier", "Like Tier", 120), ("count", "Videos", 80), ("size", "Total Storage", 110), ("avg_size", "Avg Size", 90), ("pct", "% Storage", 90)])
        setupTable(resolutionsTableView, columns: [("res", "Resolution Class", 140), ("count", "Videos", 80), ("size", "Total Storage", 110), ("pct", "% Videos", 90)])
        setupTable(durationsTableView, columns: [("dur", "Duration Range", 140), ("count", "Videos", 80), ("total_dur", "Total Duration", 120), ("size", "Total Storage", 110), ("pct", "% Videos", 90)])
        setupTable(viewsTableView, columns: [("views", "View Tier", 140), ("count", "Videos", 80), ("size", "Total Storage", 110), ("pct", "% Videos", 90)])

        let likesBox = makeSectionBox(title: "File Sizes & Storage by Likes", view: likesTableView, height: 180)
        let resBox = makeSectionBox(title: "Resolutions Breakdown", view: resolutionsTableView, height: 150)
        let durBox = makeSectionBox(title: "Durations Breakdown", view: durationsTableView, height: 170)
        let viewsBox = makeSectionBox(title: "View Counts Breakdown", view: viewsTableView, height: 140)

        // Content layout container
        let stackView = NSStackView(views: [
            headerStack,
            overviewCardsStack,
            treemapTitleLabel,
            treemapView,
            likesBox,
            resBox,
            durBox,
            viewsBox
        ])
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 16
        stackView.translatesAutoresizingMaskIntoConstraints = false

        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stackView)

        scrollView.documentView = contentView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        windowContentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: windowContentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: windowContentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: windowContentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: windowContentView.bottomAnchor),

            contentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),

            headerStack.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            overviewCardsStack.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            overviewCardsStack.heightAnchor.constraint(equalToConstant: 75),

            treemapView.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            treemapView.heightAnchor.constraint(equalToConstant: 260),

            likesBox.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            resBox.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            durBox.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            viewsBox.widthAnchor.constraint(equalTo: stackView.widthAnchor),
        ])
    }

    private func setupTable(_ tableView: NSTableView, columns: [(id: String, title: String, width: CGFloat)]) {
        for col in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.id))
            column.title = col.title
            column.width = col.width
            tableView.addTableColumn(column)
        }
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
    }

    private func makeSectionBox(title: String, view: NSView, height: CGFloat) -> NSBox {
        let box = NSBox()
        box.title = title
        box.titleFont = .systemFont(ofSize: 13, weight: .bold)
        box.boxType = .primary
        box.borderType = .lineBorder
        box.cornerRadius = 6
        box.translatesAutoresizingMaskIntoConstraints = false

        let tableScrollView = NSScrollView()
        tableScrollView.documentView = view
        tableScrollView.hasVerticalScroller = true
        tableScrollView.drawsBackground = false
        tableScrollView.translatesAutoresizingMaskIntoConstraints = false

        box.contentView?.addSubview(tableScrollView)
        if let cv = box.contentView {
            NSLayoutConstraint.activate([
                tableScrollView.topAnchor.constraint(equalTo: cv.topAnchor, constant: 4),
                tableScrollView.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 4),
                tableScrollView.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -4),
                tableScrollView.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -4),
                tableScrollView.heightAnchor.constraint(equalToConstant: height)
            ])
        }
        return box
    }

    private func makeStatCard(title: String, value: String, subtitle: String, color: NSColor) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = color.withAlphaComponent(0.12).cgColor
        card.layer?.borderColor = color.withAlphaComponent(0.3).cgColor
        card.layer?.borderWidth = 1
        card.layer?.cornerRadius = 6
        card.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title.uppercased())
        titleLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .systemFont(ofSize: 18, weight: .bold)
        valueLabel.textColor = .labelColor

        let subLabel = NSTextField(labelWithString: subtitle)
        subLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [titleLabel, valueLabel, subLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
        ])
        return card
    }

    // MARK: - Update Logic

    @objc private func scopeChanged(_ sender: NSSegmentedControl) {
        updateDashboard()
    }

    @objc private func treemapMetricChanged(_ sender: NSSegmentedControl) {
        updateTreemap()
    }

    private func updateDashboard() {
        let records = activeRecords

        // 1. Calculate overview stats
        let totalCount = records.count
        let totalBytes = records.reduce(Int64(0)) { $0 + $1.fileSize }
        let totalDuration = records.reduce(0.0) { $0 + ($1.duration ?? 0) }

        let avgBytes = totalCount > 0 ? totalBytes / Int64(totalCount) : 0
        let avgDuration = totalCount > 0 ? totalDuration / Double(totalCount) : 0

        overviewCardsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        overviewCardsStack.addArrangedSubview(makeStatCard(title: "Total Videos", value: "\(totalCount)", subtitle: "Items in library", color: .systemBlue))
        overviewCardsStack.addArrangedSubview(makeStatCard(title: "Total Storage", value: formatBytes(totalBytes), subtitle: "Avg \(formatBytes(avgBytes)) / video", color: .systemPurple))
        overviewCardsStack.addArrangedSubview(makeStatCard(title: "Total Playtime", value: formatDuration(totalDuration), subtitle: "Avg \(formatDuration(avgDuration)) / video", color: .systemOrange))

        // 2. Compute group breakdowns
        computeBreakdowns(records: records, totalBytes: totalBytes, totalCount: totalCount)

        // 3. Update Treemap
        updateTreemap()

        // 4. Reload Tables
        likesTableView.reloadData()
        resolutionsTableView.reloadData()
        durationsTableView.reloadData()
        viewsTableView.reloadData()
    }

    private func computeBreakdowns(records: [Database.DashboardRecord], totalBytes: Int64, totalCount: Int) {
        // Likes Breakdown
        var likesMap: [String: (title: String, count: Int, bytes: Int64, dur: Double, color: NSColor)] = [
            "disliked": ("Disliked (< 0)", 0, 0, 0, .systemRed),
            "unrated": ("Unrated (0 / NULL)", 0, 0, 0, .secondaryLabelColor),
            "1": ("1 Like", 0, 0, 0, .systemOrange),
            "2": ("2 Likes", 0, 0, 0, .systemYellow),
            "3": ("3 Likes", 0, 0, 0, .systemGreen),
            "4": ("4 Likes", 0, 0, 0, .systemTeal),
            "5+": ("5+ Likes", 0, 0, 0, .systemPurple),
        ]

        for r in records {
            let key: String
            switch r.like {
            case .some(let l) where l < 0: key = "disliked"
            case .some(1): key = "1"
            case .some(2): key = "2"
            case .some(3): key = "3"
            case .some(4): key = "4"
            case .some(let l) where l >= 5: key = "5+"
            default: key = "unrated"
            }
            if var entry = likesMap[key] {
                entry.count += 1
                entry.bytes += r.fileSize
                entry.dur += r.duration ?? 0
                likesMap[key] = entry
            }
        }

        let likesOrder = ["disliked", "unrated", "1", "2", "3", "4", "5+"]
        likesStats = likesOrder.compactMap { key in
            guard let entry = likesMap[key] else { return nil }
            return GroupStat(key: key, title: entry.title, count: entry.count, totalSizeBytes: entry.bytes, totalDurationSec: entry.dur, color: entry.color)
        }

        // Resolutions Breakdown
        var resMap: [String: (title: String, count: Int, bytes: Int64, dur: Double, color: NSColor)] = [
            "4k": ("4K / 2160p+", 0, 0, 0, .systemPurple),
            "1080p": ("1080p Full HD", 0, 0, 0, .systemBlue),
            "720p": ("720p HD", 0, 0, 0, .systemTeal),
            "sd": ("480p / SD", 0, 0, 0, .systemGreen),
            "unknown": ("Unknown / Missing", 0, 0, 0, .systemGray),
        ]

        for r in records {
            let key: String
            if let w = r.width {
                if w >= 3840 { key = "4k" }
                else if w >= 1920 { key = "1080p" }
                else if w >= 1280 { key = "720p" }
                else if w > 0 { key = "sd" }
                else { key = "unknown" }
            } else {
                key = "unknown"
            }
            if var entry = resMap[key] {
                entry.count += 1
                entry.bytes += r.fileSize
                entry.dur += r.duration ?? 0
                resMap[key] = entry
            }
        }

        let resOrder = ["4k", "1080p", "720p", "sd", "unknown"]
        resolutionsStats = resOrder.compactMap { key in
            guard let entry = resMap[key] else { return nil }
            return GroupStat(key: key, title: entry.title, count: entry.count, totalSizeBytes: entry.bytes, totalDurationSec: entry.dur, color: entry.color)
        }

        // Durations Breakdown
        var durMap: [String: (title: String, count: Int, bytes: Int64, dur: Double, color: NSColor)] = [
            "short": ("Short (< 5 min)", 0, 0, 0, .systemTeal),
            "medium": ("Medium (5 - 15 min)", 0, 0, 0, .systemGreen),
            "long": ("Long (15 - 30 min)", 0, 0, 0, .systemYellow),
            "extended": ("Extended (30 - 60 min)", 0, 0, 0, .systemOrange),
            "feature": ("Feature (> 1 hour)", 0, 0, 0, .systemRed),
            "unknown": ("Unknown Duration", 0, 0, 0, .systemGray),
        ]

        for r in records {
            let key: String
            if let d = r.duration, d > 0 {
                if d < 300 { key = "short" }
                else if d < 900 { key = "medium" }
                else if d < 1800 { key = "long" }
                else if d < 3600 { key = "extended" }
                else { key = "feature" }
            } else {
                key = "unknown"
            }
            if var entry = durMap[key] {
                entry.count += 1
                entry.bytes += r.fileSize
                entry.dur += r.duration ?? 0
                durMap[key] = entry
            }
        }

        let durOrder = ["short", "medium", "long", "extended", "feature", "unknown"]
        durationsStats = durOrder.compactMap { key in
            guard let entry = durMap[key] else { return nil }
            return GroupStat(key: key, title: entry.title, count: entry.count, totalSizeBytes: entry.bytes, totalDurationSec: entry.dur, color: entry.color)
        }

        // Views Breakdown
        var viewsMap: [String: (title: String, count: Int, bytes: Int64, dur: Double, color: NSColor)] = [
            "unwatched": ("Unwatched (0 views)", 0, 0, 0, .systemGray),
            "1-2": ("1 - 2 Views", 0, 0, 0, .systemBlue),
            "3-5": ("3 - 5 Views", 0, 0, 0, .systemOrange),
            "6+": ("6+ Views", 0, 0, 0, .systemPurple),
        ]

        for r in records {
            let key: String
            switch r.viewCount {
            case .none, .some(0): key = "unwatched"
            case .some(1), .some(2): key = "1-2"
            case .some(3), .some(4), .some(5): key = "3-5"
            default: key = "6+"
            }
            if var entry = viewsMap[key] {
                entry.count += 1
                entry.bytes += r.fileSize
                entry.dur += r.duration ?? 0
                viewsMap[key] = entry
            }
        }

        let viewsOrder = ["unwatched", "1-2", "3-5", "6+"]
        viewsStats = viewsOrder.compactMap { key in
            guard let entry = viewsMap[key] else { return nil }
            return GroupStat(key: key, title: entry.title, count: entry.count, totalSizeBytes: entry.bytes, totalDurationSec: entry.dur, color: entry.color)
        }
    }

    private func updateTreemap() {
        let selectedIndex = treemapMetricControl.selectedSegment
        let totalRecords = activeRecords.count
        let totalBytes = activeRecords.reduce(Int64(0)) { $0 + $1.fileSize }

        var treemapItems: [TreemapItem] = []

        switch selectedIndex {
        case 0: // By Likes (visualize storage size by like tier)
            treemapTitleLabel.stringValue = "Squarified Treemap: Storage Distribution by Like Rating"
            for stat in likesStats {
                guard stat.totalSizeBytes > 0 else { continue }
                let pct = totalBytes > 0 ? (Double(stat.totalSizeBytes) / Double(totalBytes)) * 100.0 : 0
                treemapItems.append(TreemapItem(
                    id: stat.key,
                    title: stat.title,
                    subtitle: "\(stat.count) videos",
                    value: Double(stat.totalSizeBytes),
                    formattedValue: formatBytes(stat.totalSizeBytes),
                    percentage: pct,
                    color: stat.color
                ))
            }

        case 1: // By Resolutions (visualize video counts)
            treemapTitleLabel.stringValue = "Squarified Treemap: Video Count by Resolution Class"
            for stat in resolutionsStats {
                guard stat.count > 0 else { continue }
                let pct = totalRecords > 0 ? (Double(stat.count) / Double(totalRecords)) * 100.0 : 0
                treemapItems.append(TreemapItem(
                    id: stat.key,
                    title: stat.title,
                    subtitle: formatBytes(stat.totalSizeBytes),
                    value: Double(stat.count),
                    formattedValue: "\(stat.count) videos",
                    percentage: pct,
                    color: stat.color
                ))
            }

        case 2: // By Durations (visualize video counts)
            treemapTitleLabel.stringValue = "Squarified Treemap: Video Count by Duration Range"
            for stat in durationsStats {
                guard stat.count > 0 else { continue }
                let pct = totalRecords > 0 ? (Double(stat.count) / Double(totalRecords)) * 100.0 : 0
                treemapItems.append(TreemapItem(
                    id: stat.key,
                    title: stat.title,
                    subtitle: formatDuration(stat.totalDurationSec),
                    value: Double(stat.count),
                    formattedValue: "\(stat.count) videos",
                    percentage: pct,
                    color: stat.color
                ))
            }

        case 3: // By Views (visualize storage size)
            treemapTitleLabel.stringValue = "Squarified Treemap: Storage Distribution by View Count Tier"
            for stat in viewsStats {
                guard stat.totalSizeBytes > 0 else { continue }
                let pct = totalBytes > 0 ? (Double(stat.totalSizeBytes) / Double(totalBytes)) * 100.0 : 0
                treemapItems.append(TreemapItem(
                    id: stat.key,
                    title: stat.title,
                    subtitle: "\(stat.count) videos",
                    value: Double(stat.totalSizeBytes),
                    formattedValue: formatBytes(stat.totalSizeBytes),
                    percentage: pct,
                    color: stat.color
                ))
            }

        default:
            break
        }

        treemapView.setItems(treemapItems)
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds > 0, seconds.isFinite else { return "0s" }
        let totalSec = Int(seconds)
        let days = totalSec / 86400
        let hours = (totalSec % 86400) / 3600
        let mins = (totalSec % 3600) / 60
        let secs = totalSec % 60

        if days > 0 {
            return "\(days)d \(hours)h \(mins)m"
        } else if hours > 0 {
            return "\(hours)h \(mins)m"
        } else if mins > 0 {
            return "\(mins)m \(secs)s"
        } else {
            return "\(secs)s"
        }
    }
}

// MARK: - NSTableViewDataSource / Delegate for Breakdown Tables

extension DashboardWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === likesTableView { return likesStats.count }
        if tableView === resolutionsTableView { return resolutionsStats.count }
        if tableView === durationsTableView { return durationsStats.count }
        if tableView === viewsTableView { return viewsStats.count }
        return 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let colId = tableColumn?.identifier.rawValue else { return nil }

        let totalRecords = activeRecords.count
        let totalBytes = activeRecords.reduce(Int64(0)) { $0 + $1.fileSize }

        let text: String
        var customColor: NSColor? = nil

        if tableView === likesTableView, likesStats.indices.contains(row) {
            let stat = likesStats[row]
            let avgBytes = stat.count > 0 ? stat.totalSizeBytes / Int64(stat.count) : 0
            let pct = totalBytes > 0 ? (Double(stat.totalSizeBytes) / Double(totalBytes)) * 100.0 : 0

            switch colId {
            case "tier": text = stat.title; customColor = stat.color
            case "count": text = "\(stat.count)"
            case "size": text = formatBytes(stat.totalSizeBytes)
            case "avg_size": text = formatBytes(avgBytes)
            case "pct": text = String(format: "%.1f%%", pct)
            default: text = ""
            }
        } else if tableView === resolutionsTableView, resolutionsStats.indices.contains(row) {
            let stat = resolutionsStats[row]
            let pct = totalRecords > 0 ? (Double(stat.count) / Double(totalRecords)) * 100.0 : 0

            switch colId {
            case "res": text = stat.title; customColor = stat.color
            case "count": text = "\(stat.count)"
            case "size": text = formatBytes(stat.totalSizeBytes)
            case "pct": text = String(format: "%.1f%%", pct)
            default: text = ""
            }
        } else if tableView === durationsTableView, durationsStats.indices.contains(row) {
            let stat = durationsStats[row]
            let pct = totalRecords > 0 ? (Double(stat.count) / Double(totalRecords)) * 100.0 : 0

            switch colId {
            case "dur": text = stat.title; customColor = stat.color
            case "count": text = "\(stat.count)"
            case "total_dur": text = formatDuration(stat.totalDurationSec)
            case "size": text = formatBytes(stat.totalSizeBytes)
            case "pct": text = String(format: "%.1f%%", pct)
            default: text = ""
            }
        } else if tableView === viewsTableView, viewsStats.indices.contains(row) {
            let stat = viewsStats[row]
            let pct = totalRecords > 0 ? (Double(stat.count) / Double(totalRecords)) * 100.0 : 0

            switch colId {
            case "views": text = stat.title; customColor = stat.color
            case "count": text = "\(stat.count)"
            case "size": text = formatBytes(stat.totalSizeBytes)
            case "pct": text = String(format: "%.1f%%", pct)
            default: text = ""
            }
        } else {
            text = ""
        }

        let cellId = NSUserInterfaceItemIdentifier("dash-cell-\(colId)")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellId
            let textField = NSTextField(labelWithString: "")
            textField.isSelectable = true
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        cell.textField?.stringValue = text
        if let customColor {
            cell.textField?.textColor = customColor
            cell.textField?.font = .systemFont(ofSize: 12, weight: .bold)
        } else {
            cell.textField?.textColor = .labelColor
            cell.textField?.font = .systemFont(ofSize: 12, weight: .regular)
        }
        return cell
    }
}
