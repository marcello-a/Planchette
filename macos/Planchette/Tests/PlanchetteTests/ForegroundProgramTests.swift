import XCTest
@testable import Planchette

/// A program that runs in front of a durable shell — `k9s`, a `kubectl port-forward` — is work in
/// progress, not a free terminal, and it is what names a terminal that has nothing better to say.
final class ForegroundProgramTests: XCTestCase {
    // MARK: What runs in front

    func testAProgramInFrontIsNamed() {
        for program in ["k9s", "kubectl", "node", "vim", "ssh", "psql", "tail"] {
            XCTAssertEqual(Durable.foregroundProgram(paneCommand: program, agentLive: false), program)
        }
    }

    func testAShellAtItsPromptRunsNothing() {
        for shell in ["zsh", "-zsh", "bash", "fish", "sh"] {
            XCTAssertNil(Durable.foregroundProgram(paneCommand: shell, agentLive: false), shell)
        }
        XCTAssertNil(Durable.foregroundProgram(paneCommand: nil, agentLive: false), "tmux has no pane for it")
        XCTAssertNil(Durable.foregroundProgram(paneCommand: "  ", agentLive: false))
    }

    // An agent speaks through its hooks; its process name is no name for the terminal.
    func testAnAgentIsNoProgram() {
        XCTAssertNil(Durable.foregroundProgram(paneCommand: "node", agentLive: true), "Claude from npm, hooks live")
        // The native install runs a versioned file: the kernel calls the process by its version,
        // also before the first hook — on a real machine 26 of 28 panes read like this.
        for version in ["2.1.323", "2.1.332", "10.0"] {
            XCTAssertNil(Durable.foregroundProgram(paneCommand: version, agentLive: false), version)
        }
        XCTAssertNil(Durable.foregroundProgram(paneCommand: "claude", agentLive: false))
        XCTAssertNil(Durable.foregroundProgram(paneCommand: "codex", agentLive: false))
    }

    // MARK: The state it implies

    func testAProgramThatAppearsMakesTheTerminalRun() {
        for state in [AttentionState.free, .ready, .error] {
            XCTAssertEqual(
                AttentionState.forForegroundProgram(
                    state, programAppeared: true, atPrompt: false, raisedByProgram: false),
                .running, "\(state)")
        }
    }

    // A question is on the screen; it stays until it is answered.
    func testAQuestionStays() {
        XCTAssertNil(AttentionState.forForegroundProgram(
            .waiting, programAppeared: true, atPrompt: false, raisedByProgram: false))
        XCTAssertNil(AttentionState.forForegroundProgram(
            .running, programAppeared: true, atPrompt: false, raisedByProgram: false))
    }

    // "Mark as free" on a terminal whose port-forward keeps running stays what you decided.
    func testAProgramThatKeepsRunningIsNoNews() {
        XCTAssertNil(AttentionState.forForegroundProgram(
            .free, programAppeared: false, atPrompt: false, raisedByProgram: true))
    }

    // A shell without OSC 133 `D` never says the program ended: the pane does.
    func testBackAtThePromptARaisedRunningIsFree() {
        XCTAssertEqual(
            AttentionState.forForegroundProgram(
                .running, programAppeared: false, atPrompt: true, raisedByProgram: true),
            .free)
    }

    // A `running` a hook or the screen set is theirs to end — not the pane's.
    func testTheRuleEndsOnlyWhatItRaised() {
        XCTAssertNil(AttentionState.forForegroundProgram(
            .running, programAppeared: false, atPrompt: true, raisedByProgram: false))
        // The pane shows an agent, not a prompt: nothing to give back yet.
        XCTAssertNil(AttentionState.forForegroundProgram(
            .running, programAppeared: false, atPrompt: false, raisedByProgram: true))
        // `D` already named the result; the pane does not overwrite it.
        XCTAssertNil(AttentionState.forForegroundProgram(
            .ready, programAppeared: false, atPrompt: true, raisedByProgram: true))
    }

    // MARK: The symbol

    // The robot means an agent at work; a terminal running `k9s` shows `>_` in the running colour.
    func testARunningProgramShowsTheShellMark() {
        XCTAssertTrue(AttentionState.showsProgramMark(state: .running, programInFront: true))
        XCTAssertFalse(AttentionState.showsProgramMark(state: .running, programInFront: false), "an agent at work")
        for state in [AttentionState.free, .ready, .waiting, .error] {
            XCTAssertFalse(AttentionState.showsProgramMark(state: state, programInFront: true), "\(state)")
        }
    }

