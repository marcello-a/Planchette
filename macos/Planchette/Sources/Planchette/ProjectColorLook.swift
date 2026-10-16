import Foundation

/// Where a project's color shows (Settings → General → Project color).
///
/// The color is the one picked in a project's Color menu. A project without one is
/// never tinted, whatever is set here.
enum ProjectColorScope: String, Codable, CaseIterable, Identifiable {
    /// Nowhere: a picked color is only the dot beside the project's name.
    case off
    /// On the project's label — in the project panel, in the header above its terminal,
    /// and on its overview page.
    case label
    /// On the label, and over the terminals of an open project in the panel.
    case project

    var id: String { rawValue }

    var titleKey: LKey {
        switch self {
        case .off: .projectColorOff
        case .label: .projectColorLabel
        case .project: .projectColorProject
        }
    }
}

/// How strong that color is. "Colorful" is the look 0.2.36 shipped; the default is the
/// subtler one in the middle, because the colorful one read as heavy. The last step of the
/// dial is no gradient at all.
enum ProjectColorStrength: String, Codable, CaseIterable, Identifiable {
    case colorful
    case subtle
    case faint
    /// The end of the dial: nothing is drawn, whatever `ProjectColorScope` says.
    case off

    var id: String { rawValue }

    var titleKey: LKey {
        switch self {
        case .colorful: .projectColorColorful
        case .subtle: .projectColorSubtle
        case .faint: .projectColorFaint
        case .off: .projectColorStrengthOff
        }
    }

    /// How much of the colorful look's strength this level keeps: one factor for a label
    /// (and the header that is a label of the same kind), one for the wash behind the
    /// terminals. The wash starts softer to begin with, so it keeps more of what it has.
    func factor(isLabel: Bool) -> Double {
        switch self {
        case .colorful: 1
        case .subtle: isLabel ? 0.5 : 0.6
        case .faint: isLabel ? 0.26 : 0.45
        case .off: 0
        }
    }
}

/// How the color of a project is shown: where, and how strong. Persisted with the
/// workspace; every field decodes on its own, so a value that no version can read costs
/// that one choice and never the whole `state.json`.
struct ProjectColorLook: Codable, Equatable {
    var scope: ProjectColorScope = .project
    var strength: ProjectColorStrength = .subtle

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scope = (try? c.decodeIfPresent(ProjectColorScope.self, forKey: .scope)) ?? .project
        strength = (try? c.decodeIfPresent(ProjectColorStrength.self, forKey: .strength)) ?? .subtle
    }

    /// A label, a header: the strip. Off in either choice means no gradient at all.
    var showsLabel: Bool { scope != .off && strength != .off }

    /// The wash behind the terminals of an open project.
    var showsBody: Bool { scope == .project && strength != .off }
}
