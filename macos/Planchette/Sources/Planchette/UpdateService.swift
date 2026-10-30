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

    /// When an update is applied. The binary cannot be swapped under a running
    /// process (see docs/LIVE-UPDATE.md), but nothing forces that swap to happen
    /// the moment the update lands.
    enum InstallMode {
        /// Swap now and relaunch — ends every running turn.
        case now
        /// Verify and stage now, swap at the next quit. No interruption.
        case onQuit
    }

    /// A verified bundle waiting for the next quit, if any. Published so
    /// Settings can say so — a pending update the user cannot see is a surprise
    /// the next time they quit.
    @Published private(set) var stagedUpdate: StagedUpdate?

    struct StagedUpdate: Equatable {
        let version: String
        /// The extracted `.app` to move into place.
        let bundlePath: String
    }

    /// Where a staged update is remembered across launches, so an app that was
    /// killed rather than quit still picks it up.
    static var stagingRecordURL: URL {
        AppState.stateURL.deletingLastPathComponent()
            .appendingPathComponent("staged-update.json")
    }

    init(appState: AppState) {
        self.appState = appState
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// How often a running app re-checks. Planchette is meant to stay open for
    /// days — durable terminals exist precisely so it can — so a launch-only
    /// check means a long-lived instance never learns an update exists.
    static let autoCheckInterval: TimeInterval = 6 * 3600

    /// The version the user said no to, so a background check never asks twice.
    /// Deliberately not persisted: a relaunch is a fair moment to offer again.
    private var declinedVersion: String?
    private var autoCheckTimer: Timer?

    /// Check shortly after launch, then keep checking while the app runs.
    func startAutoChecks() {
        // Housekeeping for earlier runs, off the main thread: it lists the temp
        // folder. A bundle staged for the next quit is kept.
        let staged = stagedUpdate?.bundlePath
        Task.detached(priority: .utility) { Self.cleanStaleArtifacts(keeping: staged) }
        autoCheckIfEnabled()
        let timer = Timer(timeInterval: Self.autoCheckInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.autoCheckIfEnabled(repeating: true) }
        }
        timer.tolerance = 300  // nothing here is time-critical; let macOS coalesce
        RunLoop.main.add(timer, forMode: .common)
        autoCheckTimer = timer
    }

    /// Run if the user enabled auto-check. Once shortly after launch, and then
    /// on `autoCheckInterval` — a repeat check also refreshes detection rules,
    /// which is worth doing on its own since they update independently.
    func autoCheckIfEnabled(repeating: Bool = false) {
        guard appState?.autoUpdateCheck == true else { return }
        if repeating {
            // Never interrupt work in progress, and never re-open a dialog the
            // user is already dealing with or has answered.
            // A staged update does not stop the check: a newer release replaces it (`decide`).
            guard !isChecking, !isInstalling else { return }
        } else {
            guard !didAutoCheck else { return }
            didAutoCheck = true
        }
        Task { await check(userInitiated: false) }
    }

    /// Manual "Check for updates…".
    func checkNow() {
        Task { await check(userInitiated: true) }
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String
        /// The release body — the new version's CHANGELOG section, put there by
        /// scripts/release.sh. Optional: a release published by hand may have none.
        let body: String?
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
            case body
            case assets
        }

        func asset(named suffix: String) -> Asset? {
            assets.first { $0.name.hasSuffix(suffix) }
        }
    }

    /// Why an install was refused. Every one of them leaves the installed app
    /// exactly as it was; the detail that does not belong in a dialog goes to the
    /// log.
    fileprivate enum UpdateError: LocalizedError {
        case checksumMismatch, checksumUnavailable, noAppInArchive
        /// The download itself failed: a bad status, a redirect off GitHub, a
        /// file larger than any release could be.
        case downloadFailed
        /// The archive unpacked, but what is in it is not an acceptable build of
        /// this app (wrong identity, wrong version, broken signature).
        case bundleRejected
        var errorDescription: String? {
            switch self {
            case .checksumMismatch: L10n.t(.updateErrChecksumMismatch)
            case .checksumUnavailable: L10n.t(.updateErrChecksumUnavailable)
            case .noAppInArchive: L10n.t(.updateErrNoApp)
            case .downloadFailed: L10n.t(.updateErrDownload)
            case .bundleRejected: L10n.t(.updateErrBundle)
            }
        }
    }

    /// Every small fetch the updater makes (release metadata, checksums, rules).
    /// Redirects are only followed to GitHub's own hosts over HTTPS — the same
    /// rule as for the download — and a request never waits longer than a minute.
    private static let fetchSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        return URLSession(
            configuration: configuration, delegate: TrustedRedirects(), delegateQueue: nil)
    }()

    enum UpdateDecision: Equatable { case upToDate, offer, alreadyStaged }

    /// What a check that found `latest` does. Newer than the running app: offer it — unless a
    /// bundle for exactly that version (or a newer one) is staged already. A staged bundle for an
    /// older version does not count: the latest is offered and replaces it.
    nonisolated static func decide(latest: String, current: String, staged: String?) -> UpdateDecision {
        guard Semver.isNewer(latest, than: current) else { return .upToDate }
        if let staged, !Semver.isNewer(latest, than: staged) { return .alreadyStaged }
        return .offer
    }

    private func check(userInitiated: Bool) async {
        isChecking = true
        defer { isChecking = false }

        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await Self.fetchSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 404 {
                if userInitiated { showNoReleases() }   // no published releases
                return
            }
            guard http.statusCode == 200, data.count <= Self.maxReleaseJSONBytes else {
                if userInitiated { showError("HTTP \(http.statusCode)") }
                return
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            // Rules first, and regardless of the binary version: a rule fix is
            // the one kind of update that needs no restart at all, so it should
            // not wait for the user to accept an app update.
            await refreshDetectionRules(from: release)
            let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            switch Self.decide(latest: latest, current: currentVersion, staged: stagedUpdate?.version) {
            case .offer:
                // Only the latest release is ever offered, however many came out since the one
                // the user has: `/releases/latest` is one release, and a bundle staged for an
                // older one is dropped, or the next quit would install it first and the next
                // launch would offer the newer one all over again.
                if stagedUpdate != nil { discardStagedUpdate() }
                // A background check must not re-open a dialog the user already
                // dismissed — checks now repeat while the app runs, so without
                // this the same version would interrupt them every few hours.
                // Asking again is always fine when they asked us to look.
                guard userInitiated || latest != declinedVersion else { return }
                await offerUpdate(version: latest, release: release)
            case .alreadyStaged:
                // The latest one is already waiting for the next quit: nothing to offer.
                if userInitiated, let staged = stagedUpdate { showStaged(version: staged.version) }
            case .upToDate:
                if userInitiated { showUpToDate() }
            }
        } catch {
            if userInitiated { showError(error.localizedDescription) }
        }
    }

    // MARK: - Live rule updates

    /// Detection rules ship as their own release asset so they can be fixed
    /// without a new binary — agent TUIs change far faster than we release.
    /// Applied live: the detection poll picks the file up on its next tick.
    /// Failure is silent by design; this runs on every check and must never
    /// interrupt anyone.
    private func refreshDetectionRules(from release: Release) async {
        guard let asset = release.asset(named: "screen-rules.json"),
              let url = trusted(asset.browserDownloadURL)
        else { return }
        // Same defence in depth as the binary, and just as fail-closed: rules
        // that cannot be checked against the release's SHA256SUMS are dropped,
        // not applied unverified. That includes a release with no SHA256SUMS at
        // all — "nothing to verify against" must never read as "verified".
        guard let checksumURL = release.asset(named: "SHA256SUMS")
            .flatMap({ trusted($0.browserDownloadURL) })
        else {
            NSLog("screen rules: release has no SHA256SUMS, ignored")
            return
        }
        do {
            let (data, response) = try await Self.fetchSession.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count <= Self.maxRulesBytes
            else { return }
            guard let expected = try? await expectedSHA(checksumURL, for: "screen-rules.json") else {
                NSLog("screen rules: checksum unavailable, ignored")
                return
            }
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else {
                NSLog("screen rules: checksum mismatch, ignored")
                return
            }
            if appState?.applyFetchedScreenRules(data) == true {
                NSLog("screen rules: updated from release \(release.tagName)")
            }
        } catch {
            NSLog("screen rules: fetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Offer

    /// "What's new" as the dialog's accessory: every point of the new version's
    /// changelog, each opening to its whole text (`ReleaseNotesView`). Nil when the
    /// release carries no notes we can read — then the dialog reads exactly as before.
    private func whatsNew(_ release: Release) -> NSView? {
        guard let body = release.body else { return nil }
        let entries = ReleaseNotes.entries(from: body)
        guard !entries.isEmpty else { return nil }
        return ReleaseNotesView.accessory(for: entries)
    }

    private func offerUpdate(version: String, release: Release) async {
        // Prefer in-app install (zip) when the bundle is replaceable in place;
        // otherwise fall back to opening the DMG for a manual drag-install.
        //
        // The in-app path swaps a running app for downloaded code, so it needs
        // the release's SHA256SUMS to check the bytes against. A release without
        // one is not installed behind the user's back: it takes the manual path,
        // where the browser and Gatekeeper apply their own checks.
        if let zip = release.asset(named: ".zip"),
           let zipURL = trusted(zip.browserDownloadURL),
           let checksumURL = release.asset(named: "SHA256SUMS")
               .flatMap({ trusted($0.browserDownloadURL) }),
           canReplaceBundle {
            let alert = NSAlert()
            alert.messageText = L10n.t(.updateAvailable, version)
            alert.informativeText = L10n.t(.updateInstallBody)
            alert.accessoryView = whatsNew(release)
            // Install & Relaunch first: the top button is the highlighted default, and it is the
            // one that takes the update. The session comes back by itself (no restore question).
            alert.addButton(withTitle: L10n.t(.updateInstallRelaunch))
            alert.addButton(withTitle: L10n.t(.updateInstallOnQuit))
            alert.addButton(withTitle: L10n.t(.updateLater))
            // Awaited from a run-loop callout, never `runModal()` from here: an open
            // alert must not stop libghostty and the control API (see `ModalAlert`).
            // This one appears unattended — on launch and every few hours — and
            // used to freeze every terminal until somebody answered it.
            switch await ModalAlert.run(alert) {
            case .alertFirstButtonReturn:
                Task {
                    await install(
                        zipURL: zipURL, checksumURL: checksumURL,
                        version: version, mode: .now)
                }
            case .alertSecondButtonReturn:
                Task {
                    await install(
                        zipURL: zipURL, checksumURL: checksumURL,
                        version: version, mode: .onQuit)
                }
            default:
                // "Later" means later, not "in six hours".
                declinedVersion = version
            }
        } else {
            let dmg = release.asset(named: ".dmg").flatMap { trusted($0.browserDownloadURL) }
            let target = dmg ?? URL(string: release.htmlURL)
            let alert = NSAlert()
            alert.messageText = L10n.t(.updateAvailable, version)
            alert.informativeText = L10n.t(.updateAvailableBody)
            alert.accessoryView = whatsNew(release)
            alert.addButton(withTitle: L10n.t(.updateDownload))
            alert.addButton(withTitle: L10n.t(.cancel))
            if await ModalAlert.run(alert) == .alertFirstButtonReturn, let target,
               Self.isTrustedDownload(target) {
                NSWorkspace.shared.open(target)
            } else {
                declinedVersion = version
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

    private func install(
        zipURL: URL, checksumURL: URL, version: String, mode: InstallMode
    ) async {
        isInstalling = true
        let panel = InstallProgressPanel()
        panel.show()
        // What this attempt put on disk, so a failure at any step takes it away
        // again instead of leaving tens of megabytes in the temp folder.
        var downloaded: URL?
        var workDir: URL?
        do {
            // 1. Download the zip, showing a live progress bar.
            let file = try await Downloader.download(zipURL) { fraction in
                panel.setDownloading(fraction)
            }
            downloaded = file
            panel.setInstalling()   // switch to an indeterminate spinner

            // 2. Verify its SHA-256 against the release's checksum file (defence
            //    in depth on top of HTTPS + the GitHub-only host allowlist).
            //    Fail-closed: a fetch error or a missing entry aborts the
            //    install — "could not verify" must never become "verified".
            //    Hashing a zip is a few hundred milliseconds of disk and CPU, so
            //    it runs off the main thread, streamed in chunks.
            guard let expected = try? await expectedSHA(checksumURL, for: "Planchette.zip") else {
                throw UpdateError.checksumUnavailable
            }
            let actual = try await Task.detached(priority: .userInitiated) {
                try Self.sha256(ofFileAt: file)
            }.value
            guard actual == expected else { throw UpdateError.checksumMismatch }

            // 3. Extract into a temp dir, locate the new .app, and check that it
            //    is an acceptable build of THIS app before anything is swapped.
            //    `ditto` and `codesign` can take seconds: a main-thread wait
            //    froze the window, including the very progress spinner showing
            //    that work was in flight.
            let target = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(Self.workDirPrefix)\(UUID().uuidString)")
            workDir = target
            let bundleID = Bundle.main.bundleIdentifier
            let current = currentVersion
            let newApp = try await Task.detached(priority: .userInitiated) {
                try Self.extractAndVerify(
                    zip: file, into: target, bundleIdentifier: bundleID,
                    version: version, currentVersion: current)
            }.value
            // The archive has done its job; the verified bundle is what is kept.
            try? FileManager.default.removeItem(at: file)
            downloaded = nil

            switch mode {
            case .now:
                // 4a. Stage the bundle, ask to quit, and only spawn the swap
                //     helper once the quit is certain (applyStagedUpdateOnQuit,
                //     called from applicationShouldTerminate's commit path).
                //     Spawning it before terminate() left a helper waiting on
                //     our pid when the user cancelled the quit dialog — it then
                //     swapped the bundle under whatever later ended the app,
                //     and relaunched it out of nowhere.
                stage(StagedUpdate(version: version, bundlePath: newApp.path))
                pendingRelaunch = true
                panel.close()
                isInstalling = false
                NSApp.terminate(nil)
            case .onQuit:
                // 4b. Keep the verified bundle and swap it at the next quit —
                //     a process boundary the user was going to cross anyway.
                stage(StagedUpdate(version: version, bundlePath: newApp.path))
                panel.close()
                isInstalling = false
                showStaged(version: version)
            }
        } catch {
            if let downloaded { try? FileManager.default.removeItem(at: downloaded) }
            if let workDir { try? FileManager.default.removeItem(at: workDir) }
            panel.close()
            isInstalling = false
            NSLog("update: install of \(version) refused: \(error)")
            showError(error.localizedDescription)
        }
    }

    // MARK: - Staging (install on quit)

    /// True while an "Install & Relaunch" is driving the current quit: the swap
    /// helper should relaunch the app. Reset when the user cancels that quit —
    /// the staged bundle stays (it applies at the next quit), but a later,
    /// ordinary quit must not drag the app back up. Deliberately not persisted.
    private var pendingRelaunch = false

    /// The quit the updater initiated was cancelled (applicationShouldTerminate
    /// returned terminateCancel). Nothing was swapped — the update stays staged.
    func quitCancelled() {
        pendingRelaunch = false
    }

    private func stage(_ update: StagedUpdate) {
        stagedUpdate = update
        let record = ["version": update.version, "bundlePath": update.bundlePath]
        if let data = try? JSONSerialization.data(withJSONObject: record) {
            try? data.write(to: Self.stagingRecordURL, options: .atomic)
        }
    }

    /// Re-adopt a staged update recorded by a previous run — the app may have
    /// been killed rather than quit. The extracted bundle lives in a temp
    /// directory, so it may be gone; then the record is simply dropped.
    func adoptStagedUpdateIfAny() {
        guard let data = try? Data(contentsOf: Self.stagingRecordURL),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let version = record["version"], let path = record["bundlePath"]
        else { return }
        guard FileManager.default.fileExists(atPath: path),
              Self.isStagedBundlePath(path)
        else {
            discardStagedUpdate()
            return
        }
        // Already running it (the swap happened) → nothing staged any more.
        if !Semver.isNewer(version, than: currentVersion) {
            discardStagedUpdate()
            return
        }
        stagedUpdate = StagedUpdate(version: version, bundlePath: path)
    }

    /// A staged bundle is something this updater extracted into the temp folder:
    /// `<tmp>/planchette-update-<id>/<name>.app`. The swap helper copies whatever
    /// the record names over the installed app, so a record that names anything
    /// else — a stale or damaged file, a path edited by hand — is dropped rather
    /// than trusted.
    nonisolated static func isStagedBundlePath(
        _ path: String, temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        let tmp = temporaryDirectory.resolvingSymlinksInPath().path
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        return resolved.pathExtension == "app"
            && resolved.deletingLastPathComponent().deletingLastPathComponent().path == tmp
            && resolved.deletingLastPathComponent().lastPathComponent.hasPrefix(workDirPrefix)
    }

    /// The extraction directory that holds a staged bundle — what the swap helper
    /// removes when it is done — or nil when the path is not one of ours. Resolved,
    /// so a record that goes through a symlink cannot aim the cleanup elsewhere.
    nonisolated static func cleanupDirectory(
        forStagedBundle bundlePath: String,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> String? {
        guard isStagedBundlePath(bundlePath, temporaryDirectory: temporaryDirectory) else {
            return nil
        }
        return URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().path
    }

    func discardStagedUpdate() {
        stagedUpdate = nil
        try? FileManager.default.removeItem(at: Self.stagingRecordURL)
    }

    /// Called from `applicationShouldTerminate` once the user has committed to
    /// quitting — the ONLY place the swap helper is spawned, so a cancelled
    /// quit can never leave one behind. Relaunches only when this quit was
    /// started by "Install & Relaunch"; a staged update applied at an ordinary
    /// quit must not drag the app back up. Best-effort — a failed swap must
    /// never block the quit the user asked for.
    func applyStagedUpdateOnQuit() {
        guard let staged = stagedUpdate else { return }
        defer { discardStagedUpdate() }
        do {
            try swap(newApp: staged.bundlePath, dest: Bundle.main.bundlePath, relaunch: pendingRelaunch)
            NSLog("update: swapping to \(staged.version) on quit (relaunch: \(pendingRelaunch))")
        } catch {
            NSLog("update: staged swap could not start: \(error)")
        }
    }

    // MARK: - Verification (nonisolated: it all runs off the main thread)

    /// A real SHA256SUMS is a few lines. Reading more than this says the response
    /// is not one.
    nonisolated static let maxChecksumFileBytes = 64 * 1024
    /// The detection rules are a few kilobytes of JSON.
    nonisolated static let maxRulesBytes = 256 * 1024
    /// The release metadata (changelog text included) is a few kilobytes.
    nonisolated static let maxReleaseJSONBytes = 1 << 20
    /// Larger than any build of this app will ever be; a bound so a hostile or
    /// broken server cannot fill the disk through the updater.
    nonisolated static let maxDownloadBytes: Int64 = 250 * 1024 * 1024
    /// Every directory the updater creates in the temp folder starts with this,
    /// which is what lets `cleanStaleArtifacts` recognise them as its own.
    nonisolated static let workDirPrefix = "planchette-update-"

    /// Fetch the checksum file and return the hash it lists for `filename`.
    private func expectedSHA(_ url: URL, for filename: String) async throws -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await Self.fetchSession.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= Self.maxChecksumFileBytes
        else { return nil }
        return Self.checksum(in: String(decoding: data, as: UTF8.self), for: filename)
    }

    /// Pure: the hash a `shasum`-style file lists for `filename`.
    ///
    /// Accepts both text (`hash  name`) and binary (`hash *name`) lines — `shasum
    /// -b` writes the `*`, and treating it as part of the name made a perfectly
    /// good file read as "this release has no checksum for the download", which
    /// aborts the install. A line whose first field is not a SHA-256 digest is
    /// not a checksum line and is skipped.
    nonisolated static func checksum(in text: String, for filename: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, let last = parts.last else { continue }
            var name = String(last)
            if name.hasPrefix("*") { name.removeFirst() }
            let digest = String(parts[0]).lowercased()
            guard name == filename, digest.count == 64,
                  digest.allSatisfy(\.isHexDigit)
            else { continue }
            return digest
        }
        return nil
    }

    /// SHA-256 of a file, read in chunks. The whole archive used to be loaded into
    /// memory at once, on the main thread.
    nonisolated static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Unpack `zip` into `workDir` and return the app inside — only if it is an
    /// acceptable build of this app (see `verifyBundle`).
    nonisolated static func extractAndVerify(
        zip: URL, into workDir: URL, bundleIdentifier: String?,
        version: String, currentVersion: String
    ) throws -> URL {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        guard let ditto = Subprocess.run(
            "/usr/bin/ditto", ["-x", "-k", zip.path, workDir.path],
            timeout: 300, stderr: .capture),
              ditto.succeeded
        else {
            NSLog("update: could not unpack the archive")
            throw UpdateError.bundleRejected
        }
        guard let app = firstAppBundle(in: workDir) else { throw UpdateError.noAppInArchive }
        try verifyBundle(
            app, bundleIdentifier: bundleIdentifier,
            version: version, currentVersion: currentVersion)
        return app
    }

    /// Refuse anything that is not a newer, intact build of this very app.
    ///
    /// The checksum proves the download is the file the release published; it says
    /// nothing about what that file *is*. Before the running app is replaced:
    /// - **identity** — the same bundle identifier, so an archive that unpacks to
    ///   some other program is never swapped in under our name;
    /// - **version** — it must match the release tag and be newer than what runs.
    ///   A mismatch is how a rollback to an old build, or an update that offers
    ///   itself again after every install, would look;
    /// - **integrity** — `codesign --verify --deep --strict` must pass. The app
    ///   is ad-hoc signed, so this proves the bundle is complete and unmodified
    ///   since it was signed, not who signed it; that is enough to keep a
    ///   truncated or half-written extraction from replacing a working app with
    ///   one that cannot launch.
    nonisolated static func verifyBundle(
        _ app: URL, bundleIdentifier: String?, version: String, currentVersion: String
    ) throws {
        guard let info = Bundle(url: app)?.infoDictionary else {
            NSLog("update: the downloaded bundle has no readable Info.plist")
            throw UpdateError.bundleRejected
        }
        if let bundleIdentifier, (info["CFBundleIdentifier"] as? String) != bundleIdentifier {
            NSLog("update: the downloaded bundle is not \(bundleIdentifier)")
            throw UpdateError.bundleRejected
        }
        guard let found = info["CFBundleShortVersionString"] as? String,
              found == version, Semver.isNewer(found, than: currentVersion)
        else {
            NSLog("update: the downloaded bundle's version does not match release \(version)")
            throw UpdateError.bundleRejected
        }
        guard let executable = info["CFBundleExecutable"] as? String,
              FileManager.default.isExecutableFile(
                atPath: app.appendingPathComponent("Contents/MacOS/\(executable)").path)
        else {
            NSLog("update: the downloaded bundle has no executable")
            throw UpdateError.bundleRejected
        }
        guard let signature = Subprocess.run(
            "/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path],
            timeout: 120, stderr: .capture),
              signature.succeeded
        else {
            NSLog("update: the downloaded bundle failed codesign verification")
            throw UpdateError.bundleRejected
        }
    }

    nonisolated private static func firstAppBundle(in dir: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.first { $0.pathExtension == "app" }
    }

    /// Remove what earlier runs left in the temp folder. A download, an extracted
    /// bundle and a swap script were never deleted — about 35 MB per update that
    /// stayed until the OS swept the folder. Only our own names, only when a day
    /// old, and never the bundle a staged update is still waiting to install.
    nonisolated static func cleanStaleArtifacts(
        in directory: URL = FileManager.default.temporaryDirectory,
        keeping staged: String? = nil, olderThan age: TimeInterval = 24 * 3600,
        now: Date = Date()
    ) {
        let fm = FileManager.default
        let prefixes = [workDirPrefix, "planchette-dl-", "planchette-swap-"]
        // Compared with symlinks resolved: the temp folder is reached as /var/…
        // and as /private/var/… depending on who asks.
        let keep = staged.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().resolvingSymlinksInPath().path
        }
        guard let items = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for item in items where prefixes.contains(where: { item.lastPathComponent.hasPrefix($0) }) {
            if let keep, item.resolvingSymlinksInPath().path == keep { continue }
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? now
            if now.timeIntervalSince(modified) > age { try? fm.removeItem(at: item) }
        }
    }

    /// The helper script itself, separate from launching it so it can be run — and
    /// tested — against a sandbox. Args: $1 = new .app (extracted), $2 = installed
    /// .app, $3 = log file, $4 = "1" to relaunch afterwards, $5 = the directory $1
    /// was extracted into (removed on the way out, with the script itself, in every
    /// outcome; empty = remove nothing).
    nonisolated static func swapScript(waitingForPID pid: Int32) -> String {
        #"""
        #!/bin/sh
        exec >> "$3" 2>&1
        # Whatever the outcome — including the early exits below — the extracted
        # copy and this script are not needed any more. Only a directory the
        # updater itself created is ever removed.
        trap '[ -n "$5" ] && case "$5" in */\#(Self.workDirPrefix)*) rm -rf "$5" ;; esac; rm -f "$0"' EXIT
        echo "--- swap $(date) : pid \#(pid) ---"
        while kill -0 \#(pid) 2>/dev/null; do sleep 0.2; done
        sleep 0.7   # let the OS release the old bundle after the process exits
        STAGING="$2.new"
        OLD="$2.old"
        rm -rf "$STAGING" "$OLD"
        if /usr/bin/ditto "$1" "$STAGING"; then
            # Move the installed app aside rather than deleting it: if the swap
            # fails after an `rm -rf "$2"`, the machine is left with no app at
            # all. Keeping it until the new one is in place makes that
            # unrecoverable case impossible.
            if [ -d "$2" ] && ! mv "$2" "$OLD"; then
                echo "ERROR: could not move the installed app aside; nothing changed"
                rm -rf "$STAGING"
                exit 0
            fi
            if mv "$STAGING" "$2"; then
                /usr/bin/xattr -dr com.apple.quarantine "$2" 2>/dev/null
                rm -rf "$OLD"
                echo "swap ok -> $2"
            else
                echo "ERROR: mv staging into place failed; restoring previous version"
                [ -d "$OLD" ] && mv "$OLD" "$2"
                rm -rf "$STAGING"
            fi
        else
            echo "ERROR: ditto to staging failed; app left untouched"
            rm -rf "$STAGING"
        fi
        [ "$4" = "1" ] && open "$2"
        exit 0
        """#
    }

    /// Writes a helper script that waits for us to fully quit, then swaps the
    /// installed bundle for the new one — and relaunches only when asked, so a
    /// staged update applied at quit does not drag the app back up. The child
    /// survives our
    /// termination. The new build is staged next to the destination and only
    /// swapped in once the copy fully succeeds, so a failed copy can never leave
    /// the app missing. All output is logged for diagnosis.
    /// Args: $1 = new .app (extracted), $2 = installed .app, $3 = log file,
    /// $4 = "1" to relaunch afterwards, $5 = the directory $1 was extracted into
    /// (removed on the way out, with the script itself, in every outcome).
    private func swap(newApp: String, dest: String, relaunch: Bool) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("planchette-update.log")
        // One run of history is plenty; the log is appended to on every update.
        if let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? Int,
           size > 100_000 {
            try? FileManager.default.removeItem(at: logURL)
        }
        // The script removes a directory on its way out, so WHICH directory is decided
        // here, on the resolved path, with the same test the adoption of a staged
        // update uses — not by a pattern in the script, which matched any path that
        // merely contained "planchette-update-" and so could be pointed at a user's
        // folder by a damaged or edited record. A bundle that is not one of ours is
        // not swapped in at all.
        guard let workDir = Self.cleanupDirectory(forStagedBundle: newApp) else {
            NSLog("update: refusing to swap in a bundle that is not a staged extraction")
            throw UpdateError.bundleRejected
        }
        let resolvedApp = URL(fileURLWithPath: newApp).resolvingSymlinksInPath().path
        let script = Self.swapScript(waitingForPID: pid)
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("planchette-swap-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [scriptURL.path, resolvedApp, dest, logURL.path, relaunch ? "1" : "0", workDir]
        try task.run()   // detached; keeps running after we terminate
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

    private func showStaged(version: String) {
        let alert = NSAlert()
        alert.messageText = L10n.t(.updateStagedTitle, version)
        alert.informativeText = L10n.t(.updateStagedBody)
        alert.addButton(withTitle: L10n.t(.ok))
        ModalAlert.show(alert)
    }

    private func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = L10n.t(.updateUpToDate)
        alert.informativeText = L10n.t(.updateCurrentVersion, currentVersion)
        ModalAlert.show(alert)
    }

    private func showNoReleases() {
        let alert = NSAlert()
        alert.messageText = L10n.t(.updateNoReleases)
        alert.informativeText = L10n.t(.updateCurrentVersion, currentVersion)
        ModalAlert.show(alert)
    }

    private func showError(_ detail: String) {
        let alert = NSAlert()
        alert.messageText = L10n.t(.updateFailed)
        alert.informativeText = detail
        ModalAlert.show(alert)
    }
}

/// Redirects of an updater request must stay on GitHub's hosts over HTTPS. The
/// allowlist used to be checked on the first URL only — and `URLSession` follows
/// a redirect anywhere by default, so a response could hand the download to a
/// host nobody had vetted. Refusing makes the 3xx response the final answer, and
/// callers treat anything but 200 as a failure.
class TrustedRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, UpdateService.isTrustedDownload(url) else {
            NSLog("update: refused a redirect to \(request.url?.host ?? "an unknown host")")
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// Downloads a file while reporting progress (0…1) on the main queue.
///
/// Bounded three ways, because the bytes come from the network: redirects stay on
/// GitHub (`TrustedRedirects`), the final answer must be a 200 (an error page used
/// to be saved as if it were the archive), and the transfer is cut off past
/// `UpdateService.maxDownloadBytes`.
final class Downloader: TrustedRedirects, URLSessionDownloadDelegate {
    private var continuation: CheckedContinuation<URL, Error>?
    private let onProgress: (Double) -> Void
    private var moved: URL?
    /// Why *we* stopped the transfer. It wins over the "cancelled" error
    /// `URLSession` then reports, which would hide the reason.
    private var failure: Error?

    private let maxBytes: Int64

    private init(maxBytes: Int64, onProgress: @escaping (Double) -> Void) {
        self.maxBytes = maxBytes
        self.onProgress = onProgress
        super.init()
    }

    static func download(
        _ url: URL, maxBytes: Int64 = UpdateService.maxDownloadBytes,
        onProgress: @escaping (Double) -> Void
    ) async throws -> URL {
        try await Downloader(maxBytes: maxBytes, onProgress: onProgress).run(url)
    }

    private func run(_ url: URL) async throws -> URL {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60       // no bytes for a minute
        configuration.timeoutIntervalForResource = 30 * 60 // and never an open-ended transfer
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let limit = maxBytes
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit {
            NSLog("update: download exceeds \(limit) bytes, cancelled")
            failure = UpdateService.UpdateError.downloadFailed
            downloadTask.cancel()
            return
        }
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.onProgress(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
            NSLog("update: download answered HTTP "
                + "\((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)")
            failure = UpdateService.UpdateError.downloadFailed
            return
        }
        // The temp file is removed when this returns, so move it synchronously.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("planchette-dl-\(UUID().uuidString).zip")
        try? FileManager.default.moveItem(at: location, to: dest)
        moved = dest
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let reason: Error? = failure ?? error
        if let reason {
            // Whatever was already moved into place is no use to anyone.
            if let moved { try? FileManager.default.removeItem(at: moved) }
            continuation?.resume(throwing: reason)
        } else if let moved {
            continuation?.resume(returning: moved)
        } else {
            continuation?.resume(throwing: URLError(.cannotOpenFile))
        }
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
