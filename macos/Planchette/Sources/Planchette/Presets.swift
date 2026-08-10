import Foundation

/// A saved arrangement: the shape of a workspace — folders, projects, terminals
/// and their cluster splits — without any live state.
///
/// A preset is a **template, not a snapshot**: it stores working directories,
/// names, colors, tags and startup commands, never a Claude conversation id. So
/// opening one twice gives you two independent workspaces instead of two
/// terminals fighting over the same conversation (see `ClaudeResume`).
///
/// Presets live in their own file next to `state.json` because that is the
/// point of them: "Start fresh" throws the workspace away, and the presets have
/// to still be there afterwards.
struct Preset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var createdAt: Date
    var projects: [PresetProject] = []

    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), projects: [PresetProject] = []) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.projects = projects
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        projects = try c.decodeIfPresent([PresetProject].self, forKey: .projects) ?? []
    }

    var terminalCount: Int { projects.reduce(0) { $0 + $1.terminals.count } }
}

struct PresetProject: Codable, Equatable {
    var name: String
    var color: SessionColor = .none
    var favorite: Bool = false
    var viewMode: GroupViewMode = .tabs
    /// Folder this project sat in, by name — folders are per window and get
    /// re-created (or reused) in whatever window the preset is opened in.
    var folderName: String?
    var folderColor: SessionColor = .none
    var terminals: [PresetTerminal] = []
    /// Cluster splits, addressed by terminal index (see `PresetLayout`).
    var clusterLayout: PresetLayout?

    init(name: String) { self.name = name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decodeIfPresent(SessionColor.self, forKey: .color) ?? .none
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        viewMode = try c.decodeIfPresent(GroupViewMode.self, forKey: .viewMode) ?? .tabs
        folderName = try c.decodeIfPresent(String.self, forKey: .folderName)
        folderColor = try c.decodeIfPresent(SessionColor.self, forKey: .folderColor) ?? .none
        terminals = try c.decodeIfPresent([PresetTerminal].self, forKey: .terminals) ?? []
        clusterLayout = try c.decodeIfPresent(PresetLayout.self, forKey: .clusterLayout)
    }
}

struct PresetTerminal: Codable, Equatable {
    var workingDirectory: String
    var customTitle: String?
    var color: SessionColor = .none
    var tags: [String] = []
    var startupCommand: String?

    init(workingDirectory: String) { self.workingDirectory = workingDirectory }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workingDirectory = try c.decode(String.self, forKey: .workingDirectory)
        customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
        color = try c.decodeIfPresent(SessionColor.self, forKey: .color) ?? .none
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        startupCommand = try c.decodeIfPresent(String.self, forKey: .startupCommand)
    }
}

/// A `SplitLayout` with terminal **indices** instead of session ids. Session ids
/// are created fresh every time a preset is opened, so a stored id would point
/// at nothing; the index says "the second terminal of this project", which
/// survives.
indirect enum PresetLayout: Codable, Equatable {
    case leaf(Int)
    case row([PresetLayout])
    case column([PresetLayout])

    /// Convert a live layout, given the session ids in the project's tab order.
    /// Returns nil when the layout holds nothing that is still in the project.
    static func from(_ layout: SplitLayout, sessionIDs: [UUID]) -> PresetLayout? {
        switch layout {
        case .leaf(let id):
            return sessionIDs.firstIndex(of: id).map { .leaf($0) }
        case .row(let children):
            let mapped = children.compactMap { from($0, sessionIDs: sessionIDs) }
            return mapped.isEmpty ? nil : (mapped.count == 1 ? mapped[0] : .row(mapped))
        case .column(let children):
            let mapped = children.compactMap { from($0, sessionIDs: sessionIDs) }
            return mapped.isEmpty ? nil : (mapped.count == 1 ? mapped[0] : .column(mapped))
        }
    }

    /// Rebuild a live layout for freshly created sessions (same order as the
    /// preset's terminals). Indices that don't exist are dropped.
    func resolved(with sessionIDs: [UUID]) -> SplitLayout? {
        switch self {
        case .leaf(let index):
            return sessionIDs.indices.contains(index) ? .leaf(sessionIDs[index]) : nil
        case .row(let children):
            let mapped = children.compactMap { $0.resolved(with: sessionIDs) }
            return mapped.isEmpty ? nil : (mapped.count == 1 ? mapped[0] : .row(mapped))
        case .column(let children):
            let mapped = children.compactMap { $0.resolved(with: sessionIDs) }
            return mapped.isEmpty ? nil : (mapped.count == 1 ? mapped[0] : .column(mapped))
        }
    }
}

/// Reads and writes `presets.json`. Deliberately separate from `state.json`:
/// the workspace comes and goes, the arrangements stay.
///
/// Main-actor bound like `AppState`, whose `stateURL` it sits next to; the file
/// is small enough that reading it inline costs nothing.
@MainActor
enum PresetStore {
    static var url: URL {
        AppState.stateURL.deletingLastPathComponent().appendingPathComponent("presets.json")
    }

    static func load() -> [Preset] {
        guard let data = try? Data(contentsOf: url),
              let presets = try? JSONDecoder().decode([Preset].self, from: data)
        else { return [] }
        return presets
    }

    static func save(_ presets: [Preset]) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(presets).write(to: url, options: .atomic)
            // Same reasoning as state.json: it carries working directories.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("preset save failed: \(error)")
        }
    }
}
