import AppKit
import ApplicationServices
import SwiftUI

/// Menu-bar agent app (ARCHITECTURE.md §2). LSUIElement in Resources/Info.plist
/// keeps it out of the Dock; all interaction is the menu and global hotkeys.
@main
struct UndertoneApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(appState: appState)
        } label: {
            MenuBarIcon(systemName: menuIcon)
        }
        .menuBarExtraStyle(.menu)

        Window("Setup", id: "setup") {
            SetupView()
        }
        .windowResizability(.contentSize)

        Window("History", id: "history") {
            HistoryView()
                .modelContainer(appState.container)
        }
        .defaultSize(width: 520, height: 620)

        Settings {
            SettingsView()
                .modelContainer(appState.container)
        }
    }

    private var menuIcon: String {
        switch appState.session.state {
        case .idle: "mic"
        case .recording: "mic.fill"
        case .transcribing, .enhancing: "waveform"
        case .inserting: "text.cursor"
        }
    }
}

/// The status-bar label view: also the app's only always-alive view, so it
/// doubles as the launch hook that pops the Setup window when permissions
/// are missing (an LSUIElement app has no other first-window moment).
private struct MenuBarIcon: View {
    let systemName: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: systemName)
            .task {
                if PermissionsModel.needsSetup() {
                    openWindow(id: "setup")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

struct MenuContent: View {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(statusLine)

        Button(appState.session.state == .recording ? "Stop Dictation" : "Start Dictation") {
            appState.toggleDictation()
        }
        .keyboardShortcut(.space, modifiers: [.command, .shift])

        if !appState.modes.isEmpty {
            Divider()
            Picker("Mode", selection: $appState.pickedModeName) {
                Text("Automatic").tag(String?.none)
                ForEach(appState.modes, id: \.name) { mode in
                    Text(mode.name).tag(String?.some(mode.name))
                }
            }
        }

        if !AXIsProcessTrusted() {
            Button("⚠️ Finish Setup — text isn’t inserting…") {
                openWindow(id: "setup")
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        Divider()
        Button("History…") {
            openWindow(id: "history")
            // LSUIElement apps don't auto-activate; without this the window
            // opens behind whatever is frontmost.
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("y", modifiers: .command)
        Button("Settings…") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()
        Button("Quit Undertone") {
            NSApp.terminate(nil)
        }
    }

    private var statusLine: String {
        if let error = appState.startupError ?? appState.session.lastError {
            return error
        }
        switch appState.session.state {
        case .idle: return "Ready — ⌘⇧Space to dictate"
        case .recording: return "Recording… — esc cancels"
        case .transcribing: return "Transcribing…"
        case .enhancing: return "Enhancing…"
        case .inserting: return "Inserting…"
        }
    }
}
