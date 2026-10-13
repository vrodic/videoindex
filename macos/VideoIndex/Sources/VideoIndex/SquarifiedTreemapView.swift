import Cocoa

/// Item model for the Squarified Treemap visualization.
struct TreemapItem {
    let id: String
    let title: String
    let subtitle: String?
    let value: Double
    let formattedValue: String
    let percentage: Double
    let color: NSColor
}

/// Calculated tile geometry for drawing.
private struct TreemapTile {
    let item: TreemapItem
    let frame: NSRect
}

/// Custom AppKit view implementing Bruls et al. Squarified Treemap layout algorithm.
final class SquarifiedTreemapView: NSView {
    var onSelectTile: ((TreemapItem) -> Void)?

    private var items: [TreemapItem] = []
    private var tiles: [TreemapTile] = []
    private var hoveredTileIndex: Int?

    override var isFlipped: Bool { true }

    func setItems(_ newItems: [TreemapItem]) {
        // Filter out zero or negative values, sort descending by value
        self.items = newItems.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        recalculateLayout()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recalculateLayout()
        needsDisplay = true
    }

    // MARK: - Layout Calculation (Squarified Treemap Algorithm)

    private func recalculateLayout() {
        tiles.removeAll()
        guard !items.isEmpty, bounds.width > 20, bounds.height > 20 else { return }

        let totalValue = items.reduce(0.0) { $0 + $1.value }
        guard totalValue > 0 else { return }

        let containerArea = Double(bounds.width * bounds.height)

        // Convert item values to target areas
        let areas = items.map { ($0, ($0.value / totalValue) * containerArea) }

        var remainingBounds = bounds
        squarify(itemsWithAreas: areas, currentMinSide: minSide(remainingBounds), row: [], containerBounds: &remainingBounds)
    }

    private func minSide(_ rect: NSRect) -> Double {
        Double(min(rect.width, rect.height))
    }

    private func squarify(
        itemsWithAreas: [(item: TreemapItem, area: Double)],
        currentMinSide: Double,
        row: [(item: TreemapItem, area: Double)],
        containerBounds: inout NSRect
    ) {
        guard !itemsWithAreas.isEmpty else {
            if !row.isEmpty {
                layoutRow(row, containerBounds: &containerBounds)
            }
            return
        }

        var remaining = itemsWithAreas
        let head = remaining.removeFirst()

        if row.isEmpty {
            squarify(itemsWithAreas: remaining, currentMinSide: currentMinSide, row: [head], containerBounds: &containerBounds)
        } else {
            let currentWorst = worstAspectRatio(row: row, side: currentMinSide)
            var newRow = row
            newRow.append(head)
            let newWorst = worstAspectRatio(row: newRow, side: currentMinSide)

            if newWorst <= currentWorst {
                squarify(itemsWithAreas: remaining, currentMinSide: currentMinSide, row: newRow, containerBounds: &containerBounds)
            } else {
                layoutRow(row, containerBounds: &containerBounds)
                let newMinSide = minSide(containerBounds)
                squarify(itemsWithAreas: itemsWithAreas, currentMinSide: newMinSide, row: [], containerBounds: &containerBounds)
            }
        }
    }

    private func worstAspectRatio(row: [(item: TreemapItem, area: Double)], side: Double) -> Double {
        guard side > 0 else { return Double.greatestFiniteMagnitude }
        let sumArea = row.reduce(0.0) { $0 + $1.area }
        guard sumArea > 0 else { return Double.greatestFiniteMagnitude }

        let minArea = row.map { $0.area }.min() ?? sumArea
        let maxArea = row.map { $0.area }.max() ?? sumArea

        let sideSq = side * side
        let sumAreaSq = sumArea * sumArea

        return max((sideSq * maxArea) / sumAreaSq, sumAreaSq / (sideSq * minArea))
    }

    private func layoutRow(_ row: [(item: TreemapItem, area: Double)], containerBounds: inout NSRect) {
        let sumArea = row.reduce(0.0) { $0 + $1.area }
        guard sumArea > 0, containerBounds.width > 0, containerBounds.height > 0 else { return }

        let isHorizontal = containerBounds.width >= containerBounds.height

        if isHorizontal {
            let rowWidth = CGFloat(sumArea / Double(containerBounds.height))
            var currentY = containerBounds.minY

            for entry in row {
                let itemHeight = CGFloat(entry.area / Double(rowWidth))
                let tileRect = NSRect(
                    x: containerBounds.minX,
                    y: currentY,
                    width: rowWidth,
                    height: itemHeight
                )
                tiles.append(TreemapTile(item: entry.item, frame: tileRect))
                currentY += itemHeight
            }

            containerBounds = NSRect(
                x: containerBounds.minX + rowWidth,
                y: containerBounds.minY,
                width: max(0, containerBounds.width - rowWidth),
                height: containerBounds.height
            )
        } else {
            let rowHeight = CGFloat(sumArea / Double(containerBounds.width))
            var currentX = containerBounds.minX

            for entry in row {
                let itemWidth = CGFloat(entry.area / Double(rowHeight))
                let tileRect = NSRect(
                    x: currentX,
                    y: containerBounds.minY,
                    width: itemWidth,
                    height: rowHeight
                )
                tiles.append(TreemapTile(item: entry.item, frame: tileRect))
                currentX += itemWidth
            }

            containerBounds = NSRect(
                x: containerBounds.minX,
                y: containerBounds.minY + rowHeight,
                width: containerBounds.width,
                height: max(0, containerBounds.height - rowHeight)
            )
        }
    }

