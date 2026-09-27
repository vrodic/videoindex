import SwiftUI
import AppKit

/// Local NSEvent monitor view wrapper to intercept custom single-key app navigation
/// (+/=, Delete, Return, Home, End, Esc) when typing in text fields is not active.
struct KeyEventHandlerContainer: NSViewRepresentable {
    var onPlay: () -> Void
    var onLikeIncrement: () -> Void
    var onDeleteOrDislike: () -> Void
    var onHome: () -> Void
    var onEnd: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> KeyEventHandlerNSView {
        let view = KeyEventHandlerNSView()
        view.onPlay = onPlay
        view.onLikeIncrement = onLikeIncrement
        view.onDeleteOrDislike = onDeleteOrDislike
        view.onHome = onHome
        view.onEnd = onEnd
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: KeyEventHandlerNSView, context: Context) {
        nsView.onPlay = onPlay
        nsView.onLikeIncrement = onLikeIncrement
        nsView.onDeleteOrDislike = onDeleteOrDislike
        nsView.onHome = onHome
        nsView.onEnd = onEnd
        nsView.onEscape = onEscape
    }
}

final class KeyEventHandlerNSView: NSView {
    var onPlay: (() -> Void)?
    var onLikeIncrement: (() -> Void)?
    var onDeleteOrDislike: (() -> Void)?
    var onHome: (() -> Void)?
    var onEnd: (() -> Void)?
    var onEscape: (() -> Void)?

    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            setupMonitor()
        } else {
            removeMonitor()
        }
    }

    private func setupMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            // If the user is currently editing a text field (Search or Condition), don't intercept normal typing
            if let firstResponder = self.window?.firstResponder,
               firstResponder is NSTextView || firstResponder is NSTextField {
                if event.keyCode == 53 { // Esc still exits or cancels focus
                    self.onEscape?()
                    return nil
                }
                return event
            }

            switch event.keyCode {
            case 53: // Escape
                self.onEscape?()
                return nil
            case 36, 76: // Return / Enter
                self.onPlay?()
                return nil
            case 51, 117: // Delete / Forward Delete
                self.onDeleteOrDislike?()
                return nil
            case 115: // Home
                self.onHome?()
                return nil
            case 119: // End
                self.onEnd?()
                return nil
            case 114: // Help / Insert
                self.onLikeIncrement?()
                return nil
            default:
                if event.charactersIgnoringModifiers == "+" || event.charactersIgnoringModifiers == "=" {
                    self.onLikeIncrement?()
                    return nil
                }
            }

            return event
        }
    }

    private func removeMonitor() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        removeMonitor()
    }
}
