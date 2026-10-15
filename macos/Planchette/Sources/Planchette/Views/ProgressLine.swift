import SwiftUI

/// A terminal's reported progress on its row: one segment per step, then
/// "7/13 Verify · round 2". Steps done are a faint version of the state colour,
/// the current one is the colour itself — so a blue segment is the step that
/// is waiting for you.
struct ProgressLine: View {
    let progress: TerminalProgress
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 1.5) {
                ForEach(1...progress.total, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(fill(index))
                        .frame(height: 3)
                }
            }
            .frame(maxWidth: 160)
            HStack(spacing: 4) {
                Text("\(progress.step)/\(progress.total)")
                    .monospacedDigit()
                    .foregroundStyle(tint)
                Text(caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.caption2)
        }
        .help(tooltip)
    }

    private func fill(_ index: Int) -> Color {
        if index < progress.step { return tint.opacity(0.45) }
        if index == progress.step { return tint }
        return Color.primary.opacity(0.12)
    }

    private var caption: String {
        [progress.stepName, progress.label].compactMap { $0 }.joined(separator: " · ")
    }

    /// Every step by name, the current one marked — the row only has room for one.
    private var tooltip: String {
        var lines = [L10n.t(.progressTooltip, progress.step, progress.total)]
        for (offset, name) in progress.steps.enumerated() {
            let index = offset + 1
            let mark = index < progress.step ? "✓" : index == progress.step ? "▸" : "·"
            lines.append("\(mark) \(name)")
        }
        if let label = progress.label { lines.append(label) }
        return lines.joined(separator: "\n")
    }
}