    // MARK: - Mouse Tracking & Tooltips

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }

        let options: NSTrackingArea.Options = [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp]
        let trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let newHoverIndex = tiles.firstIndex { $0.frame.contains(point) }

        if newHoverIndex != hoveredTileIndex {
            hoveredTileIndex = newHoverIndex
            if let index = newHoverIndex {
                let tile = tiles[index]
                let subtitleText = tile.item.subtitle != nil ? " (\(tile.item.subtitle!))" : ""
                self.toolTip = "\(tile.item.title)\(subtitleText): \(tile.item.formattedValue) (\(String(format: "%.1f", tile.item.percentage))%)"
            } else {
                self.toolTip = nil
            }
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredTileIndex != nil {
            hoveredTileIndex = nil
            self.toolTip = nil
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = tiles.firstIndex(where: { $0.frame.contains(point) }) {
            onSelectTile?(tiles[index].item)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Draw background
        NSColor.clear.setFill()
        dirtyRect.fill()

        if tiles.isEmpty {
            let emptyText = "No data available"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let str = NSAttributedString(string: emptyText, attributes: attrs)
            let strSize = str.size()
            let drawPoint = NSPoint(x: (bounds.width - strSize.width) / 2, y: (bounds.height - strSize.height) / 2)
            str.draw(at: drawPoint)
            return
        }

        let innerPadding: CGFloat = 2

        for (index, tile) in tiles.enumerated() {
            let isHovered = (index == hoveredTileIndex)
            let insetFrame = tile.frame.insetBy(dx: innerPadding, dy: innerPadding)
            guard insetFrame.width > 2 && insetFrame.height > 2 else { continue }

            let path = NSBezierPath(roundedRect: insetFrame, xRadius: 4, yRadius: 4)

            // Fill color
            let fillColor = isHovered ? tile.item.color.highlight(withLevel: 0.15) ?? tile.item.color : tile.item.color
            fillColor.setFill()
            path.fill()

            // Border
            let strokeColor = isHovered ? NSColor.white : NSColor.black.withAlphaComponent(0.2)
            strokeColor.setStroke()
            path.lineWidth = isHovered ? 2.0 : 1.0
            path.stroke()

            // Draw text if tile is big enough
            if insetFrame.width > 35 && insetFrame.height > 20 {
                let isLightColor = tile.item.color.brightnessComponent > 0.6
                let textColor: NSColor = isLightColor ? .black : .white

                let titleFont = NSFont.systemFont(ofSize: insetFrame.height > 40 ? 12 : 10, weight: .bold)
                let valueFont = NSFont.systemFont(ofSize: insetFrame.height > 40 ? 10 : 9, weight: .regular)

                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.alignment = .center
                paragraphStyle.lineBreakMode = .byTruncatingTail

                let titleAttrs: [NSAttributedString.Key: Any] = [
                    .font: titleFont,
                    .foregroundColor: textColor,
                    .paragraphStyle: paragraphStyle
                ]

                let valueAttrs: [NSAttributedString.Key: Any] = [
                    .font: valueFont,
                    .foregroundColor: textColor.withAlphaComponent(0.85),
                    .paragraphStyle: paragraphStyle
                ]

                let titleStr = NSAttributedString(string: tile.item.title, attributes: titleAttrs)
                let valueText = "\(tile.item.formattedValue) (\(String(format: "%.1f", tile.item.percentage))%)"
                let valueStr = NSAttributedString(string: valueText, attributes: valueAttrs)

                let titleHeight = titleStr.size().height
                let valueHeight = valueStr.size().height

                var textRect = insetFrame.insetBy(dx: 4, dy: 4)

                if insetFrame.height >= titleHeight + valueHeight + 4 {
                    let totalTextHeight = titleHeight + valueHeight + 2
                    let startY = textRect.minY + (textRect.height - totalTextHeight) / 2

                    let titleRect = NSRect(x: textRect.minX, y: startY, width: textRect.width, height: titleHeight)
                    let valueRect = NSRect(x: textRect.minX, y: startY + titleHeight + 2, width: textRect.width, height: valueHeight)

                    titleStr.draw(in: titleRect)
                    valueStr.draw(in: valueRect)
                } else {
                    let singleRect = NSRect(x: textRect.minX, y: textRect.minY + (textRect.height - titleHeight) / 2, width: textRect.width, height: titleHeight)
                    titleStr.draw(in: singleRect)
                }
            }
        }
    }
}

// Extension to calculate color brightness helper
private extension NSColor {
    var brightnessComponent: CGFloat {
        guard let rgb = usingColorSpace(.sRGB) else { return 0.5 }
        return (rgb.redComponent * 299 + rgb.greenComponent * 587 + rgb.blueComponent * 114) / 1000
    }
}
