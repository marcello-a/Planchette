import AppKit
import CryptoKit

/// Repo-native update flow: checks the GitHub Releases of the Planchette repo,
/// compares the latest tag to the running app's version, and — when a newer one
/// exists — downloads it, swaps the app bundle in place, and relaunches. No
/// external framework, no manual DMG dragging.
///
/// Release process (see scripts/release.sh): tag a stable commit as `vX.Y.Z`
/// and attach `Planchette.zip` (+ `SHA256SUMS`) to a GitHub Release. This
/// service finds it via /releases/latest, verifies the download's checksum, and
/// installs it.
@MainActor
final class UpdateService: ObservableObject {
    /// owner/repo the in-app updater checks for new releases.
    static let repo = "marcello-a/Planchette"

    @Published var isChecking = false
    /// True while a download/install is in flight (drives the Settings UI).
    @Published var isInstalling = false

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

        func asset(named suffix: String) -> Asset? {
            assets.first { $0.name.hasSuffix(suffix) }
        }
    }

    private enum UpdateError: LocalizedError {
        case checksumMismatch, noAppInArchive
        var errorDescription: String? {
            switch self {
            case .checksumMismatch: "The downloaded file failed its integrity check."
            case .noAppInArchive: "The downloaded archive didn't contain Planchette.app."
            }
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
                if userInitiated { showNoReleases() }   // no published releases
                return
            }
            guard http.statusCode == 200 else {
                if userInitiated { showError("HTTP \(http.statusCode)") }
                return
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            if Semver.isNewer(latest, than: currentVersion) {
                offerUpdate(version: latest, release: release)
            } else if userInitiated {
                showUpToDate()
            }
        } catch {
            if userInitiated { showError(error.localizedDescription) }
        }
    }

    // MARK: - Offer

    private func offerUpdate(version: String, release: Release) {
        // Prefer in-app install (zip) when the bundle is replaceable in place;
        // otherwise fall back to opening the DMG for a manual drag-install.
        if let zip = release.asset(named: ".zip"),
           let zipURL = trusted(zip.browserDownloadURL), canReplaceBundle {
            let checksumURL = release.asset(named: "SHA256SUMS").flatMap { trusted($0.browserDownloadURL) }
            let alert = NSAlert()
            alert.messageText = L10n.t(.updateAvailable, version)
            alert.informativeText = L10n.t(.updateInstallBody)
            alert.addButton(withTitle: L10n.t(.updateInstallRelaunch))
            alert.addButton(withTitle: L10n.t(.updateLater))
            if alert.runModal() == .alertFirstButtonReturn {
                Task { await install(zipURL: zipURL, checksumURL: checksumURL) }
            }
        } else {
            let dmg = release.asset(named: ".dmg").flatMap { trusted($0.browserDownloadURL) }
            let target = dmg ?? URL(string: release.htmlURL)
            let alert = NSAlert()
            alert.messageText = L10n.t(.updateAvailable, version)
            alert.informativeText = L10n.t(.updateAvailableBody)
            alert.addButton(withTitle: L10n.t(.updateDownload))
            alert.addButton(withTitle: L10n.t(.cancel))
            if alert.runModal() == .alertFirstButtonReturn, let target,
               Self.isTrustedDownload(target) {
                NSWorkspace.shared.open(target)
            }
        }
    }

    // MARK: - Install

    /// The app bundle we're running from, if it's a real `.app` in a writable
    /// location (so we can swap it in place and relaunch).
    private var canReplaceBundle: Bool {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else { return false }
        return FileManager.default.isWritableFile(atPath: (path as NSString).deletingLastPathComponent)
    }

    private func install(zipURL: URL, checksumURL: URL?) async {
        isInstalling = true
        let panel = InstallProgressPanel()
        panel.show()
        do {
            // 1. Download the zip, showing a live progress bar.
            let downloaded = try await Downloader.download(zipURL) { fraction in
                panel.setDownloading(fraction)
            }
            panel.setInstalling()   // switch to an indeterminate spinner

            // 2. Verify its SHA-256 against the release's checksum file (defence
            //    in depth on top of HTTPS + the GitHub-only host allowlist). If
            //    the release predates SHA256SUMS, skip rather than fail.
            if let checksumURL, let expected = try? await expectedSHA(checksumURL, for: "Planchette.zip") {
                guard sha256(ofFileAt: downloaded) == expected else { throw UpdateError.checksumMismatch }
            }

            // 3. Extract into a temp dir and locate the new .app.
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("planchette-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            try runTool("/usr/bin/ditto", ["-x", "-k", downloaded.path, workDir.path])
            guard let newApp = firstAppBundle(in: workDir) else { throw UpdateError.noAppInArchive }

            // 4. Hand the swap to a detached helper (we can't overwrite our own
            //    running bundle), then quit so it can proceed.
            try swapAndRelaunch(newApp: newApp.path, dest: Bundle.main.bundlePath)
            NSApp.terminate(nil)
        } catch {
            panel.close()
            isInstalling = false
            showError(error.localizedDescription)
        }
    }

    /// Parse a `shasum`-style file and return the hash for `filename`.
    private func expectedSHA(_ url: URL, for filename: String) async throws -> String? {
        let (data, _) = try await URLSession.shared.data(from: url)
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace).filter { !$0.isEmpty }
            if parts.count >= 2, parts.last.map(String.init) == filename {
                return String(parts[0]).lowercased()
            }
        }
        return nil
    }

    private func sha256(ofFileAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func firstAppBundle(in dir: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.first { $0.pathExtension == "app" }
    }

    /// Writes a helper script that waits for us to fully quit, then swaps the
    /// installed bundle for the new one and relaunches. The child survives our
    /// termination. The new build is staged next to the destination and only
    /// swapped in once the copy fully succeeds, so a failed copy can never leave
    /// the app missing. All output is logged for diagnosis.
    /// Args: $1 = new .app (extracted), $2 = installed .app, $3 = log file.
    private func swapAndRelaunch(newApp: String, dest: String) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("planchette-update.log")
        let script = #"""
        #!/bin/sh
        exec >> "$3" 2>&1
        echo "--- swap $(date) : pid \#(pid) ---"
        while kill -0 \#(pid) 2>/dev/null; do sleep 0.2; done
        sleep 0.7   # let the OS release the old bundle after the process exits
        STAGING="$2.new"
        rm -rf "$STAGING"
        if /usr/bin/ditto "$1" "$STAGING"; then
            rm -rf "$2"
            if mv "$STAGING" "$2"; then
                /usr/bin/xattr -dr com.apple.quarantine "$2" 2>/dev/null
                echo "swap ok -> $2"
            else
                echo "ERROR: mv staging into place failed"
            fi
        else
            echo "ERROR: ditto to staging failed; app left untouched"
            rm -rf "$STAGING"
        fi
        open "$2"
        """#
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("planchette-swap-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [scriptURL.path, newApp, dest, logURL.path]
        try task.run()   // detached; keeps running after we terminate
    }

    @discardableResult
    private func runTool(_ launchPath: String, _ args: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }

    private func trusted(_ string: String) -> URL? {
        guard let url = URL(string: string), Self.isTrustedDownload(url) else { return nil }
        return url
    }

    // MARK: - Security

    /// Only follow HTTPS links on GitHub's own hosts, so a tampered API
    /// response can't redirect the user to an arbitrary download.
    nonisolated static func isTrustedDownload(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com"
            || host == "objects.githubusercontent.com"
            || host.hasSuffix(".github.com")
            || host.hasSuffix(".githubusercontent.com")
    }

    // MARK: - Alerts

    private func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = L10n.t(.updateUpToDate)
        alert.informativeText = L10n.t(.updateCurrentVersion, currentVersion)
        alert.runModal()
    }

    private func showNoReleases() {
        let alert = NSAlert()
        alert.messageText = L10n.t(.updateNoReleases)
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

/// Downloads a file while reporting progress (0…1) on the main queue.
private final class Downloader: NSObject, URLSessionDownloadDelegate {
    private var continuation: CheckedContinuation<URL, Error>?
    private let onProgress: (Double) -> Void
    private var moved: URL?

    private init(onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }

    static func download(_ url: URL, onProgress: @escaping (Double) -> Void) async throws -> URL {
        try await Downloader(onProgress: onProgress).run(url)
    }

    private func run(_ url: URL) async throws -> URL {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.onProgress(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temp file is removed when this returns, so move it synchronously.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("planchette-dl-\(UUID().uuidString).zip")
        try? FileManager.default.moveItem(at: location, to: dest)
        moved = dest
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.resume(throwing: error) }
        else if let moved { continuation?.resume(returning: moved) }
        else { continuation?.resume(throwing: URLError(.cannotOpenFile)) }
        continuation = nil
    }
}

/// A small floating window showing update download/install progress.
@MainActor
private final class InstallProgressPanel {
    private var window: NSWindow?
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()

    func show() {
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.frame = NSRect(x: 24, y: 60, width: 332, height: 20)
        label.stringValue = L10n.t(.updateDownloading, 0)

        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0; bar.maxValue = 1
        bar.frame = NSRect(x: 24, y: 30, width: 332, height: 20)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 104))
        content.addSubview(label)
        content.addSubview(bar)

        let w = NSWindow(contentRect: content.frame, styleMask: [.titled],
                         backing: .buffered, defer: false)
        w.title = "Planchette"
        w.isReleasedWhenClosed = false
        w.contentView = content
        w.center()
        w.level = .floating
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setDownloading(_ fraction: Double) {
        bar.isIndeterminate = false
        bar.doubleValue = fraction
        label.stringValue = L10n.t(.updateDownloading, Int(fraction * 100))
    }

    func setInstalling() {
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        label.stringValue = L10n.t(.updateInstalling)
    }

    func close() { window?.close(); window = nil }
}
