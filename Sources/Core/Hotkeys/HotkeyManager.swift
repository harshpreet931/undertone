import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Default ⌘⇧Space, recordable in settings via KeyboardShortcuts.Recorder.
    static let toggleDictation = Self("toggleDictation", default: .init(.space, modifiers: [.command, .shift]))
    /// Plain Esc. Registered as a Carbon hotkey (needs no Accessibility grant,
    /// unlike NSEvent global monitors) and only enabled while recording, so it
    /// never swallows Esc for the rest of the system.
    static let cancelDictation = Self("cancelDictation", default: .init(.escape))
}

/// Global shortcuts (ARCHITECTURE.md §6.2). KeyboardShortcuts covers toggle and
/// hold-to-talk for ordinary key combos (it exposes both key-down and key-up).
///
/// Modifier-only push-to-talk (hold right-⌘ / double-tap fn) is NOT expressible
/// as a hotkey and will be a separate P2 component (`ModifierKeyTap`): a
/// CGEventTap on `.flagsChanged`, gated behind the Input Monitoring permission
/// and only active when the user enables that trigger.
@MainActor
final class HotkeyManager {
    var onToggle: (() -> Void)?
    /// Hold-to-talk wiring: down starts recording, up finishes. Whether the
    /// shortcut acts as toggle or hold is a user setting consumed by AppState.
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    /// Fired by Esc while `setCancelEnabled(true)` (i.e. during recording).
    var onCancel: (() -> Void)?

    init() {
        KeyboardShortcuts.onKeyDown(for: .toggleDictation) { [weak self] in
            self?.onKeyDown?()
        }
        KeyboardShortcuts.onKeyUp(for: .toggleDictation) { [weak self] in
            self?.onKeyUp?()
            self?.onToggle?()
        }
        KeyboardShortcuts.onKeyDown(for: .cancelDictation) { [weak self] in
            self?.onCancel?()
        }
        KeyboardShortcuts.disable(.cancelDictation)
    }

    /// Enable only while recording: a plain-Esc hotkey must not exist outside
    /// that window or it would eat every Esc press system-wide.
    func setCancelEnabled(_ enabled: Bool) {
        if enabled {
            KeyboardShortcuts.enable(.cancelDictation)
        } else {
            KeyboardShortcuts.disable(.cancelDictation)
        }
    }
}
