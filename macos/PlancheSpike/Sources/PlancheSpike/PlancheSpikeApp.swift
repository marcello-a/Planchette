import SwiftUI
import GhosttyKit

@main
struct PlancheSpikeApp: App {
    init() {
        // Running as a bare SPM executable: promote to a regular app so the
        // window appears and receives focus.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup("Planchette — Spike A") {
            ContentView()
                .frame(minWidth: 1100, minHeight: 600)
        }
    }
}

struct ContentView: View {
    var body: some View {
        if let app = GhosttyRuntime.shared.app {
            HSplitView {
                terminalPane(title: "Terminal 1", app: app)
                terminalPane(title: "Terminal 2", app: app)
            }
        } else {
            Text("libghostty failed to initialize — see console log")
                .padding()
        }
    }

    private func terminalPane(title: String, app: ghostty_app_t) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.caption.bold())
                .frame(maxWidth: .infinity)
                .padding(4)
                .background(.quaternary)
            GhosttyTerminalView(app: app)
        }
        .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
    }
}
