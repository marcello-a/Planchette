import Foundation

/// A short introduction to one feature, shown once at the moment it is useful: a looping picture
/// of what it does, two lines of text, one button to try it. Every big user-facing feature gets one
/// (AGENTS.md, "Feature hints"). This file is the pure part: which hints exist and which of them are
/// still due. The card is in `Views/FeatureHintView.swift`, the offer logic in `AppState`.
enum FeatureHint: String, CaseIterable, Codable {
    case notepad
    case reviews

    /// The picture: `hints/<name>.gif` in the repository, `Contents/Resources/hints` in the app.
    var mediaName: String { rawValue }
}

/// What the user has done with the hints: switched them all off, or used a feature (so it needs
/// no introduction). Persisted inside `OnboardingState`; tolerant of unknown names, so a hint a
/// newer build knows does not cost the workspace.
struct HintBook: Codable, Equatable {
    /// "Don't show this again": no hint at all, for any feature.
    var hidden = false
    /// Hints whose feature was used: the raw values of `FeatureHint`.
    var done: Set<String> = []

    init(hidden: Bool = false, done: Set<String> = []) {
        self.hidden = hidden
        self.done = done
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hidden = (try? c.decodeIfPresent(Bool.self, forKey: .hidden)) ?? false
        done = Set((try? c.decodeIfPresent([String].self, forKey: .done)) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hidden, forKey: .hidden)
        try c.encode(done.sorted(), forKey: .done)
    }

    private enum CodingKeys: String, CodingKey { case hidden, done }

    func isDue(_ hint: FeatureHint) -> Bool { !hidden && !done.contains(hint.rawValue) }
}
