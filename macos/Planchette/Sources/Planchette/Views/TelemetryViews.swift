import SwiftUI

/// The one question about usage data: asked once (`Telemetry.promptDue`), with the answer
/// changeable in Settings → Privacy. Closing it without an answer means "ask me after the next
/// update", never yes.
///
/// It asks for a yes with reasons, not with pressure: why the data matters, what is sent and
/// what never is, the report itself to read, and the code behind it. The yes is in the accent
/// colour, but the no stays as large, as close and one click away, and neither is the default:
/// Return picks nothing (consent must be a free, informed choice; GDPR, and the EDPB's
/// guidelines on deceptive design).
struct TelemetryPromptSheet: View {
    @ObservedObject private var telemetry = TelemetryService.shared
    @State private var example: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                Text(L10n.t(.telemetryPromptTitle))
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.t(.telemetryPromptBody))
                .fixedSize(horizontal: false, vertical: true)
            TelemetryWhatList()
            DisclosureGroup(L10n.t(.telemetryShowExample), isExpanded: Binding(
                get: { example != nil },
                set: { example = $0 ? telemetry.previewReport() : nil })) {
                ScrollView {
                    Text(example ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
            }
            .font(.callout)
            Link(L10n.t(.telemetryDocsLink), destination: Telemetry.docsURL)
                .font(.callout)
            Text(L10n.t(.telemetryPromptNote))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.t(.telemetryDontShare)) { telemetry.setConsent(false) }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                // Accent colour, but no `.defaultAction`: Return must not answer yes.
                Button(L10n.t(.telemetryShare)) { telemetry.setConsent(true) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(22)
        .frame(width: 500)
    }
}

/// What a report holds and what it never holds — the same list in the question and in Settings.
/// "Never" is a promise, so it is drawn as one: a lock, not a red cross.
struct TelemetryWhatList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            heading(.telemetrySentHeading)
            row("checkmark.circle", .telemetryWhatFeatures)
            row("checkmark.circle", .telemetryWhatWorkspace)
            row("checkmark.circle", .telemetryWhatErrors)
            heading(.telemetryNeverHeading).padding(.top, 4)
            row("lock", .telemetryWhatNever)
        }
    }

    private func heading(_ key: LKey) -> some View {
        Text(L10n.t(key))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func row(_ symbol: String, _ key: LKey) -> some View {
        Label {
            Text(L10n.t(key)).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

/// Settings → Privacy: the switch, what is sent, the last report word for word, and the id.
struct PrivacySettings: View {
    @ObservedObject private var telemetry = TelemetryService.shared
    @State private var showsReport = false

    var body: some View {
        Form {
            Section {
                Toggle(L10n.t(.telemetryToggle), isOn: Binding(
                    get: { telemetry.record.consent == true },
                    set: { telemetry.setConsent($0) }))
                    .help(L10n.t(.telemetryToggleHelp))
                    .disabled(!telemetry.canSend)
                Text(L10n.t(telemetry.canSend ? .telemetryToggleHelp : .telemetryUnavailable))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(L10n.t(.telemetryWhatTitle)) {
                TelemetryWhatList()
            }
            Section(L10n.t(.telemetryLastReport)) {
                if let sent = telemetry.record.lastSent {
                    Text(L10n.t(.telemetrySentAt, sent.formatted(date: .abbreviated, time: .shortened)))
                } else {
                    Text(L10n.t(.telemetryNothingSent)).foregroundStyle(.secondary)
                }
                Text(L10n.t(.telemetryPending,
                            telemetry.record.features.values.reduce(0, +),
                            telemetry.record.errors.values.reduce(0, +),
                            telemetry.record.crashes.reduce(0) { $0 + $1.count }))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let report = telemetry.record.lastReport {
                    DisclosureGroup(L10n.t(.telemetryShowReport), isExpanded: $showsReport) {
                        ScrollView {
                            Text(report)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 180)
                    }
                }
            }
            Section(L10n.t(.telemetryInstallID)) {
                HStack {
                    Text(telemetry.record.installID.uuidString.lowercased())
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button(L10n.t(.telemetryResetID)) { telemetry.resetInstallID() }
                        .help(L10n.t(.telemetryResetIDHelp))
                }
            }
        }
        .formStyle(.grouped)
    }
}
