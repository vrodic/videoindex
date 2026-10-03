import Cocoa

/// Custom view that arranges word buttons in a flowing grid/wrap layout
final class WordCloudFlowView: NSView {
    var onSelectWord: ((String) -> Void)?

    private var words: [(word: String, count: Int)] = []
    private var maxCount: Int = 1
    private var minCount: Int = 1
    private var buttons: [NSButton] = []

    override var isFlipped: Bool { true }

    func setWords(_ newWords: [(word: String, count: Int)], globalMaxCount: Int) {
        words = newWords
        maxCount = max(globalMaxCount, 1)
        minCount = max(words.last?.count ?? 1, 1)

        // Remove old buttons
        subviews.forEach { $0.removeFromSuperview() }
        buttons.removeAll()

        for (word, count) in words {
            let button = NSButton(title: word, target: self, action: #selector(wordClicked(_:)))
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor.clear.cgColor
            button.alignment = .center

            // Calculate font size (range 14 - 48 pt)
            let minFontSize: CGFloat = 14
            let maxFontSize: CGFloat = 48
            let fontSize: CGFloat
            if maxCount > minCount {
                let ratio = CGFloat(count - minCount) / CGFloat(maxCount - minCount)
                fontSize = minFontSize + ratio * (maxFontSize - minFontSize)
            } else {
                fontSize = 20
            }

            let font = NSFont.systemFont(ofSize: fontSize, weight: count >= maxCount / 2 ? .bold : .regular)

            // Assign color based on frequency ratio
            let color = colorForCount(count, maxCount: maxCount)

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]

            button.attributedTitle = NSAttributedString(string: "\(word) (\(count))", attributes: attributes)
            button.toolTip = "\(word) appears in \(count) files"

            // Mouse cursor as hand pointer
            button.addTrackingArea(NSTrackingArea(rect: button.bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: button, userInfo: nil))

            buttons.append(button)
            addSubview(button)
        }

        needsLayout = true
    }

    private func colorForCount(_ count: Int, maxCount: Int) -> NSColor {
        let ratio = Double(count) / Double(max(maxCount, 1))
        if ratio > 0.7 {
            return .systemPurple
        } else if ratio > 0.4 {
            return .systemRed
        } else if ratio > 0.2 {
            return .systemOrange
        } else if ratio > 0.1 {
            return .systemTeal
        } else if ratio > 0.05 {
            return .systemBlue
        } else if ratio > 0.02 {
            return .systemGreen
        } else {
            return .labelColor
        }
    }

    @objc private func wordClicked(_ sender: NSButton) {
        guard let index = buttons.firstIndex(of: sender), index < words.count else { return }
        let selectedWord = words[index].word
        onSelectWord?(selectedWord)
    }

    override func layout() {
        super.layout()

        let paddingX: CGFloat = 12
        let paddingY: CGFloat = 12
        let boundsWidth = bounds.width > 0 ? bounds.width : 800

        var currentX: CGFloat = paddingX
        var currentY: CGFloat = paddingY
        var rowMaxHeight: CGFloat = 0

        for button in buttons {
            button.sizeToFit()
            let btnWidth = button.frame.width
            let btnHeight = button.frame.height

            if currentX + btnWidth + paddingX > boundsWidth, currentX > paddingX {
                // Move to next line
                currentX = paddingX
                currentY += rowMaxHeight + paddingY
                rowMaxHeight = 0
            }

            button.frame = NSRect(x: currentX, y: currentY, width: btnWidth, height: btnHeight)
            currentX += btnWidth + paddingX
            rowMaxHeight = max(rowMaxHeight, btnHeight)
        }

        let totalHeight = currentY + rowMaxHeight + paddingY
        if frame.height != totalHeight {
            setFrameSize(NSSize(width: bounds.width, height: max(totalHeight, 400)))
        }
    }
}

/// Window controller managing the word cloud presentation and bottom pagination
final class WordCloudWindowController: NSWindowController {
    var onSelectWord: ((String) -> Void)?

    private let allWords: [(word: String, count: Int)]
    private let pageSize = 200
    private var currentPage = 0
    private var totalPages: Int {
        max(1, Int(ceil(Double(allWords.count) / Double(pageSize))))
    }

    private let scrollView = NSScrollView()
    private let flowView = WordCloudFlowView()
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

        setupUI()
        updatePage()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

    private func updatePage() {
        let startIndex = currentPage * pageSize
        let endIndex = min(startIndex + pageSize, allWords.count)

        let pageWords: [(word: String, count: Int)]
        if startIndex < allWords.count {
            pageWords = Array(allWords[startIndex..<endIndex])
        } else {
            pageWords = []
        }

        let globalMax = allWords.first?.count ?? 1
        flowView.setWords(pageWords, globalMaxCount: globalMax)

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
