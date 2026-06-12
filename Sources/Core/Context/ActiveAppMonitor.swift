import AppKit

/// Tracks the frontmost app's bundle ID (ARCHITECTURE.md §6.3) so mode
/// resolution can apply per-app rules: explicit pick → app rule → default mode.
@MainActor
final class ActiveAppMonitor {
    private(set) var frontmostBundleID: String?
    var onChange: ((String?) -> Void)?

    private var observer: NSObjectProtocol?

    init() {
        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                self?.frontmostBundleID = app?.bundleIdentifier
                self?.onChange?(app?.bundleIdentifier)
            }
        }
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
