import XCTest
@testable import Planchette

// The native hook forwarder (hook/planchette-hook.c) and how the app installs it.
//
// The full differential table — every event, binary-ish payloads, 5 MB, every pointer
// variant, stalled and closing apps, with time bounds — is scripts/test-hook-helper.sh,
// which CI runs next to this suite. These tests build the helper exactly as the app
// bundle ships it and keep the essentials inside `swift test`: the same bytes as the
// script, the refusals, the pointer, a stalled app, and the install, upgrade and
// downgrade of the forwarder. No time limits (AGENTS.md, "Tests must survive a slow
// machine"): order and outcome only.

private let repoRoot: URL = {
    // …/macos/Planchette/Tests/PlanchetteTests/NativeHookTests.swift
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
}()

/// The helper, built once per test run by hook/build-hook-helper.sh — the flags
/// (every warning an error) and the slices (arm64 + x86_64) of the shipped one.
private enum BuiltHelper {
    static let result: Result<String, Error> = {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plt-helper-\(UUID().uuidString)")
        let output = directory.appendingPathComponent("planchette-hook").path
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(error)
        }
        let script = repoRoot.appendingPathComponent("hook/build-hook-helper.sh").path
        guard let build = Subprocess.run("/bin/sh", [script, output], timeout: 600, stderr: .capture),
              build.succeeded
        else {
            return .failure(NSError(domain: "BuiltHelper", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "hook/build-hook-helper.sh failed",
            ]))
        }
        return .success(output)
    }()

    static func path() throws -> String { try result.get() }
}

