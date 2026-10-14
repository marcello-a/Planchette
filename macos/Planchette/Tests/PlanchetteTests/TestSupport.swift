import Foundation
@testable import Planchette

/// Run git for a test's fixture or as its oracle ("what does git itself say?").
///
/// Not `Worktrees.git` with its defaults: that carries the app's own 15 s deadline for
/// a poll, which a fixture has no business sharing. On a machine that is badly
/// overloaded — endpoint security scanning every exec and file open, a CI runner with
/// noisy neighbours — a `git commit` can take longer, and the test then failed in its
/// `setUp` with "git commit did not answer in time", which XCTest reports as both
/// skipped and failed. Measured by making `git commit` take 16 s: 18 tests failed this way.
@discardableResult
func fixtureGit(_ arguments: [String], in directory: String) throws -> String {
    try Worktrees.git(arguments, in: directory, timeout: 300)
}
