import Foundation

/// What the app has already told this user, kept with the rest of the state: the
/// welcome of a first launch, and the one nudge toward durable terminals after an
/// update. Pure, so when each message is due is tested instead of discovered.
struct OnboardingState: Codable, Equatable {
    /// The welcome screen did its job: the user started their first project. A state
    /// file that predates the key belongs to someone who already works in the app, so
    /// a missing key reads as seen.
    var welcomeSeen = true
    /// The version that ran last. A different one at launch means the app was updated.
    var lastLaunchedVersion: String?
    /// "Don't show this again" on the durable terminals prompt.
    var durablePromptHidden = false
    /// The feature hints: which are switched off, which feature was used already (`HintBook`).
    var hints = HintBook()

    /// The state of somebody who has never run the app: no state file existed.
    static let firstLaunch = OnboardingState(welcomeSeen: false)

    init(welcomeSeen: Bool = true, lastLaunchedVersion: String? = nil, durablePromptHidden: Bool = false,
         hints: HintBook = HintBook()) {
        self.welcomeSeen = welcomeSeen
        self.lastLaunchedVersion = lastLaunchedVersion
        self.durablePromptHidden = durablePromptHidden
        self.hints = hints
    }

    // Tolerant on purpose: a file from another version must cost this struct a field,
    // never the whole workspace.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        welcomeSeen = (try? c.decodeIfPresent(Bool.self, forKey: .welcomeSeen)) ?? true
        lastLaunchedVersion = try? c.decodeIfPresent(String.self, forKey: .lastLaunchedVersion)
        durablePromptHidden = (try? c.decodeIfPresent(Bool.self, forKey: .durablePromptHidden)) ?? false
        hints = (try? c.decodeIfPresent(HintBook.self, forKey: .hints)) ?? HintBook()
    }


    /// The version this process is. An unbundled debug build has none: "0.0.0", as the
    /// updater reads it too.
    static var runningVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Whether to offer durable terminals now: once after each update, for somebody
    /// who does not have them (no tmux, or the switch is off) and did not say to stop.
    ///
    /// - A first launch gets the welcome instead, which says the same thing in its place.
    /// - A launch of the same version offers nothing: the message belongs to the update,
    ///   not to every start, or it would be the first thing anyone learns to dismiss.
    func durablePromptDue(runningVersion: String, durableOn: Bool) -> Bool {
        guard welcomeSeen, !durablePromptHidden, !durableOn else { return false }
        return lastLaunchedVersion != runningVersion
    }
}
