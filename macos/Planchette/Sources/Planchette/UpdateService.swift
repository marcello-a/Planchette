import AppKit

/// Repo-native update flow: checks the GitHub Releases of the Planchette repo,
/// compares the latest tag to the running app's version, and offers to
/// download the DMG. No external framework — just the GitHub REST API.
///
/// Release process (see scripts/release.sh): tag a stable commit on master as
/// `vX.Y.Z`, attach `Planchette.dmg` to a GitHub Release. This service finds
/// it via /releases/latest.
@MainActor
final class UpdateService: ObservableObject {
    /// owner/repo the in-app updater checks for new releases.
    static let repo = "marcello-a/Planchette"

    @Published var isChecking = false

    private weak var appState: AppState?
    private var didAutoCheck = false

    init(appState: AppState) {
        self.appState = appState
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Run once shortly after launch if the user enabled auto-check.
    func autoCheckIfEnabled() {
        guard appState?.autoUpdateCheck == true, !didAutoCheck else { return }
        didAutoCheck = true
        Task { await check(userInitiated: false) }
    }

    /// Manual "Check for updates…".
    func checkNow() {
        Task { await check(userInitiated: true) }
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String
            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    private func check(userInitiated: Bool) async {
        isChecking = true
        defer { isChecking = false }

        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 404 {
                if userInitiated { showUpToDate() }  // no releases yet
                return
            }
            guard http.statusCode == 200 else {
                if userInitiated { showError("HTTP \(http.statusCode)") }
                return
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            if Semver.isNewer(latest, than: currentVersion) {
                let dmg = release.assets.first { $0.name.hasSuffix(".dmg") }
                showUpdateAvailable(
                    version: latest,
                    downloadURL: dmg?.browserDownloadURL ?? release.htmlURL
                )
            } else if userInitiated {
                showUpToDate()
            }
        } catch {
            if userInitiated { showError(error.localizedDescription) }
        }
    }

    private func showUpdateAvailable(version: String, downloadURL: String) {
        let alert = NSAlert()
        alert.messageText = L10n.t(.updateAvailable, version)
        alert.informativeText = L10n.t(.updateAvailableBody)
        alert.addButton(withTitle: L10n.t(.updateDownload))
        alert.addButton(withTitle: L10n.t(.cancel))
        if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: downloadURL) {
            NSWorkspace.shared.open(url)
        }
    }

    private func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = L10n.t(.updateUpToDate)
        alert.informativeText = L10n.t(.updateCurrentVersion, currentVersion)
        alert.runModal()
    }

    private func showError(_ detail: String) {
        let alert = NSAlert()
        alert.messageText = L10n.t(.updateFailed)
        alert.informativeText = detail
        alert.runModal()
    }
}
