import Foundation

/// The tags you keep, and the rules that edit them (Settings → Project panel → Tags).
///
/// A tag is a short lowercase label on a terminal ("review", "blocked"). The
/// **list** is what a terminal's Tags menu offers, in your order. A tag a
/// terminal carries that is not on the list — made with "New tag…" in the menu —
/// is a **stray**: still offered while some terminal has it, gone when none does,
/// unless you add it to the list. Everything here is pure, so the rules are
/// tested instead of eyeballed.
enum TagList {
    /// What a fresh install offers, and what "Restore default list" brings back.
    static let defaults = TerminalSession.suggestedTags

    /// A tag is a label, not a sentence.
    static let maxLength = 24

    /// A tag as it is stored: one line, lowercase, single spaces — what "New tag…"
    /// has always done — and at most `maxLength` characters. Nil when nothing is left.
    static func normalized(_ name: String) -> String? {
        let line = name.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        let clipped = String(line.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
        return clipped.isEmpty ? nil : clipped
    }

    /// A list read from disk: every entry normalized, none twice, the order kept.
    /// A hand-edited or damaged file must not hand SwiftUI an empty name or a
    /// duplicate identity.
    static func sanitized(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.compactMap(normalized).filter { seen.insert($0).inserted }
    }

    // MARK: Editing the list

    /// The list with `name` appended — unchanged if it is already there.
    static func adding(_ name: String, to list: [String]) -> [String] {
        guard let tag = normalized(name), !list.contains(tag) else { return list }
        return list + [tag]
    }

    /// The list after renaming `old` to `name`. A name that is already on the
    /// list is a merge: the old entry goes, the existing one stays where it is.
    static func renaming(_ old: String, to name: String, in list: [String]) -> [String] {
        guard let new = normalized(name), new != old, let index = list.firstIndex(of: old)
        else { return list }
        var result = list
        if result.contains(new) {
            result.remove(at: index)
        } else {
            result[index] = new
        }
        return result
    }

    static func removing(_ tag: String, from list: [String]) -> [String] {
        list.filter { $0 != tag }
    }

    // MARK: What a rename or a delete does to a terminal

    /// One terminal's tags after `old` became `name`: in place, and once — a
    /// terminal that carried both ends up with one.
    static func renamed(_ tags: [String], from old: String, to name: String) -> [String] {
        guard let new = normalized(name) else { return tags }
        var result: [String] = []
        for tag in tags {
            let mapped = tag == old ? new : tag
            if !result.contains(mapped) { result.append(mapped) }
        }
        return result
    }

    static func removed(_ tags: [String], _ tag: String) -> [String] {
        tags.filter { $0 != tag }
    }

    // MARK: What the menu offers

    /// Tags some terminal carries that the list does not have, alphabetically —
    /// a dictionary of terminals has no order worth keeping.
    static func strays(list: [String], inUse terminals: [[String]]) -> [String] {
        Set(terminals.joined()).subtracting(list).sorted()
    }

    /// The Tags menu: your list, then the strays.
    static func known(list: [String], inUse terminals: [[String]]) -> [String] {
        list + strays(list: list, inUse: terminals)
    }

    /// On how many terminals a tag sits.
    static func usage(of tag: String, in terminals: [[String]]) -> Int {
        terminals.filter { $0.contains(tag) }.count
    }
}

/// Everything a rename or a delete in the tag list touches, as plain values: the
/// list, the tags of every terminal and the tags in the saved arrangements.
/// `AppState` hands its own over and takes the result back, so the rules live
/// here, where they are tested, and the app's part is an assignment.
struct TagBook: Equatable {
    var list: [String]
    var terminals: [UUID: [String]]
    var presets: [Preset]

    /// A rename is meant everywhere: the list, every terminal that carries the
    /// tag, and every arrangement that remembers it.
    func renaming(_ old: String, to name: String) -> TagBook {
        guard let new = TagList.normalized(name), new != old else { return self }
        return TagBook(
            list: TagList.renaming(old, to: new, in: list),
            terminals: terminals.mapValues { TagList.renamed($0, from: old, to: new) },
            presets: presets.map { $0.retagged { TagList.renamed($0, from: old, to: new) } })
    }

    /// A delete is meant everywhere too.
    func deleting(_ tag: String) -> TagBook {
        TagBook(
            list: TagList.removing(tag, from: list),
            terminals: terminals.mapValues { TagList.removed($0, tag) },
            presets: presets.map { $0.retagged { TagList.removed($0, tag) } })
    }
}

extension Preset {
    /// The arrangement with every terminal's tags passed through `transform`.
    /// A rename or a delete in the tag list is meant everywhere: an old
    /// arrangement must not bring a deleted tag back to life.
    func retagged(_ transform: ([String]) -> [String]) -> Preset {
        var copy = self
        for p in copy.projects.indices {
            for t in copy.projects[p].terminals.indices {
                copy.projects[p].terminals[t].tags = transform(copy.projects[p].terminals[t].tags)
            }
        }
        return copy
    }
}
