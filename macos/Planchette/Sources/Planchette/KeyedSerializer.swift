import Foundation

/// Runs async jobs one after another for each key; jobs for different keys run side
/// by side. `session.prompt` uses it per terminal: its text and its Enter are two
/// steps with a pause between them, and two prompts to one terminal must not
/// interleave.
@MainActor
final class KeyedSerializer<Key: Hashable> {
    private var tails: [Key: Task<Void, Never>] = [:]

    /// Wait for the previous job with this key, run `job`, and return when it is done.
    func run(_ key: Key, _ job: @escaping @MainActor () async -> Void) async {
        let previous = tails[key]
        let task = Task { @MainActor in
            await previous?.value
            await job()
        }
        tails[key] = task
        await task.value
        // The last one out removes the entry, so the table does not grow with every
        // terminal that was ever prompted.
        if tails[key] == task { tails[key] = nil }
    }

    /// Keys with a job in flight (for tests).
    var activeKeys: Int { tails.count }
}
