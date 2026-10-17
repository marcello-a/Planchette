import AppKit
import SwiftUI

/// Where the picture of a hint is: `hints/<name>.gif` — in the app bundle's resources, or, in a
/// dev run, in the repository. A hint without its picture still works: the card just has no image.
enum FeatureHintMedia {
    static func url(for hint: FeatureHint) -> URL? {
        if let bundled = Bundle.main.url(forResource: hint.mediaName, withExtension: "gif", subdirectory: "hints") {
            return bundled
        }
        // A dev run: this file is macos/Planchette/Sources/Planchette/Views/<file>.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let dev = root.appendingPathComponent("hints/\(hint.mediaName).gif")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }
}

/// What a hint says and does. One entry per `FeatureHint`: the strings are `LKey`s like any other,
/// so a hint is localized by the rule that localizes everything.
struct FeatureHintContent {
    let title: LKey
    let body: LKey
    let action: LKey
    let perform: @MainActor (AppState) -> Void

    static func of(_ hint: FeatureHint) -> FeatureHintContent {
        switch hint {
        case .notepad:
            return FeatureHintContent(title: .notepadHintTitle, body: .notepadHintBody, action: .notepadHintTry) { state in
                if state.notepad.isOpen { state.completeHint(.notepad) } else { state.toggleNotepad() }
            }
        }
    }
}

/// A GIF that plays: `NSImageView` animates it by itself.
private struct AnimatedImage: NSViewRepresentable {
    let image: NSImage
    let label: String

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView(image: image)
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.isEditable = false
        view.setAccessibilityLabel(label)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {}
}

/// The card: the picture first (it explains the feature faster than words), two lines under it,
/// the way to try it, and "Don't show tips again".
struct FeatureHintCard: View {
    @EnvironmentObject var appState: AppState
    let hint: FeatureHint
    @State private var hideForever = false

    private static let width: CGFloat = 420

    var body: some View {
        let content = FeatureHintContent.of(hint)
        VStack(alignment: .leading, spacing: 10) {
            if let url = FeatureHintMedia.url(for: hint), let image = NSImage(contentsOf: url), image.size.width > 0 {
                AnimatedImage(image: image, label: L10n.t(content.title))
                    .frame(width: Self.width, height: Self.width * image.size.height / image.size.width)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
            }
            Text(L10n.t(content.title)).font(.headline)
            Text(L10n.t(content.body))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Toggle(L10n.t(.hintHide), isOn: $hideForever)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer()
                Button(L10n.t(.close)) { appState.closeHint() }
                Button(L10n.t(content.action)) { content.perform(appState) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: Self.width + 28)
        .onAppear { hideForever = appState.onboarding.hints.hidden }
        .onChange(of: hideForever) { _, hide in appState.hideHints(hide) }
    }
}

/// Points a hint at a view: when `AppState.hintShowing` is this hint, a popover opens at the view.
/// Half a second late on purpose — a popover requested in the pass that creates its anchor is
/// silently dropped, and one that arrives with the new tab would be missed.
private struct FeatureHintModifier: ViewModifier {
    @EnvironmentObject var appState: AppState
    let hint: FeatureHint
    @State private var open = false

    func body(content: Content) -> some View {
        content
            .popover(isPresented: Binding(
                get: { open },
                set: { shown in
                    open = shown
                    if !shown, appState.hintShowing == hint { appState.closeHint() }
                }), arrowEdge: .bottom
            ) { FeatureHintCard(hint: hint) }
            .task(id: appState.hintShowing) {
                guard appState.hintShowing == hint else { open = false; return }
                try? await Task.sleep(for: .seconds(0.5))
                if appState.hintShowing == hint { open = true }
            }
    }
}

extension View {
    /// The anchor of a feature hint (see `FeatureHint`, `AppState.offerHint`).
    func featureHint(_ hint: FeatureHint) -> some View { modifier(FeatureHintModifier(hint: hint)) }
}
