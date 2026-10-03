import Cocoa

/// Custom interactive label for a word in the cloud
final class ClickableWordView: NSTextField {
    var onSelect: (() -> Void)?

    init(word: String, count: Int, attributedTitle: NSAttributedString) {
        super.init(frame: .zero)
        self.stringValue = ""
        self.attributedStringValue = attributedTitle
        self.toolTip = "\(word) appears in \(count) files"
        self.isSelectable = false
        self.isEditable = false
        self.drawsBackground = false
        self.isBordered = false
        self.isBezeled = false
        self.lineBreakMode = .byClipping
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }
}

/// Custom container view that arranges word views in a flowing grid/wrap layout
final class WordCloudFlowView: NSView {
    var onSelectWord: ((String) -> Void)?

    private var words: [(word: String, count: Int)] = []
    private var itemViews: [ClickableWordView] = []

    override var isFlipped: Bool { true }

    func setWords(_ newWords: [(word: String, count: Int)], width: CGFloat) {
        words = newWords

        // Remove old views
        subviews.forEach { $0.removeFromSuperview() }
        itemViews.removeAll()

        let pageMax = words.first?.count ?? 1
        let pageMin = words.last?.count ?? 1

        for (word, count) in words {
            // Calculate font size (range 14 - 44 pt) based on current page distribution
            let minFontSize: CGFloat = 14
            let maxFontSize: CGFloat = 44
            let fontSize: CGFloat
            let ratio: CGFloat
            if pageMax > pageMin {
                ratio = CGFloat(count - pageMin) / CGFloat(pageMax - pageMin)
                fontSize = minFontSize + ratio * (maxFontSize - minFontSize)
            } else {
                ratio = 0.5
                fontSize = 20
            }

            let font = NSFont.systemFont(ofSize: fontSize, weight: ratio >= 0.5 ? .bold : .regular)
            let color = colorForRatio(ratio)

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]

            let attrTitle = NSAttributedString(string: "\(word) (\(count))", attributes: attributes)
            let itemView = ClickableWordView(word: word, count: count, attributedTitle: attrTitle)
            itemView.onSelect = { [weak self] in
                self?.onSelectWord?(word)
            }

            itemViews.append(itemView)
            addSubview(itemView)
        }

        layoutWords(width: width)
    }

    func layoutWords(width: CGFloat) {
        let paddingX: CGFloat = 12
        let paddingY: CGFloat = 12
        let boundsWidth = max(width, 600)

        var currentX: CGFloat = paddingX
        var currentY: CGFloat = paddingY
        var rowMaxHeight: CGFloat = 0

        for itemView in itemViews {
            let textSize = itemView.attributedStringValue.size()
            let itemWidth = ceil(textSize.width) + 12
            let itemHeight = ceil(textSize.height) + 8

            if currentX + itemWidth + paddingX > boundsWidth, currentX > paddingX {
                // Move to next line
                currentX = paddingX
                currentY += rowMaxHeight + paddingY
                rowMaxHeight = 0
            }

            itemView.frame = NSRect(x: currentX, y: currentY, width: itemWidth, height: itemHeight)
            currentX += itemWidth + paddingX
            rowMaxHeight = max(rowMaxHeight, itemHeight)
        }

        let totalHeight = currentY + rowMaxHeight + paddingY
        let newHeight = max(totalHeight, 400)
        setFrameSize(NSSize(width: boundsWidth, height: newHeight))
    }

    private func colorForRatio(_ ratio: CGFloat) -> NSColor {
        if ratio > 0.8 {
            return .systemPurple
        } else if ratio > 0.6 {
            return .systemRed
        } else if ratio > 0.4 {
            return .systemOrange
        } else if ratio > 0.25 {
            return .systemTeal
        } else if ratio > 0.12 {
            return .systemBlue
        } else if ratio > 0.05 {
            return .systemGreen
        } else {
            return .labelColor
        }
    }
}

/// Window controller managing the word cloud presentation and bottom pagination
final class WordCloudWindowController: NSWindowController, NSWindowDelegate {
    var onSelectWord: ((String) -> Void)?

    private let allWords: [(word: String, count: Int)]
    private let pageSize = 200
    private var currentPage = 0
    private var totalPages: Int {
        max(1, Int(ceil(Double(allWords.count) / Double(pageSize))))
    }

    private let scrollView = NSScrollView()
    private let flowView = WordCloudFlowView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
    private let prevButton = NSButton(title: "← Previous", target: nil, action: nil)
    private let nextButton = NSButton(title: "Next →", target: nil, action: nil)
    private let pageLabel = NSTextField(labelWithString: "")

    init(wordFrequencies: [(word: String, count: Int)]) {
        self.allWords = wordFrequencies

        // Calculate 90% of main screen frame
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let windowWidth = screenFrame.width * 0.90
        let windowHeight = screenFrame.height * 0.90
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
        window.title = "Word Cloud Search"
        window.minSize = NSSize(width: 600, height: 400)

        super.init(window: window)
        window.delegate = self

        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        updatePage()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        flowView.onSelectWord = { [weak self] word in
            self?.onSelectWord?(word)
            self?.close()
        }

        scrollView.documentView = flowView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        prevButton.target = self
        prevButton.action = #selector(prevPageClicked)
        prevButton.translatesAutoresizingMaskIntoConstraints = false

        nextButton.target = self
        nextButton.action = #selector(nextPageClicked)
        nextButton.translatesAutoresizingMaskIntoConstraints = false

        pageLabel.font = .systemFont(ofSize: 13, weight: .medium)
        pageLabel.alignment = .center
        pageLabel.translatesAutoresizingMaskIntoConstraints = false

        let bottomStack = NSStackView(views: [prevButton, pageLabel, nextButton])
        bottomStack.orientation = .horizontal
        bottomStack.alignment = .centerY
        bottomStack.spacing = 20
        bottomStack.distribution = .fillProportionally
        bottomStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(scrollView)
        contentView.addSubview(bottomStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -10),

            bottomStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            bottomStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            bottomStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            bottomStack.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    func windowDidResize(_ notification: Notification) {
        let width = scrollView.contentSize.width > 0 ? scrollView.contentSize.width : scrollView.bounds.width
        flowView.layoutWords(width: width)
    }

    private func updatePage() {
        let startIndex = currentPage * pageSize
        let endIndex = min(startIndex + pageSize, allWords.count)

        let pageWords: [(word: String, count: Int)]
        if startIndex < allWords.count {
            pageWords = Array(allWords[startIndex..<endIndex])
        } else {
            pageWords = []
        }

        let width = scrollView.contentSize.width > 0 ? scrollView.contentSize.width : (window?.contentView?.bounds.width ?? 1000) - 20
        flowView.setWords(pageWords, width: width)

        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        prevButton.isEnabled = currentPage > 0
        nextButton.isEnabled = currentPage < totalPages - 1

        if allWords.isEmpty {
            pageLabel.stringValue = "No words found"
        } else {
            pageLabel.stringValue = "Page \(currentPage + 1) of \(totalPages) (\(allWords.count) total words)"
        }
    }

    @objc private func prevPageClicked() {
        if currentPage > 0 {
            currentPage -= 1
            updatePage()
        }
    }

    @objc private func nextPageClicked() {
        if currentPage < totalPages - 1 {
            currentPage += 1
            updatePage()
        }
    }
}
