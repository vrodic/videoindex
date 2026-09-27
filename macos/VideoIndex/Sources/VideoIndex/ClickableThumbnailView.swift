import Cocoa

/// An `NSImageView` that shows a pointing-hand cursor on hover and calls
/// `onClick` on a plain click. Used for the "Up Next" filmstrip thumbnails,
/// which jump the table's selection to that file when clicked.
final class ClickableThumbnailView: NSImageView {
    var onClick: (() -> Void)?

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        // Deliberately not calling super: NSImageView's default mouseDown
        // handles drag-out-of-the-view behavior we don't want here.
        onClick?()
    }
}
