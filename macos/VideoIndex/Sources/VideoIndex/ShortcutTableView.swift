import Cocoa

/// Actions triggered by the keyboard shortcuts, implemented by
/// PlayerViewController.
protocol ShortcutTableViewDelegateActions: AnyObject {
    func handlePlay()
    func handleLikeIncrement()
    func handleDeleteOrDislike()
    func handleHome()
    func handleEnd()
    func handleEscape()
}

/// Table view that reproduces the original PyQt keyPressEvent handling:
///   - Return          -> play the selected video
///   - Delete/Backspace -> dislike, then delete on the second press
///   - Home / End       -> jump to first / last row
///   - Escape           -> commit & quit
///   - "+" / "="/ Help  -> like (there's no true "Insert" key on Mac keyboards)
/// Up/Down arrows are left to the default NSTableView behavior, which
/// already moves the selection exactly like the Python version's
/// select_row(±1).
final class ShortcutTableView: NSTableView {
    weak var shortcutHandler: ShortcutTableViewDelegateActions?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            shortcutHandler?.handleEscape()
        case 36, 76: // Return / keypad Enter
            shortcutHandler?.handlePlay()
        case 51, 117: // Delete (Backspace) / Forward Delete
            shortcutHandler?.handleDeleteOrDislike()
        case 115: // Home
            shortcutHandler?.handleHome()
        case 119: // End
            shortcutHandler?.handleEnd()
        case 114: // Help/Insert (present on some external keyboards)
            shortcutHandler?.handleLikeIncrement()
        default:
            if event.charactersIgnoringModifiers == "+" || event.charactersIgnoringModifiers == "=" {
                shortcutHandler?.handleLikeIncrement()
            } else {
                super.keyDown(with: event) // arrow keys etc. keep default behavior
            }
        }
    }
}
