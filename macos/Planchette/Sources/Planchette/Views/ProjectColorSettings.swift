import SwiftUI

/// Settings → General → Project color: where the color of a project shows, and how strong it
/// is. The example is drawn with the app's own gradient, so it cannot drift from the panel and
/// the header it stands for.
struct ProjectColorSection: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Section(L10n.t(.projectColorSection)) {
            // Off in either choice is the end of the gradient, so what the other one says is moot:
            // it dims, but stays in reach — two greyed-out pickers would leave no way back.
            Picker(L10n.t(.projectColorWhere), selection: $appState.projectColor.scope) {
                ForEach(ProjectColorScope.allCases) { Text(L10n.t($0.titleKey)).tag($0) }
            }
            .pickerStyle(.segmented)
            .opacity(appState.projectColor.strength == .off ? 0.5 : 1)
            Picker(L10n.t(.projectColorStrength), selection: $appState.projectColor.strength) {
                ForEach(ProjectColorStrength.allCases) { Text(L10n.t($0.titleKey)).tag($0) }
            }
            .pickerStyle(.segmented)
            .opacity(appState.projectColor.scope == .off ? 0.5 : 1)
            Text(L10n.t(.projectColorHelp))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ProjectColorExample(look: appState.projectColor)
        }
    }
}

/// Two projects as the panel draws them: one with a color, one without. The second is the
/// answer to "what does None look like".
private struct ProjectColorExample: View {
    let look: ProjectColorLook

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            project("storefront", color: .blue, terminals: ["Cart summary split", "Express checkout"])
            project("scratch", color: .none, terminals: ["Warm the CDN cache"])
        }
        .padding(.vertical, 4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func project(_ name: String, color: SessionColor, terminals: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                HStack(spacing: 6) {
                    if let dot = color.color { Circle().fill(dot).frame(width: 9, height: 9) }
                    Text(name)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(ProjectGradient(color: color, look: look).clipShape(RoundedRectangle(cornerRadius: 5)))
            }
            .padding(.leading, 4)
            .padding(.trailing, ProjectWash.trailingInset)
            .padding(.vertical, 4)
            ForEach(Array(terminals.enumerated()), id: \.offset) { row, title in
                HStack(spacing: 6) {
                    StateIcon(state: .ready, size: 12)
                    Text(title).font(.callout).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6).padding(.leading, 28).padding(.trailing, 20)
                .background(ProjectGradient(
                    color: color, look: look, shape: .body(row: row, of: terminals.count)))
            }
        }
    }
}