/// What the script's contract says must arrive: the event (NUL bytes dropped, trailing
/// newlines removed, `{}` when nothing is left) wrapped raw with session and label.
private func expectedEvent(session: String, agent: String, stdin: Data) -> Data {
    var payload = Data(stdin.filter { $0 != 0 })
    while payload.last == UInt8(ascii: "\n") { payload.removeLast() }
    if payload.isEmpty { payload = Data("{}".utf8) }
    var event = Data(#"{"planchette_session":""#.utf8)
    event.append(Data(session.utf8))
    event.append(Data(#"","agent":""#.utf8))
    event.append(Data(agent.utf8))
    event.append(Data(#"","event":"#.utf8))
    event.append(payload)
    event.append(Data("}".utf8))
    return event
}

/// A HOME with nothing in it (or only a socket pointer), so the developer's real
/// ~/.planchette/socket can never be picked up.
private func makeHome(_ test: XCTestCase, pointingAt socket: String? = nil) throws -> String {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("plt-home-\(UUID().uuidString)")
    let dir = home.appendingPathComponent(".planchette")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let socket {
        try (socket + "\n").write(to: dir.appendingPathComponent("socket"), atomically: true, encoding: .utf8)
    }
    test.addTeardownBlock { try? FileManager.default.removeItem(at: home) }
    return home.path
}

private func runForwarder(
    _ executable: String, _ arguments: [String], env: [String: String], stdin: Data
) throws -> Subprocess.Output {
    var environment = ["PATH": "/usr/bin:/bin"]
    environment.merge(env) { $1 }
    return try XCTUnwrap(Subprocess.run(
        executable, arguments, timeout: 300, stderr: .capture, input: stdin, environment: environment))
}

// MARK: - The helper does what the script does

final class NativeHookForwarderTests: XCTestCase {
    private var script: String { repoRoot.appendingPathComponent("hook/planchette-hook").path }

    /// Run `forwarder` against a fresh fake app and return what the app received.
    private func delivery(_ forwarder: String, session: String, args: [String], stdin: Data) throws -> Data {
        let app = try FakeApp()
        let result = try runForwarder(
            forwarder, args,
            env: ["PLANCHETTE_SESSION": session, "PLANCHETTE_SOCKET": app.path, "HOME": try makeHome(self)],
            stdin: stdin)
        app.waitUntilServed()
        XCTAssertTrue(result.succeeded, "\(forwarder) must exit 0 (status \(result.status))")
        XCTAssertTrue(result.stdout.isEmpty, "\(forwarder) printed \(result.stdoutString)")
        return app.received
    }

    // The core promise: for the same input, the app receives the same bytes from the
    // helper as from the script, and both are what the contract says.
    func testTheHelperSendsTheScriptsBytes() throws {
        let helper = try BuiltHelper.path()
        let inputs: [(args: [String], stdin: Data)] = [
            (["claude"], Data(#"{"hook_event_name":"Stop","session_id":"abc"}"#.utf8)),
            (["codex"], Data(#"{"hook_event_name":"SessionStart","source":"startup"}"#.utf8)),
            (["claude"], Data(#"{"hook_event_name":"UserPromptSubmit","prompt":"Grüße 👋🏽 日本語"}"#.utf8)),
            (["claude"], Data("{\"a\":1}\n\n\n".utf8)),
            (["claude"], Data("{\"a\":\"x\0y\"}".utf8)),
            (["claude"], Data()),
            ([], Data(#"{"hook_event_name":"Notification"}"#.utf8)),
            ([""], Data(#"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#.utf8)),
        ]
        for input in inputs {
            let session = UUID().uuidString
            let agent = input.args.first.flatMap { $0.isEmpty ? nil : $0 } ?? "claude"
            let want = expectedEvent(session: session, agent: agent, stdin: input.stdin)
            let fromScript = try delivery(script, session: session, args: input.args, stdin: input.stdin)
            let fromHelper = try delivery(helper, session: session, args: input.args, stdin: input.stdin)
            XCTAssertEqual(fromScript, want, "script, \(input)")
            XCTAssertEqual(fromHelper, want, "helper, \(input)")
        }
    }

    func testABigEventArrivesWhole() throws {
        let helper = try BuiltHelper.path()
        let session = UUID().uuidString
        var stdin = Data(#"{"hook_event_name":"UserPromptSubmit","prompt":""#.utf8)
        stdin.append(Data(repeating: UInt8(ascii: "x"), count: 2 << 20))
        stdin.append(Data(#""}"#.utf8))
        let received = try delivery(helper, session: session, args: ["claude"], stdin: stdin)
        XCTAssertEqual(received, expectedEvent(session: session, agent: "claude", stdin: stdin))
    }

    func testTheHelperIsANoOpOutsideAPlanchetteTerminal() throws {
        let helper = try BuiltHelper.path()
        let app = try FakeApp()
        let result = try runForwarder(
            helper, ["claude"], env: ["PLANCHETTE_SOCKET": app.path, "HOME": try makeHome(self)],
            stdin: Data("{}".utf8))
        app.stop()
        app.waitUntilServed()
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(app.received.isEmpty, "no session, no event")
        XCTAssertTrue(result.stdout.isEmpty && result.stderr.isEmpty)
    }

    func testTheHelperIsQuietWhenNoAppListens() throws {
        let helper = try BuiltHelper.path()
        let result = try runForwarder(
            helper, ["claude"],
            env: ["PLANCHETTE_SESSION": UUID().uuidString,
                  "PLANCHETTE_SOCKET": "/tmp/plt-gone-\(UUID().uuidString.prefix(8)).sock",
                  "HOME": try makeHome(self)],
            stdin: Data(#"{"hook_event_name":"Stop"}"#.utf8))
        XCTAssertTrue(result.succeeded, "a missing app must never fail the agent")
        XCTAssertTrue(result.stdout.isEmpty && result.stderr.isEmpty)
    }

    // The same race the script guards against (HookScriptTests): a link to our own
    // live socket could be swapped for another listener before the connect.
    func testTheHelperRefusesASymlinkToOurOwnSocket() throws {
        let helper = try BuiltHelper.path()
        let app = try FakeApp()
        let link = "/tmp/plt-link-\(UUID().uuidString.prefix(8)).sock"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: app.path)
        defer { unlink(link) }
        let result = try runForwarder(
            helper, ["claude"],
            env: ["PLANCHETTE_SESSION": UUID().uuidString, "PLANCHETTE_SOCKET": link,
                  "HOME": try makeHome(self, pointingAt: link)],
            stdin: Data("{}".utf8))
        app.stop()
        app.waitUntilServed()
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(app.received.isEmpty, "must not connect through a symlink")
    }

    // A durable terminal's own socket is gone: the event reaches the running app
    // through the pointer.
    func testTheHelperReachesTheAppThroughThePointer() throws {
        let helper = try BuiltHelper.path()
        let app = try FakeApp()
        let session = UUID().uuidString
        let stdin = Data(#"{"hook_event_name":"Stop"}"#.utf8)
        let result = try runForwarder(
            helper, ["claude"],
            env: ["PLANCHETTE_SESSION": session,
                  "PLANCHETTE_SOCKET": "/tmp/plt-gone-\(UUID().uuidString.prefix(8)).sock",
                  "HOME": try makeHome(self, pointingAt: app.path)],
            stdin: stdin)
        app.waitUntilServed()
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(app.received, expectedEvent(session: session, agent: "claude", stdin: stdin))
    }

    // An app that accepted the event but never answers does not hold the agent's tool
    // call: the helper ends while the app still holds the connection — with an event
    // too big for the socket buffer as well, where the script's `nc` would wait for good.
    func testTheHelperEndsWhileAStalledAppStillHoldsTheConnection() throws {
        let helper = try BuiltHelper.path()
        for size in [16, 1 << 20] {
            let app = try StalledApp()
            let result = try runForwarder(
                helper, ["claude"],
                env: ["PLANCHETTE_SESSION": UUID().uuidString, "PLANCHETTE_SOCKET": app.path,
                      "HOME": try makeHome(self)],
                stdin: Data(repeating: UInt8(ascii: "x"), count: size))
            // Order, not time: the app lets go only after the helper ended.
            app.release()
            XCTAssertFalse(result.timedOut, "the helper ended before the app let go (\(size) bytes)")
            XCTAssertTrue(result.succeeded)
            XCTAssertTrue(app.accepted)
        }
    }
}

// MARK: - Installing the forwarder: helper, script, upgrade, downgrade

final class HookForwarderDeployTests: XCTestCase {
    private var sandbox: URL!
    private var dest: URL { sandbox.appendingPathComponent("home/.planchette/planchette-hook") }
    private let script = Data("#!/bin/sh\n# the script\nexit 0\n".utf8)
    private let helper = Data([0xCF, 0xFA, 0xED, 0xFE] + Array(repeating: 0x42, count: 4096))

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("plt-fwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// A packaged app: the script in Resources, the helper (when given) in Helpers.
    private func makeApp(helper: Data?, script: Data? = nil, name: String = "Planchette.app") throws -> Bundle {
        let app = sandbox.appendingPathComponent(name)
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try (script ?? self.script).write(to: resources.appendingPathComponent("planchette-hook"))
        if let helper {
            let helpers = app.appendingPathComponent("Contents/Helpers")
            try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
            let url = helpers.appendingPathComponent("planchette-hook")
            try helper.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return try XCTUnwrap(Bundle(url: app))
    }

    private func put(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Nothing but the forwarder is left in its folder: no staged copy survives.
    private func assertNoLeftovers(file: StaticString = #filePath, line: UInt = #line) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path)
        XCTAssertEqual(names, ["planchette-hook"], file: file, line: line)
    }

    private func mode(_ url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    }

    func testAHelperThatRunsIsInstalled() throws {
        let app = try makeApp(helper: helper)
        var probed: [URL] = []
        let installed = try HookInstaller.deployHook(from: app, to: dest) { probed.append($0); return true }
        XCTAssertEqual(installed, .native)
        XCTAssertEqual(try Data(contentsOf: dest), helper)
        XCTAssertEqual(try mode(dest), 0o755)
        // The probe ran the staged copy beside the destination, never the destination.
        XCTAssertEqual(probed.count, 1)
        XCTAssertNotEqual(probed.first?.path, dest.path)
        XCTAssertEqual(probed.first?.deletingLastPathComponent().path, dest.deletingLastPathComponent().path)
        try assertNoLeftovers()
    }

    // Quarantine, a broken signature, a CPU the helper was not built for: whatever
    // keeps it from running, the script is installed and the hooks keep working.
    func testAHelperThatDoesNotRunLeavesTheScript() throws {
        let app = try makeApp(helper: helper)
        let installed = try HookInstaller.deployHook(from: app, to: dest) { _ in false }
        XCTAssertEqual(installed, .script)
        XCTAssertEqual(try Data(contentsOf: dest), script)
        XCTAssertEqual(try mode(dest), 0o755)
        try assertNoLeftovers()
    }

    // An existing user updates: the script under the same name becomes the helper, and
    // nothing else has to change.
    func testAnUpdateReplacesTheScriptWithTheHelper() throws {
        try put(script, at: dest)
        let installed = try HookInstaller.deployHook(from: try makeApp(helper: helper), to: dest) { _ in true }
        XCTAssertEqual(installed, .native)
        XCTAssertEqual(try Data(contentsOf: dest), helper)
        try assertNoLeftovers()
    }

    // A downgrade: an older app carries no helper and puts its script back — both
    // through this installer and through the plain copy every older version runs.
    func testADowngradePutsTheScriptBack() throws {
        let older = try makeApp(helper: nil, script: Data("#!/bin/sh\n# older\n".utf8), name: "Older.app")
        try put(helper, at: dest)
        XCTAssertEqual(try HookInstaller.deployHook(from: older, to: dest) { _ in XCTFail("no helper to probe"); return true },
                       .script)
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "#!/bin/sh\n# older\n")

        try put(helper, at: dest)
        try HookInstaller.deploy("planchette-hook", to: dest, from: older)
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "#!/bin/sh\n# older\n")
        try assertNoLeftovers()
    }

    // The command in the agents' configs names the forwarder, not what it is: the
    // same path for the helper and the script, so neither an update nor a downgrade
    // rewrites settings.json, and an older app still recognizes it as its own.
    func testTheConfiguredCommandIsTheSameForBothForwarders() throws {
        let command = HookInstaller.hookCommand(for: .claude)
        XCTAssertEqual(command, HookInstaller.hookScriptURL.path + " claude")
        XCTAssertTrue(HookInstaller.isPlanchetteCommand(command))

        let settings = sandbox.appendingPathComponent("settings.json")
        try HookInstaller.mergeSettings(at: settings, hookCmd: command)
        let wired = try Data(contentsOf: settings)
        let before = try FileManager.default.attributesOfItem(atPath: settings.path)[.systemFileNumber] as? Int
        try HookInstaller.deployHook(from: try makeApp(helper: helper), to: dest) { _ in true }
        try HookInstaller.mergeSettings(at: settings, hookCmd: command)
        XCTAssertEqual(try Data(contentsOf: settings), wired)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: settings.path)[.systemFileNumber] as? Int,
                       before, "settings.json is not rewritten by the switch")
    }

    func testAnInstalledHelperIsNotProbedAgain() throws {
        try put(helper, at: dest)
        let installed = try HookInstaller.deployHook(from: try makeApp(helper: helper), to: dest) { _ in
            XCTFail("an installed helper is not run again")
            return false
        }
        XCTAssertEqual(installed, .native)
        XCTAssertEqual(try Data(contentsOf: dest), helper)
    }

    // A helper that failed its probe last launch is tried again: the next start may be
    // the one where it runs (a quarantine flag cleared, a signature fixed).
    func testARefusedHelperIsTriedAgainNextLaunch() throws {
        let app = try makeApp(helper: helper)
        XCTAssertEqual(try HookInstaller.deployHook(from: app, to: dest) { _ in false }, .script)
        XCTAssertEqual(try HookInstaller.deployHook(from: app, to: dest) { _ in true }, .native)
        XCTAssertEqual(try Data(contentsOf: dest), helper)
    }

    // A rename, not an overwrite: an agent that started the old forwarder a moment
    // ago keeps reading the old file, and a signed binary is never rewritten in place.
    func testTheForwarderIsReplacedByANewFile() throws {
        try put(script, at: dest)
        let reader = try FileHandle(forReadingFrom: dest)
        defer { try? reader.close() }
        let before = try FileManager.default.attributesOfItem(atPath: dest.path)[.systemFileNumber] as? Int
        try HookInstaller.deployHook(from: try makeApp(helper: helper), to: dest) { _ in true }
        let after = try FileManager.default.attributesOfItem(atPath: dest.path)[.systemFileNumber] as? Int
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(try reader.readToEnd(), script, "the open file is still the old one")
    }

    func testADevRunInstallsNothing() throws {
        let folder = sandbox.appendingPathComponent("debug")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Contents/Helpers"),
                                                withIntermediateDirectories: true)
        try put(helper, at: folder.appendingPathComponent("Contents/Helpers/planchette-hook"))
        let bare = try XCTUnwrap(Bundle(url: folder))
        XCTAssertNil(HookInstaller.bundledHelper(in: bare))
        XCTAssertEqual(try HookInstaller.deployHook(from: bare, to: dest) { _ in true }, .none)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testAHelperThatIsNotExecutableIsNotUsed() throws {
        let app = try makeApp(helper: helper)
        let url = app.bundleURL.appendingPathComponent("Contents/Helpers/planchette-hook")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertNil(HookInstaller.bundledHelper(in: app))
        XCTAssertEqual(try HookInstaller.deployHook(from: app, to: dest) { _ in true }, .script)
    }

    // The test run is a dev run: the real installer finds nothing to deploy.
    func testThisProcessHasNoHelperToDeploy() {
        XCTAssertNil(HookInstaller.bundledHelper())
    }
}

// MARK: - The probe that decides between helper and script

final class HookHelperProbeTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("plt-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func executable(_ name: String, _ content: Data) throws -> URL {
        let url = sandbox.appendingPathComponent(name)
        try content.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testTheBuiltHelperRuns() throws {
        XCTAssertTrue(HookInstaller.helperRuns(URL(fileURLWithPath: try BuiltHelper.path())))
    }

    // What Gatekeeper does to a binary it refuses: SIGKILL at exec.
    func testAHelperKilledAtStartDoesNotRun() throws {
        let killed = try executable("killed", Data("#!/bin/sh\nkill -9 $$\n".utf8))
        XCTAssertFalse(HookInstaller.helperRuns(killed))
    }

    // A file the kernel cannot execute (a CPU it was not built for, a truncated copy).
    func testAFileThatCannotBeExecutedDoesNotRun() throws {
        let garbage = try executable("garbage", Data([0xCF, 0xFA, 0xED, 0xFE] + Array(repeating: 0, count: 64)))
        XCTAssertFalse(HookInstaller.helperRuns(garbage))
    }

    func testAHelperThatFailsDoesNotRun() throws {
        let failing = try executable("failing", Data("#!/bin/sh\nexit 3\n".utf8))
        XCTAssertFalse(HookInstaller.helperRuns(failing))
    }

    // The probe replaces the environment: a dev run started from a Planchette terminal
    // has a real PLANCHETTE_SESSION, and the probe must not send that terminal an event.
    func testTheProbeSendsNoEventEvenInsideAPlanchetteTerminal() throws {
        let helper = URL(fileURLWithPath: try BuiltHelper.path())
        let app = try FakeApp()
        let saved = ["PLANCHETTE_SESSION", "PLANCHETTE_SOCKET"].map { ($0, ProcessInfo.processInfo.environment[$0]) }
        setenv("PLANCHETTE_SESSION", UUID().uuidString, 1)
        setenv("PLANCHETTE_SOCKET", app.path, 1)
        defer {
            for (key, value) in saved {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        XCTAssertTrue(HookInstaller.helperRuns(helper))
        app.stop()
        app.waitUntilServed()
        XCTAssertTrue(app.received.isEmpty, "the probe must not reach a socket")
    }

    // End to end: the real helper in a packaged app, the real probe, a real install.
    func testARealHelperIsInstalledAndRuns() throws {
        let app = sandbox.appendingPathComponent("Planchette.app")
        let helpers = app.appendingPathComponent("Contents/Helpers")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: try BuiltHelper.path(),
                                         toPath: helpers.appendingPathComponent("planchette-hook").path)
        try FileManager.default.copyItem(at: repoRoot.appendingPathComponent("hook/planchette-hook"),
                                         to: resources.appendingPathComponent("planchette-hook"))
        let dest = sandbox.appendingPathComponent("home/.planchette/planchette-hook")

        XCTAssertEqual(try HookInstaller.deployHook(from: try XCTUnwrap(Bundle(url: app)), to: dest), .native)
        XCTAssertEqual(try Data(contentsOf: dest), try Data(contentsOf: URL(fileURLWithPath: try BuiltHelper.path())))

        let fake = try FakeApp()
        let session = UUID().uuidString
        let stdin = Data(#"{"hook_event_name":"Stop"}"#.utf8)
        let result = try runForwarder(
            dest.path, ["claude"],
            env: ["PLANCHETTE_SESSION": session, "PLANCHETTE_SOCKET": fake.path, "HOME": try makeHome(self)],
            stdin: stdin)
        fake.waitUntilServed()
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(fake.received, expectedEvent(session: session, agent: "claude", stdin: stdin))
    }
}
