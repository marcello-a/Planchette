import XCTest
@testable import Planchette

/// A durable terminal runs tmux, which hides from Planchette both where a command ends and
/// that the shell ended. These are the two rules that bring both back.
final class DurableStateTests: XCTestCase {
    private let id = UUID(uuidString: "0A1B2C3D-0000-4000-8000-0000000000AB")!
    private let other = UUID(uuidString: "0A1B2C3D-0000-4000-8000-0000000000CD")!

    // MARK: Where a command ends

    func testAZshGetsTheShimAsItsZDOTDIR() {
        let env = Durable.shellMarksEnvironment(shell: "/bin/zsh", userZDOTDIR: nil, zshDirectory: "/shim")
        XCTAssertEqual(env.map(\.key), ["ZDOTDIR"])
        XCTAssertEqual(env.first?.value, "/shim")
    }

    // The shim puts the user's ZDOTDIR back; without it, their .zshrc would never load.
    func testTheUsersOwnZDOTDIRTravelsAlong() {
        let env = Durable.shellMarksEnvironment(
            shell: "/opt/homebrew/bin/zsh", userZDOTDIR: "/Users/me/.config/zsh", zshDirectory: "/shim")
        XCTAssertEqual(env.map(\.key), ["ZDOTDIR", "PLANCHETTE_ZSH_ZDOTDIR"])
        XCTAssertEqual(env.last?.value, "/Users/me/.config/zsh")
    }

    func testAnotherShellIsLeftAlone() {
        XCTAssertTrue(Durable.shellMarksEnvironment(shell: "/bin/bash", userZDOTDIR: nil, zshDirectory: "/shim").isEmpty)
        XCTAssertTrue(Durable.shellMarksEnvironment(shell: "/opt/homebrew/bin/fish", userZDOTDIR: nil, zshDirectory: "/shim").isEmpty)
        XCTAssertTrue(Durable.shellMarksEnvironment(shell: nil, userZDOTDIR: nil, zshDirectory: "/shim").isEmpty)
    }

    // tmux swallows a raw OSC 133; only a mark wrapped for its passthrough reaches Ghostty.
    func testTheShimWritesBothMarksWrappedForTmux() {
        let shim = Durable.zshenvContents
        XCTAssertTrue(shim.contains(#"$'\ePtmux;\e\e]133;C\a\e\\'"#))
        XCTAssertTrue(shim.contains(#"$'\ePtmux;\e\e]133;D;'"$_planchette_status"$'\a\e\\'"#))
    }

    // The status is $? of the command only in the first precmd hook; ZDOTDIR must be the
    // user's again before their .zshrc is looked for, and before any child starts.
    func testTheShimRestoresZDOTDIRFirstAndPutsItsStatusHookFirst() {
        let shim = Durable.zshenvContents
        let restore = shim.range(of: "'builtin' 'unset' 'ZDOTDIR'")
        let source = shim.range(of: "'builtin' 'source'")
        XCTAssertNotNil(restore)
        XCTAssertNotNil(source)
        XCTAssertLessThan(restore!.lowerBound, source!.lowerBound)
        XCTAssertTrue(shim.contains("precmd_functions=(_planchette_precmd ${precmd_functions:#_planchette_precmd})"))
    }

    func testTheShimDeclaresNoHooksOutsideAnInteractiveShell() {
        let shim = Durable.zshenvContents
        let interactive = shim.range(of: "if [[ -o 'interactive' ]]")
        let hook = shim.range(of: "_planchette_precmd()")
        XCTAssertNotNil(interactive)
        XCTAssertLessThan(interactive!.lowerBound, hook!.lowerBound)
    }

    // MARK: When the shell ends

    private let exitedScreen = """
        ➜  work exit
        [exited]

        Process exited. Press any key to close the terminal.
        """

    func testAnExitedSessionThatTmuxNoLongerListsHasEnded() {
        XCTAssertTrue(Durable.sessionEnded(id, screen: exitedScreen, listed: [(other, true)]))
        // The last session: tmux's server ends with it and answers with no sessions at all.
        XCTAssertTrue(Durable.sessionEnded(id, screen: exitedScreen, listed: []))
    }

    // Planchette restores by attaching a new client with -D: the old one prints [detached].
    func testADetachedClientLeavesTheTerminal() {
        let screen = "[detached (from session planchette-0a1b2c3d)]\n\nProcess exited. Press any key to close the terminal."
        XCTAssertFalse(Durable.sessionEnded(id, screen: screen, listed: []))
    }

    // A crashed or killed server took every agent along; restore replays those terminals.
    func testALostServerLeavesTheTerminal() {
        XCTAssertFalse(Durable.sessionEnded(id, screen: "[lost server]\n\nProcess exited.", listed: []))
        XCTAssertFalse(Durable.sessionEnded(id, screen: "[server exited]\n\nProcess exited.", listed: []))
    }

    func testASessionTmuxStillListsHasNotEnded() {
        XCTAssertFalse(Durable.sessionEnded(id, screen: exitedScreen, listed: [(id, false)]))
    }

    func testNoAnswerFromTmuxClosesNothing() {
        XCTAssertFalse(Durable.sessionEnded(id, screen: exitedScreen, listed: nil))
    }

    func testAnUnreadableScreenClosesNothing() {
        XCTAssertFalse(Durable.sessionEnded(id, screen: nil, listed: []))
        XCTAssertFalse(Durable.sessionEnded(id, screen: "Process exited. Press any key to close the terminal.", listed: []))
    }

    // Output that happens to look like tmux's word, above the last one tmux wrote, does not count.
    func testOnlyTheLastBracketedLineIsTmuxsWord() {
        let screen = "[exited]\n[lost server]\n\nProcess exited. Press any key to close the terminal."
        XCTAssertFalse(Durable.sessionEnded(id, screen: screen, listed: []))
    }

    // MARK: Review fixes

    // After a restart the new surface never saw the command's C; Ghostty drops a D without one.
    func testThePrecmdWritesCRightBeforeD() {
        let shim = Durable.zshenvContents
        let precmd = shim[shim.range(of: "_planchette_precmd() {")!.lowerBound...]
        let c = precmd.range(of: #"$'\ePtmux;\e\e]133;C\a\e\\'"#)
        let d = precmd.range(of: #"$'\ePtmux;\e\e]133;D;'"#)
        XCTAssertNotNil(c)
        XCTAssertNotNil(d)
        XCTAssertLessThan(c!.lowerBound, d!.lowerBound)
    }

    func testPaneCommandsAreReadForOurSessionsOnly() {
        let out = """
            planchette-0a1b2c3d-0000-4000-8000-0000000000ab 2.1.323
            planchette-0a1b2c3d-0000-4000-8000-0000000000cd zsh
            mywork vim
            planchette-not-a-uuid node
            """
        let commands = Durable.parsePaneCommands(out)
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[id], "2.1.323")
        XCTAssertEqual(commands[other], "zsh")
    }

    func testAShellAtItsPromptIsNoAgent() {
        for shell in ["zsh", "-zsh", "bash", "fish", "sh"] { XCTAssertTrue(Durable.isShell(shell), shell) }
        for program in ["2.1.323", "node", "claude", "vim", "npm"] { XCTAssertFalse(Durable.isShell(program), program) }
    }
}
