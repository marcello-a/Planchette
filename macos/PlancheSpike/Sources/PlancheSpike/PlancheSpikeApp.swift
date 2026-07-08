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
    @StateObject private var hookServer = HookServer()

    var body: some View {
        VStack(spacing: 0) {
            attentionBanner
            if let app = GhosttyRuntime.shared.app {
                HSplitView {
                    terminalPane(title: "Terminal 1", session: "term-1", app: app)
                    terminalPane(title: "Terminal 2", session: "term-2", app: app)
                }
            } else {
                Text("libghostty failed to initialize — see console log")
                    .padding()
            }
        }
        .onAppear { hookServer.start() }
    }

    @ViewBuilder
    private var attentionBanner: some View {
        if let event = hookServer.lastEvent {
            HStack {
                Image(systemName: event.hookEvent == "Notification"
                    ? "questionmark.bubble.fill" : "checkmark.circle.fill")
                Text("\(event.session): \(event.hookEvent)")
                    .bold()
                if !event.message.isEmpty {
                    Text("— \(event.message)").lineLimit(1)
                }
                Spacer()
                Text(event.receivedAt, style: .time).foregroundStyle(.secondary)
            }
            .padding(8)
            .background(event.hookEvent == "Notification" ? .orange.opacity(0.25) : .green.opacity(0.25))
        } else {
            HStack {
                Image(systemName: "moon.zzz")
                Text("No attention events yet").foregroundStyle(.secondary)
                Spacer()
            }
            .padding(8)
            .background(.quaternary.opacity(0.5))
        }
    }

    private func terminalPane(title: String, session: String, app: ghostty_app_t) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.caption.bold())
                .frame(maxWidth: .infinity)
                .padding(4)
                .background(.quaternary)
            GhosttyTerminalView(
                app: app,
                environment: ["PLANCHETTE_SESSION": session]
            )
        }
        .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
    }
}
