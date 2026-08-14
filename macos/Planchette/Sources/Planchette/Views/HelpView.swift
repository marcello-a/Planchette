import AppKit
import SwiftUI

/// The Help tab: every feature in one searchable list, plus the way to ask for
/// one that isn't there. Its content comes from `Help.sections`, which is built
/// from the same localized strings the controls use — so this page cannot drift
/// from the app without the app itself changing.
struct HelpView: View {
    @State private var query = ""
    let version: String

    var body: some View {
        let sections = Help.sections(matching: query)
        VStack(spacing: 0) {
            searchField
            Divider()
            if sections.isEmpty {
                VStack(spacing: 6) {
                    Text(L10n.t(.helpNoResults)).foregroundStyle(.secondary)
                    requestButton
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            Text(L10n.t(section.titleKey).uppercased())
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14)
                                .padding(.top, 12).padding(.bottom, 4)
                            ForEach(section.entries) { entry in
                                row(entry)
                                Divider().padding(.leading, 14)
                            }
                        }
                        footer
                    }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L10n.t(.helpSearch), text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private func row(_ entry: Help.Entry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t(entry.titleKey)).fontWeight(.medium)
                if let detail = entry.detailKey {
                    Text(L10n.t(detail))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let whereKey = entry.whereKey {
                    Text(L10n.t(whereKey))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            if let shortcut = entry.shortcut {
                Text(shortcut)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t(.helpMissing)).font(.callout)
            requestButton
        }
        .padding(14)
    }

    private var requestButton: some View {
        Button {
            if let url = Help.featureRequestURL(version: version) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Label(L10n.t(.requestFeature), systemImage: "lightbulb")
        }
        .help(L10n.t(.requestFeatureHelp))
    }
}
