import Foundation

/// The environment a Planchette terminal starts in should describe *that*
/// terminal — not the agent that happened to launch the app.
///
/// Claude Code marks its own processes with a handful of variables, and a
/// Claude that finds them already set treats itself as a child session: it
/// writes **no transcript at all** (it says so in one line of its own output,
/// which is the only clue there is). Start Planchette from inside an agent's
/// terminal — every `swift run` during development does, and so does a
/// Planchette launched from a Planchette tab — and every PTY the app opens
/// inherits those markers. The cost is not one feature: the context ring, the
/// cache timer, the AI summary and the conversation title all read that file,
/// so all four go quiet at once, for a reason nothing in this app reports.
///
/// So the app clears them from its own environment once, before anything can
/// inherit it: the PTYs, the tmux server behind durable terminals and the
/// `claude -p` of `AIAssist` all fork from here.
///
/// Markers only. `ANTHROPIC_*` names an endpoint, a key or a model — it
/// configures an agent instead of identifying a running one, and a terminal
/// that loses it cannot talk to the API at all. Anything the user sets in
/// their own shell config comes back when the login shell runs, markers
/// included: this removes what was *inherited*, not what is configured.
///
/// A tmux server that is already running keeps the environment it started
/// with, so a durable terminal from an instance launched before this code can
/// still carry the markers until that server is gone. New servers start from
/// the cleaned environment like everything else.
enum AgentEnvironment {
    /// Whole names that mark a running agent session.
    static let markerNames: Set<String> = ["CLAUDECODE", "CLAUDE_PID", "AI_AGENT"]
    /// Prefixes of the same (`CLAUDE_CODE_CHILD_SESSION`, `…_SESSION_ID`,
    /// `…_ENTRYPOINT`, `…_MESSAGING_TOKEN`, and whatever a later version adds).
    static let markerPrefixes = ["CLAUDE_CODE_"]

    /// Which keys of `environment` are such markers. Pure, so it is tested.
    static func markers(in environment: [String: String]) -> [String] {
        environment.keys
            .filter { markerNames.contains($0) || markerPrefixes.contains(where: $0.hasPrefix) }
            .sorted()
    }

    /// Drop them from this process. Called once at launch, before the runtime
    /// that opens terminals exists.
    static func scrubInherited() {
        for key in markers(in: ProcessInfo.processInfo.environment) {
            unsetenv(key)
        }
    }
}