    // MARK: The name

    // The program names the tab only where nothing better is known — before "free".
    func testTheProgramNamesATerminalWithNothingElseToSay() {
        let inputs = TabNaming.Inputs(reportedTitle: "k9s", fallback: "free")
        for source in [TabName.summary, .lastPrompt, .firstPrompt, .ticketAndPrompt] {
            XCTAssertEqual(TabNaming.name(inputs, source: source), "k9s", "\(source)")
        }
        var withPrompt = inputs
        withPrompt.lastPrompt = "Fix the cart"
        XCTAssertEqual(TabNaming.name(withPrompt, source: .lastPrompt), "Fix the cart")
    }
}

/// A database client, or a tunnel to a database, shows a database instead of `>_`.
final class DatabaseProgramTests: XCTestCase {
    func testADatabaseClientIsKnownByItsName() {
        for client in ["psql", "pgcli", "mysql", "redis-cli", "mongosh", "mongo", "usql"] {
            XCTAssertTrue(Durable.isDatabase(command: client, arguments: nil), client)
        }
    }

    // A port-forward is only `kubectl` by name: the service or the port in its command line decides.
    func testAPortForwardToADatabaseIsADatabase() {
        for args in [
            "kubectl port-forward svc/postgres 5432:5432",
            "kubectl -n shop port-forward svc/checkout-db 15432:5432",
            "kubectl port-forward pod/cache-0 16379:6379",
            "kubectl port-forward deploy/api 3306",
            "kubectl port-forward svc/mongodb 27017",
            "kubectl port-forward svc/search 9200:9200",
            "kubectl port-forward svc/orders-database 8000:80",
        ] {
            XCTAssertTrue(Durable.isDatabase(command: "kubectl", arguments: args), args)
        }
        XCTAssertTrue(Durable.isDatabase(command: "ssh", arguments: "ssh -N -L 3306:db.internal:3306 bastion"))
        XCTAssertTrue(Durable.isDatabase(command: "cloud-sql-proxy", arguments: nil))
    }

    func testOtherProgramsAreNoDatabase() {
        XCTAssertFalse(Durable.isDatabase(command: "k9s", arguments: "k9s"))
        XCTAssertFalse(Durable.isDatabase(command: "kubectl", arguments: "kubectl port-forward svc/web 8080:80"))
        XCTAssertFalse(Durable.isDatabase(command: "kubectl", arguments: "kubectl logs -f svc/postgres"),
                       "not a tunnel")
        XCTAssertFalse(Durable.isDatabase(command: "kubectl", arguments: "kubectl port-forward svc/web 15432:8080"),
                       "a port that only contains 5432")
        XCTAssertFalse(Durable.isDatabase(command: "vim", arguments: "vim redis.conf"))
        XCTAssertFalse(Durable.isDatabase(command: "ssh", arguments: "ssh db.internal"), "a login, not a tunnel")
        XCTAssertFalse(Durable.isDatabase(command: "kubectl", arguments: nil))
    }

    func testOnlyARunningProgramShowsTheDatabase() {
        XCTAssertTrue(AttentionState.showsDatabaseMark(state: .running, programInFront: true, isDatabase: true))
        XCTAssertFalse(AttentionState.showsDatabaseMark(state: .running, programInFront: true, isDatabase: false))
        XCTAssertFalse(AttentionState.showsDatabaseMark(state: .free, programInFront: true, isDatabase: true))
        XCTAssertFalse(AttentionState.showsDatabaseMark(state: .running, programInFront: false, isDatabase: true))
    }

    func testPanesCarryTheShellPid() {
        let id = UUID(uuidString: "0A1B2C3D-0000-4000-8000-0000000000AB")!
        let panes = Durable.parsePanes("""
            planchette-0a1b2c3d-0000-4000-8000-0000000000ab 4242 kubectl
            mywork 1 vim
            planchette-0a1b2c3d-0000-4000-8000-0000000000cd notapid zsh
            """)
        XCTAssertEqual(panes, [id: Durable.Pane(pid: 4242, command: "kubectl")])
    }

    func testChildArgumentsAreTheShellsChildren() {
        let out = """
              4300  4242 kubectl port-forward svc/postgres 5432:5432
              4301  4242 grep forward
              4400  4343 node server.js
              4242     1 -zsh
            """
        XCTAssertEqual(Durable.parseChildArguments(out, parents: [4242]),
                       [4242: "kubectl port-forward svc/postgres 5432:5432 | grep forward"])
    }
}
