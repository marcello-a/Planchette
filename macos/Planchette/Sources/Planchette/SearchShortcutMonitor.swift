import AppKit

/// Listens for the search shortcut while Planchette is the app in front.
///
/// A *local* event monitor, not a global one: a global monitor needs the
/// Accessibility permission, and the shortcut is for the app you are in. It sees an
/// event before the terminal does, and lets every one of them through except a
/// matched chord — Shift tapped twice must not cost the terminal a key.
///
/// Not `@MainActor`-isolated on purpose: AppKit calls a local monitor on the main
/// thread, as it does everything else here, but its closure type does not say so, and
/// proving it to the compiler would cost an `NSEvent` that is not `Sendable`. The
/// owner (`AppState`) is main-actor bound and is the only one that touches it.
final class SearchShortcutMonitor {
    var shortcut: SearchShortcut {
        didSet { rebuildDetector() }
    }
    /// True while Settings is recording a new shortcut: the keys pressed then are
    /// the answer, not a request to search.
    var isSuspended = false

    private var detector: DoubleTapDetector?
    private var monitor: Any?
    private let onTrigger: () -> Void

    init(shortcut: SearchShortcut, onTrigger: @escaping () -> Void) {
        self.shortcut = shortcut
        self.onTrigger = onTrigger
        rebuildDetector()
        let mask: NSEvent.EventTypeMask = [
            .flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
        ]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func rebuildDetector() {
        if case .doubleTap(let modifier) = shortcut {
            detector = DoubleTapDetector(modifier: modifier)
        } else {
            detector = nil
        }
    }

    static func modifiers(of flags: NSEvent.ModifierFlags) -> Set<SearchShortcut.Modifier> {
        var result: Set<SearchShortcut.Modifier> = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard !isSuspended else { return event }
        switch event.type {
        case .flagsChanged:
            guard detector != nil else { return event }
            let fired = detector?.feed(.modifiers(Self.modifiers(of: event.modifierFlags), at: event.timestamp)) ?? false
            if fired { trigger() }
            return event

        case .keyDown:
            _ = detector?.feed(.other)
            guard case .chord(let key, let modifiers) = shortcut,
                  Self.modifiers(of: event.modifierFlags) == Set(modifiers),
                  event.charactersIgnoringModifiers?.lowercased() == key
            else { return event }
            // The chord is ours: the terminal never sees it, held down or not.
            if !event.isARepeat { trigger() }
            return nil

        default:
            // A click or a scroll: Shift-clicking to select text is not a tap.
            _ = detector?.feed(.other)
            return event
        }
    }

    private func trigger() {
        DispatchQueue.main.async { [onTrigger] in onTrigger() }
    }
}
