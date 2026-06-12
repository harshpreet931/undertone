import AppKit
import ApplicationServices
import CoreGraphics

/// Puts text at the cursor of the frontmost app (ARCHITECTURE.md §6.8).
protocol TextInserter: AnyObject {
    func insert(_ text: String) async throws
}

enum InsertionError: Error {
    case accessibilityNotGranted
    case eventCreationFailed
}

/// Primary strategy: clipboard save → write text → synthesize ⌘V → restore.
/// The only approach that works essentially everywhere (Electron, terminals,
/// browsers, Java apps). A clipboard-free `AXInserter` (kAXSelectedTextAttribute)
/// is the planned opportunistic upgrade, falling back to this.
@MainActor
final class PasteInserter: TextInserter {
    /// Our writes carry this marker type so clipboard managers can ignore them.
    static let transientType = NSPasteboard.PasteboardType("app.undertone.transient")

    func insert(_ text: String) async throws {
        guard AXIsProcessTrusted() else {
            // Degraded path (ARCHITECTURE.md §7): leave the text on the clipboard
            // so the user can ⌘V manually, then report why.
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            throw InsertionError.accessibilityNotGranted
        }

        let pasteboard = NSPasteboard.general
        let savedString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("1", forType: Self.transientType)
        let ourChangeCount = pasteboard.changeCount

        try synthesizeCommandV()

        // Give the target app time to read the pasteboard before restoring.
        try await Task.sleep(nanoseconds: 150_000_000)

        // Restore only if nobody else touched the clipboard meanwhile
        // (changeCount race guard, ARCHITECTURE.md §6.8).
        if pasteboard.changeCount == ourChangeCount, let savedString {
            pasteboard.clearContents()
            pasteboard.setString(savedString, forType: .string)
        }
    }

    private func synthesizeCommandV() throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode: CGKeyCode = 9
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            throw InsertionError.eventCreationFailed
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
