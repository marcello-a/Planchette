import SwiftUI

/// Settings → Tabs: what names a tab, and what else it carries. The tab bar of a
/// project, its cluster tiles and its overview cards all read these (`AppState.tabName`).
struct TabSettings: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            // First, so the result of every choice below is in view as it is made.
            Section(L10n.t(.tabExampleSection)) {
                TabExample(layout: appState.tabLayout)
            }
            Section(L10n.t(.tabNameSection)) {
                Picker(L10n.t(.tabNameTitle), selection: $appState.tabLayout.name) {
                    ForEach(TabName.allCases) { source in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.t(source.titleKey))
                            Text(L10n.t(source.helpKey))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .tag(source)
                    }
                }
                .pickerStyle(.radioGroup)
            }
            Section(L10n.t(.tabShowsSection)) {
                switchRow(.tabShowPath, .tabShowPathHelp, $appState.tabLayout.showsPath)
                switchRow(.tabShowBranch, .tabShowBranchHelp, $appState.tabLayout.showsBranch)
                switchRow(.tabShowTags, .tabShowTagsHelp, $appState.tabLayout.showsTags)
            }
        }
        .formStyle(.grouped)
    }

    private func switchRow(_ title: LKey, _ help: LKey, _ isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(L10n.t(title), isOn: isOn)
            Text(L10n.t(help))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What the choices above make of a tab: a bar in the default project color with the tab you are
/// in, built with the tab bar's own pieces and sample words. Not interactive.
private struct TabExample: View {
    @EnvironmentObject var appState: AppState
    let layout: TabLayout

    var body: some View {
        HStack(spacing: 4) {
            tab
            Image(systemName: "plus").foregroundStyle(.secondary).padding(.horizontal, 6)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ProjectGradient(color: .none).clipShape(RoundedRectangle(cornerRadius: 6)) }
        .allowsHitTesting(false)
    }

    private var name: String {
        switch layout.name {
        case .summary: "Gallery wall menu"
        case .lastPrompt: "Fix the menu spacing"
        case .firstPrompt: "Add a gallery wall"
        case .ticketAndPrompt: "NIE-2008 · Fix spacing"
        }
    }

    private var tab: some View {
        HStack(spacing: 5) {
            StateIcon(state: .running, size: 13)
            Text(name).lineLimit(1).frame(maxWidth: 160, alignment: .leading)
            if layout.showsPath {
                Text("work/gallery").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if layout.showsBranch {
                BranchText(branch: "marcello/feat/NIE-2008-gallery-menu", trim: appState.sidebarDetails.branchTrim)
                    .frame(maxWidth: 110, alignment: .leading)
            }
            if layout.showsTags { TagChips(tags: ["review"]) }
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(AnyShapeStyle(.selection), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(AttentionState.running.tint, lineWidth: 2))
    }
}
