import XCTest
@testable import Planchette

// The batched PR lookup must give every checkout the answer its own `gh pr list` gives.
// The tables below for gh's repository choice were measured with gh 2.106 (`GH_DEBUG=api
// gh pr list --head x` in a scratch repository, one config per row) — see the comments.

private func repo(_ owner: String, _ name: String) -> GitHubRepo { GitHubRepo(owner: owner, name: name) }

private func remote(_ name: String, _ url: String, push: String? = nil, resolved: String? = nil) -> GitRemote {
    GitRemote(name: name, urls: [url], pushURLs: push.map { [$0] } ?? [], ghResolved: resolved)
}

// MARK: - git config files

final class GitConfigFileTests: XCTestCase {
    private func entries(_ text: String) -> [String]? {
        GitConfigFile.parse(text)?.entries.map { entry in
            // git prints a key outside any section without one, an empty subsection as `s..k`.
            let name = [entry.section.isEmpty ? nil : entry.section, entry.subsection, entry.key]
                .compactMap { $0 }.joined(separator: ".")
            return entry.value.map { "\(name)=\($0)" } ?? name
        }
    }

    func testSectionsSubsectionsAndKeys() {
        let text = """
        [core]
        \trepositoryformatversion = 0
        [Remote "Origin"]
        \tURL = https://github.com/a/b.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        [remote.Upstream]
        \turl = git@github.com:c/d
        """
        XCTAssertEqual(entries(text), [
            "core.repositoryformatversion=0",
            "remote.Origin.url=https://github.com/a/b.git",
            "remote.Origin.fetch=+refs/heads/*:refs/remotes/origin/*",
            // The old dotted form lowercases the subsection too.
            "remote.upstream.url=git@github.com:c/d",
        ])
    }

    func testValuesAsGitReadsThem() {
        let text = #"""
        [s]
          a = plain value   ; a comment
          b = "quoted # not a comment"
          c = "with \"escapes\" and \\ backslash"
          d = tab\tand\nnewline
          e = continued \
        line
          f
          g =
          h = x  "  y  "  z
        [t] k = same line
        """#
        XCTAssertEqual(entries(text), [
            "s.a=plain value",
            "s.b=quoted # not a comment",
            #"s.c=with "escapes" and \ backslash"#,
            "s.d=tab\tand\nnewline",
            "s.e=continued line",
            "s.f",
            "s.g=",
            "s.h=x    y    z",
            "t.k=same line",
        ])
    }

    func testCRLFAndAByteOrderMark() {
        XCTAssertEqual(entries("\u{FEFF}[remote \"origin\"]\r\n\turl = https://github.com/a/b\r\n"),
                       ["remote.origin.url=https://github.com/a/b"])
    }

    func testWhatGitRefusesIsUnreadable() {
        for bad in [
            "[s]\n a = \"unclosed\n",
            "[s]\n a = bad \\q escape\n",
            "[s]\n a # comment after a bare key\n",
            "[s \"sub\" x]\n",
            "[s \"unclosed]\n",
            "[]\n",
            "[s]\n 1a = starts with a digit\n",
            "[s]\n a_b = underscore\n",
        ] {
            XCTAssertNil(GitConfigFile.parse(bad), bad)
        }
    }

    func testIncludePaths() {
        let file = GitConfigFile.parse("""
        [include]
          path = ~/a
        [includeIf "gitdir:~/work/"]
          path = work.inc
        [user]
          path = not-an-include
        """)
        XCTAssertEqual(file?.includePaths, ["~/a", "work.inc"])
    }

    /// git itself is the oracle: every file it reads, this reads to the same entries, and
    /// every file it refuses, this refuses.
    func testGitAgrees() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("planchette-gitconfig-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let samples = [
            "[remote \"origin\"]\n\turl = https://github.com/a/b.git\n\tgh-resolved = base\n",
            "[Remote \"Mixed Case\"]\n\tURL = x\n[remote.Old]\n\turl = y\n",
            "[s]\n  a = plain value   ; comment\n  b = \"q # x\"\n  c = \"e \\\"q\\\" \\\\ b\"\n  d = t\\tn\\n\n",
            "[s]\n  e = one \\\ntwo\n  f\n  g =\n  h = x  \"  y  \"  z\n[t] k = same line\n",
            "\u{FEFF}[remote \"origin\"]\r\n\turl = https://github.com/a/b\r\n",
            "[url \"git@github.com:\"]\n\tinsteadOf = https://github.com/\n",
            "[s]\n a = \"unclosed\n",
            "[s]\n a = bad \\q escape\n",
            "[s]\n a # comment\n",
            "a = no section\n",
            "[s \"unclosed]\n",
            "[remote \"o\\\"q\"]\n\turl = z\n",
            "[s \"a\\\\b\\x\"]\n k = v\n",
            "[s]\nk=v\n[s]\n\tk = w # c\n",
            "[a.B.c]\n k = v\n",
            "[s]\n k = \"\" \n m =   \"  lead\"\n",
            "[s]\n k = v\\",
            "[s]\n k = a\\\n",
            "[s]\n k = 1\n[S]\n K = 2\n[s \"\"]\n k = 3\n",
            "[s]\n k = \"a\nb\"\n",
        ]
        for (index, sample) in samples.enumerated() {
            let path = "\(dir)/\(index).config"
            try sample.write(toFile: path, atomically: true, encoding: .utf8)
            let ours = entries(sample)
            if let listed = try? fixtureGit(["config", "--file", path, "--null", "--list"], in: dir) {
                let git = listed.split(separator: "\0", omittingEmptySubsequences: true).map { item -> String in
                    let parts = item.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    return parts.count == 2 ? "\(parts[0])=\(parts[1])" : String(parts[0])
                }
                XCTAssertEqual(ours, git, "sample \(index): \(sample)")
            } else {
                XCTAssertNil(ours, "git refuses sample \(index): \(sample)")
            }
        }
    }

    func testRemotesInOrderWithTheLastGhResolved() {
        let first = GitConfigFile.parse("""
        [remote "origin"]
          url = https://github.com/a/b
          gh-resolved = base
        [remote "upstream"]
          url = https://github.com/c/d
          pushurl = https://github.com/e/f
        [remote "origin"]
          gh-resolved = c/d
        """)!
        let second = GitConfigFile.parse("[remote \"fork\"]\n url = https://github.com/g/h\n")!
        XCTAssertEqual(GitRemote.all(in: [first, second]), [
            GitRemote(name: "origin", urls: ["https://github.com/a/b"], pushURLs: [], ghResolved: "c/d"),
            GitRemote(name: "upstream", urls: ["https://github.com/c/d"], pushURLs: ["https://github.com/e/f"]),
            GitRemote(name: "fork", urls: ["https://github.com/g/h"]),
        ])
    }
}

// MARK: - Which repository

final class GhRepoResolverTests: XCTestCase {
    func testRemoteURLs() {
        let cases: [(String, GhRepoResolver.RemoteURL)] = [
            ("https://github.com/cli/cli.git", .github(repo("cli", "cli"))),
            ("https://github.com/cli/cli", .github(repo("cli", "cli"))),
            ("https://github.com/cli/cli/", .github(repo("cli", "cli"))),
            ("http://github.com/cli/cli.git", .github(repo("cli", "cli"))),
            ("https://user:token@github.com/cli/cli.git", .github(repo("cli", "cli"))),
            ("https://github.com:443/cli/cli.git", .github(repo("cli", "cli"))),
            ("https://www.github.com/cli/cli.git", .github(repo("cli", "cli"))),   // gh: cli/cli
            ("https://GitHub.COM/Cli/CLI", .github(repo("Cli", "CLI"))),
            ("git+https://github.com/cli/cli", .github(repo("cli", "cli"))),
            ("git@github.com:cli/cli.git", .github(repo("cli", "cli"))),
            ("git@github.com:cli/cli", .github(repo("cli", "cli"))),             // gh: cli/cli
            ("github.com:cli/cli.git", .github(repo("cli", "cli"))),
            ("git@github.com:/cli/cli.git", .github(repo("cli", "cli"))),
            ("ssh://git@github.com/cli/cli.git", .github(repo("cli", "cli"))),
            ("ssh://git@ssh.github.com:443/cli/cli.git", .github(repo("cli", "cli"))),   // gh: cli/cli
            ("git+ssh://git@github.com/cli/cli.git", .github(repo("cli", "cli"))),
            ("git://github.com/cli/cli.git", .github(repo("cli", "cli"))),
            ("https://github.com/cli/cli.git.git", .github(repo("cli", "cli.git"))),
            ("https://github.com/o/ünïcödé-repo", .github(repo("o", "ünïcödé-repo"))),
            // An SSH alias stands for whatever `ssh -G` says: gh 2.106 refused this one
            // ("none of the git remotes ... point to a known GitHub host").
            ("git@github.com-work:cli/cli.git", .otherHost("github.com-work")),
            ("https://ghe.example.com/cli/cli.git", .otherHost("ghe.example.com")),
            ("https://octo.ghe.com/cli/cli.git", .otherHost("octo.ghe.com")),
            ("https://gitlab.com/cli/cli.git", .otherHost("gitlab.com")),
            ("/Users/me/repos/cli", .localPath),
            ("/Users/me/My Repos/a:b%20c", .localPath),
            ("./sibling", .localPath),
            ("../sibling", .localPath),
            ("~/repos/cli", .localPath),
            ("sibling", .localPath),
            ("file:///Users/me/repos/cli", .localPath),
            ("https://github.com/cli/cli/extra", .unknown),   // gh: refused
            ("https://github.com/cli", .unknown),
            ("https://github.com/cli//cli", .unknown),
            ("https://github.com/cli/.git", .unknown),
            ("ssh+git://github.com/cli/cli", .unknown),
            ("HTTPS://github.com/cli/cli", .unknown),
            ("git:cli/cli", .unknown),
            ("dir/sub:cli/cli", .unknown),
            ("https://github.com/cli/cli%20x", .unknown),
            ("https://github.com/cli/cli?x=1", .unknown),
            ("https://[::1]/cli/cli", .unknown),
            ("https://github.com:x/cli/cli", .unknown),
            ("file://host/share/cli", .unknown),
            ("", .unknown),
            ("C:\\repos\\cli", .unknown),
        ]
        for (url, expected) in cases {
            XCTAssertEqual(GhRepoResolver.classify(url), expected, url)
        }
    }

    /// The rows measured with gh 2.106 in a scratch repository (`GH_DEBUG=api`), plus the
    /// cases where gh's answer depends on what this cannot see, which fall back.
    func testTheRepositoryGhPicks() {
        let planchette = "https://github.com/marcello-a/Planchette.git"
        let cli = "git@github.com:cli/cli.git"
        let cases: [(String, [GitRemote], RepoResolution?)] = [
            ("origin only", [remote("origin", planchette)], .github(repo("marcello-a", "Planchette"))),
            ("upstream beats origin", [remote("origin", planchette), remote("upstream", cli)], .github(repo("cli", "cli"))),
            ("gh-resolved=base on origin", [remote("origin", planchette, resolved: "base"), remote("upstream", cli)],
             .github(repo("marcello-a", "Planchette"))),
            ("gh-resolved=base on upstream", [remote("origin", planchette), remote("upstream", cli, resolved: "base")],
             .github(repo("cli", "cli"))),
            ("gh-resolved=owner/repo", [remote("origin", planchette, resolved: "octocat/Hello-World"), remote("upstream", cli)],
             .github(repo("octocat", "Hello-World"))),
            ("the higher remote's gh-resolved wins",
             [remote("origin", planchette, resolved: "octocat/Hello-World"), remote("upstream", cli, resolved: "base")],
             .github(repo("cli", "cli"))),
            ("github beats origin", [remote("origin", planchette), remote("github", "https://github.com/cli/cli")],
             .github(repo("cli", "cli"))),
            ("remote names are compared without case", [remote("origin", planchette), remote("Upstream", "https://github.com/cli/cli/")],
             .github(repo("cli", "cli"))),
            ("a local remote is dropped", [remote("origin", "/tmp/somewhere"), remote("upstream", "https://github.com/cli/cli.git")],
             .github(repo("cli", "cli"))),
            ("two remotes of one repository", [remote("foo", planchette), remote("bar", "git@github.com:marcello-a/Planchette")],
             .github(repo("marcello-a", "Planchette"))),
            ("an empty gh-resolved is none", [remote("origin", planchette, resolved: ""), remote("upstream", cli)],
             .github(repo("cli", "cli"))),
            ("a remote without a URL is not listed", [GitRemote(name: "upstream", ghResolved: "base"), remote("origin", planchette)],
             .github(repo("marcello-a", "Planchette"))),
            // gh sorts the other names in no fixed order.
            ("two other remotes", [remote("foo", planchette), remote("bar", cli)], nil),
            ("two other remotes resolved", [remote("foo", planchette, resolved: "base"), remote("bar", cli, resolved: "base")], nil),
            ("an SSH alias", [remote("origin", "git@github.com-work:cli/cli.git")], nil),
            ("Enterprise", [remote("origin", "https://ghe.example.com/cli/cli.git")], nil),
            // gh drops a host without a login, which this cannot see.
            ("another host beside github.com", [remote("origin", "https://gitlab.com/cli/cli.git"),
                                               remote("github", "https://github.com/octocat/Hello-World.git")], nil),
            // gh 2.106 then asks the push URL.
            ("a local remote that pushes to GitHub", [remote("origin", "/tmp/somewhere", push: "https://github.com/cli/cli.git")], nil),
            ("no remotes", [], nil),
            ("only local remotes", [remote("origin", "/tmp/a")], nil),
            ("an unreadable URL", [remote("origin", "https://github.com/cli/cli/extra"), remote("upstream", cli)], nil),
            ("gh-resolved with a host", [remote("origin", planchette, resolved: "github.com/cli/cli")], nil),
            ("gh-resolved nonsense", [remote("origin", planchette, resolved: "nonsense")], nil),
            ("several URLs", [GitRemote(name: "origin", urls: [planchette, cli])], nil),
        ]
        for (name, remotes, expected) in cases {
            let resolution = GhRepoResolver.resolve(remotes: remotes, rewrites: [])
            if let expected {
                XCTAssertEqual(resolution, expected, name)
            } else if case .github(let picked) = resolution {
                XCTFail("\(name): must fall back, picked \(picked)")
            }
        }
    }

    func testARewrittenURLFallsBack() {
        let remotes = [remote("origin", "https://github.com/cli/cli.git")]
        XCTAssertEqual(GhRepoResolver.resolve(remotes: remotes, rewrites: ["https://gitlab.com/"]),
                       .github(repo("cli", "cli")))
        for prefix in ["https://github.com/", "https://", "", "https://github.com/cli/cli.git"] {
            guard case .uncertain = GhRepoResolver.resolve(remotes: remotes, rewrites: [prefix]) else {
                return XCTFail("insteadOf \(prefix) rewrites the URL")
            }
        }
        let pushes = [remote("origin", "https://github.com/cli/cli.git", push: "gh:cli/cli")]
        guard case .uncertain = GhRepoResolver.resolve(remotes: pushes, rewrites: ["gh:"]) else {
            return XCTFail("a rewritten push URL falls back too")
        }
    }

    func testTheEnvironment() {
        XCTAssertNil(GhRepoResolver.environmentBlocker([:]))
        XCTAssertNil(GhRepoResolver.environmentBlocker(["HOME": "/x", "GH_TOKEN": "t", "GH_REPO": ""]))
        for name in GhRepoResolver.fallbackEnvironment {
            XCTAssertEqual(GhRepoResolver.environmentBlocker([name: "1"]), "\(name) is set")
        }
    }
}

// MARK: - Which repository, from the files

final class GhRepoResolverFileTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("planchette-resolver-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        root = (root as NSString).resolvingSymlinksInPath
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func write(_ path: String, _ text: String) throws {
        let full = "\(root)/\(path)"
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try text.write(toFile: full, atomically: true, encoding: .utf8)
    }

    private func resolve(_ checkout: String?, outer: GhRepoResolver.OuterRules? = .init()) -> RepoResolution {
        GhRepoResolver.resolve(checkoutRoot: checkout.map { "\(root)/\($0)" }, outer: outer)
    }

    private func assertUncertain(_ resolution: RepoResolution, _ message: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        if case .github(let picked) = resolution { XCTFail("\(message): picked \(picked)", file: file, line: line) }
    }

    func testACheckout() throws {
        try write("main/.git/config", "[remote \"origin\"]\n\turl = git@github.com:a/b.git\n")
        XCTAssertEqual(resolve("main"), .github(repo("a", "b")))
    }

    func testALinkedWorktreeReadsTheCommonConfig() throws {
        try write("main/.git/config", "[remote \"origin\"]\n\turl = https://github.com/a/b\n")
        try write("main/.git/worktrees/wt/commondir", "../..\n")
        try write("wt/.git", "gitdir: \(root)/main/.git/worktrees/wt\n")
        XCTAssertEqual(GhRepoResolver.gitDirs(checkoutRoot: "\(root)/wt"),
                       .init(gitDir: "\(root)/main/.git/worktrees/wt", commonDir: "\(root)/main/.git"))
        XCTAssertEqual(resolve("wt"), .github(repo("a", "b")))
    }

    func testARelativeGitdirAndAnAbsoluteCommondir() throws {
        try write("store/config", "[remote \"upstream\"]\n\turl = https://github.com/c/d\n")
        try write("store/worktrees/wt/commondir", "\(root)/store\n")
        try write("wt/.git", "gitdir: ../store/worktrees/wt")
        XCTAssertEqual(resolve("wt"), .github(repo("c", "d")))
    }

    func testASubmoduleReadsItsOwnConfig() throws {
        try write("super/.git/config", "[remote \"origin\"]\n\turl = https://github.com/super/repo\n")
        try write("super/.git/modules/sub/config", "[remote \"origin\"]\n\turl = https://github.com/sub/repo\n")
        try write("super/sub/.git", "gitdir: ../.git/modules/sub\n")
        XCTAssertEqual(resolve("super/sub"), .github(repo("sub", "repo")))
    }

    func testAWorktreeConfigCounts() throws {
        try write("main/.git/config", """
        [extensions]
        \tworktreeConfig = true
        [remote "origin"]
        \turl = https://github.com/a/b
        [remote "upstream"]
        \turl = https://github.com/c/d
        """)
        try write("main/.git/config.worktree", "[remote \"origin\"]\n\tgh-resolved = base\n")
        XCTAssertEqual(resolve("main"), .github(repo("a", "b")))
        // Without the extension git does not read the file.
        try write("main/.git/config", "[remote \"origin\"]\n\turl = https://github.com/a/b\n[remote \"upstream\"]\n\turl = https://github.com/c/d\n")
        XCTAssertEqual(resolve("main"), .github(repo("c", "d")))
    }

    func testWhatFallsBack() throws {
        assertUncertain(resolve(nil), "no checkout")
        assertUncertain(resolve("missing"), "no .git")
        try write("broken/.git", "not a gitdir line\n")
        assertUncertain(resolve("broken"), "a .git file without gitdir")
        try write("dangling/.git", "gitdir: \(root)/nowhere\n")
        assertUncertain(resolve("dangling"), "a gitdir without config")
        try write("bad/.git/config", "[remote \"origin\"\n\turl = https://github.com/a/b\n")
        assertUncertain(resolve("bad"), "a config git refuses")
        try write("inc/.git/config", "[include]\n\tpath = extra\n[remote \"origin\"]\n\turl = https://github.com/a/b\n")
        assertUncertain(resolve("inc"), "an include")
        try write("ok/.git/config", "[remote \"origin\"]\n\turl = https://github.com/a/b\n")
        assertUncertain(resolve("ok", outer: nil), "an unreadable global config")
        assertUncertain(resolve("ok", outer: .init(rewrites: [], definesRemote: true)), "a global remote")
        assertUncertain(resolve("ok", outer: .init(rewrites: ["https://github.com/a/"])), "a global insteadOf")
        try write("local/.git/config", "[remote \"origin\"]\n\turl = https://github.com/a/b\n[url \"x\"]\n\tinsteadOf = https://github.com/\n")
        assertUncertain(resolve("local"), "a local insteadOf")
    }

    /// The layout git itself writes: `git worktree add` and remotes set by git.
    func testARealRepositoryAndWorktree() throws {
        let main = "\(root)/real"
        try FileManager.default.createDirectory(atPath: main, withIntermediateDirectories: true)
        try fixtureGit(["init", "-q", "-b", "main"], in: main)
        try fixtureGit(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "x"], in: main)
        try fixtureGit(["remote", "add", "origin", "https://github.com/me/fork.git"], in: main)
        try fixtureGit(["remote", "add", "upstream", "git@github.com:them/project.git"], in: main)
        try fixtureGit(["worktree", "add", "-q", "-b", "feature", "\(root)/linked"], in: main)
        XCTAssertEqual(resolve("real"), .github(repo("them", "project")))
        XCTAssertEqual(resolve("linked"), .github(repo("them", "project")))
        try fixtureGit(["config", "remote.origin.gh-resolved", "base"], in: main)
        XCTAssertEqual(resolve("linked"), .github(repo("me", "fork")))
    }

    func testOuterRulesFollowEveryInclude() throws {
        try write("home/.gitconfig", """
        [user]
        \tname = me
        [include]
        \tpath = ~/.config/extra
        [includeIf "gitdir:~/work/"]
        \tpath = work.inc
        [include]
        \tpath = ~/.gitconfig
        """)
        try write("home/.config/extra", "[url \"git@github.com-work:\"]\n\tinsteadOf = git@github.com:\n")
        try write("home/work.inc", "[url \"x\"]\n\tpushInsteadOf = https://\n")
        let home = "\(root)/home"
        let rules = GhRepoResolver.outerRules(paths: ["\(home)/.gitconfig", "\(root)/missing"], home: home)
        XCTAssertEqual(rules, .init(rewrites: ["git@github.com:", "https://"], definesRemote: false))

        try write("home/.config/extra", "[remote \"origin\"]\n\turl = https://github.com/a/b\n")
        XCTAssertEqual(GhRepoResolver.outerRules(paths: ["\(home)/.gitconfig"], home: home)?.definesRemote, true)

        try write("home/.config/extra", "[broken\n")
        XCTAssertNil(GhRepoResolver.outerRules(paths: ["\(home)/.gitconfig"], home: home))
    }

    func testOuterConfigPaths() {
        let paths = GhRepoResolver.outerConfigPaths(environment: [:], home: "/Users/me")
        XCTAssertEqual(Array(paths.suffix(2)), ["/Users/me/.config/git/config", "/Users/me/.gitconfig"])
        XCTAssertTrue(paths.contains("/etc/gitconfig"))
        XCTAssertEqual(Array(GhRepoResolver.outerConfigPaths(environment: ["XDG_CONFIG_HOME": "/x"], home: "/h").suffix(2)),
                       ["/x/git/config", "/h/.gitconfig"])
    }
}

// MARK: - The query

final class PullRequestBatchQueryTests: XCTestCase {
    private let nasty = [
        PullRequestBatch.Request(repo: repo("o", "n"), branch: "plain"),
        PullRequestBatch.Request(repo: repo("we\"ird", "na\\me"), branch: "a\"b\\c\nd"),
        PullRequestBatch.Request(repo: repo("ü", "日本"), branch: "feat/emoji-🚀-ünï"),
        PullRequestBatch.Request(repo: repo("o", "n"), branch: "$b0 ) { evil } #"),
    ]

    func testTheQueryNamesEveryAliasAndNoValue() {
        let query = PullRequestBatch.query(count: 3)
        for index in 0..<3 {
            XCTAssertTrue(query.contains("r\(index): repository(owner: $o\(index), name: $n\(index))"), query)
            XCTAssertTrue(query.contains("pullRequests(headRefName: $b\(index), first: \(PullRequests.lookupLimit), "
                + "states: [OPEN, MERGED, CLOSED], orderBy: {field: CREATED_AT, direction: DESC})"), query)
            XCTAssertTrue(query.contains("$o\(index): String!, $n\(index): String!, $b\(index): String!"), query)
        }
        XCTAssertFalse(query.contains("r3:"))
        XCTAssertTrue(query.contains("nodes { number state isDraft reviewDecision url title }"))
        // The batch asks for exactly what `gh pr list --json` is asked for.
        XCTAssertEqual(PullRequestBatch.nodeFields.split(separator: " ").joined(separator: ","), PullRequests.jsonFields)
        XCTAssertEqual(query.filter { $0 == "{" }.count, query.filter { $0 == "}" }.count)
        XCTAssertEqual(query.filter { $0 == "(" }.count, query.filter { $0 == ")" }.count)
    }

    func testValuesTravelAsVariablesUnchanged() throws {
        let body = PullRequestBatch.body(for: nasty)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let query = try XCTUnwrap(object["query"] as? String)
        XCTAssertEqual(query, PullRequestBatch.query(count: nasty.count))
        let variables = try XCTUnwrap(object["variables"] as? [String: String])
        XCTAssertEqual(variables.count, nasty.count * 3)
        for (index, request) in nasty.enumerated() {
            XCTAssertEqual(variables["o\(index)"], request.repo.owner)
            XCTAssertEqual(variables["n\(index)"], request.repo.name)
            XCTAssertEqual(variables["b\(index)"], request.branch)
            XCTAssertFalse(query.contains(request.branch), "the branch must not be in the query text")
        }
        XCTAssertFalse(query.contains("we\"ird") || query.contains("日本") || query.contains("evil"))
    }

    func testTheBodyIsStable() {
        XCTAssertEqual(PullRequestBatch.body(for: nasty), PullRequestBatch.body(for: nasty))
    }
}

// MARK: - The answer

final class PullRequestBatchParseTests: XCTestCase {
    private func parse(_ json: String, count: Int) -> [Int: PullRequests.Lookup]? {
        PullRequestBatch.parse(Data(json.utf8), count: count)
    }

    private func node(_ number: Int, _ state: String, draft: Bool = false, review: String? = nil) -> String {
        let reviewJSON = review.map { "\"\($0)\"" } ?? "null"
        return #"{"number":\#(number),"state":"\#(state)","isDraft":\#(draft),"reviewDecision":\#(reviewJSON),"url":"https://github.com/o/n/pull/\#(number)","title":"PR \#(number)"}"#
    }

    private func pr(_ number: Int, _ status: PullRequest.Status, review: PullRequest.Review? = nil) -> PullRequests.Lookup {
        .found(PullRequest(number: number, status: status, review: review,
                           url: URL(string: "https://github.com/o/n/pull/\(number)")!, title: "PR \(number)"))
    }

    func testEveryAliasAnswered() {
        let json = """
        {"data":{
          "r0":{"pullRequests":{"nodes":[\(node(3, "CLOSED")),\(node(2, "OPEN", review: "APPROVED"))]}},
          "r1":{"pullRequests":{"nodes":[]}},
          "r2":{"pullRequests":{"nodes":[\(node(9, "OPEN", draft: true, review: "CHANGES_REQUESTED"))]}},
          "r3":{"pullRequests":{"nodes":[\(node(7, "MERGED", review: "APPROVED")),\(node(5, "CLOSED"))]}}
        }}
        """
        XCTAssertEqual(parse(json, count: 4), [
            0: pr(2, .open, review: .approved),   // an open PR wins over a newer closed one
            1: PullRequests.Lookup.none,
            2: pr(9, .draft),                      // no review for a draft, as `parse` does
            3: pr(7, .merged),                     // else the newest; a decided PR has no review
        ])
    }

    func testAnAliasWithAnErrorIsLeftOut() {
        let json = """
        {"data":{"r0":{"pullRequests":{"nodes":[\(node(1, "OPEN"))]}},"r1":null,
                 "r2":{"pullRequests":{"nodes":[null,\(node(4, "OPEN"))]}}},
         "errors":[{"type":"NOT_FOUND","path":["r1"],"message":"Could not resolve to a Repository"},
                   {"type":"FORBIDDEN","path":["r2","pullRequests","nodes",0],"message":"no"}]}
        """
        // r2 has data, but an error inside it: its answer is not trusted.
        XCTAssertEqual(parse(json, count: 3), [0: pr(1, .open)])
    }

    func testANullOrMisshapenAliasIsLeftOut() {
        let json = """
        {"data":{"r0":null,"r1":{"pullRequests":null},"r2":{"pullRequests":{}},"r3":{},
                 "r4":{"pullRequests":{"nodes":"x"}},"r6":{"pullRequests":{"nodes":[]}}}}
        """
        XCTAssertEqual(parse(json, count: 7), [6: PullRequests.Lookup.none])
    }

    func testANodeWithoutItsFieldsIsSkippedAsParseSkipsIt() {
        let json = """
        {"data":{"r0":{"pullRequests":{"nodes":[{"number":8,"state":"OPEN"},{"number":"x","state":"OPEN","url":"u"},
          {"number":7,"state":"WEIRD","url":"https://github.com/o/n/pull/7"},\(node(6, "MERGED"))]}}}}
        """
        XCTAssertEqual(parse(json, count: 1), [0: pr(6, .merged)])
    }

    func testAnAnswerAsAWholeNotUnderstood() {
        for json in [
            "", "not json", "[]", "{}", #"{"data":null}"#, #"{"data":[]}"#,
            #"{"data":null,"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#,
            #"{"data":{"r0":null},"errors":[{"message":"an error without a path"}]}"#,
            #"{"data":{"r0":null},"errors":{"path":["r0"]}}"#,
            #"{"data":{"r0":null},"errors":[{"path":[]}]}"#,
            #"{"message":"Bad credentials","documentation_url":"https://docs.github.com/rest"}"#,
        ] {
            XCTAssertNil(parse(json, count: 1), json)
        }
        XCTAssertEqual(parse(#"{"data":{"r0":{"pullRequests":{"nodes":[]}}},"errors":null}"#, count: 1),
                       [0: PullRequests.Lookup.none])
    }

    func testTheOutcomeOfACall() {
        let answer = Data(#"{"data":{"r0":{"pullRequests":{"nodes":[]}},"r1":null},"errors":[{"path":["r1"]}]}"#.utf8)
        // gh exits 1 when an alias has an error, and still prints the answer.
        XCTAssertEqual(PullRequestBatch.outcome(stdout: answer, succeeded: false, timedOut: false, count: 2),
                       .answered([0: PullRequests.Lookup.none]))
        XCTAssertEqual(PullRequestBatch.outcome(stdout: answer, succeeded: false, timedOut: true, count: 2), .unreachable)
        XCTAssertEqual(PullRequestBatch.outcome(stdout: Data(), succeeded: false, timedOut: false, count: 2), .unreachable)
        XCTAssertEqual(PullRequestBatch.outcome(stdout: Data("<html>502</html>".utf8), succeeded: false, timedOut: false, count: 2),
                       .unreachable)
        XCTAssertEqual(PullRequestBatch.outcome(stdout: Data(#"{"message":"Bad credentials"}"#.utf8), succeeded: false,
                                                timedOut: false, count: 2), .notUnderstood)
        XCTAssertEqual(PullRequestBatch.outcome(stdout: Data("garbage".utf8), succeeded: true, timedOut: false, count: 2),
                       .notUnderstood)
    }
}

// MARK: - gh pr list and the batch agree

final class PullRequestBatchEquivalenceTests: XCTestCase {
    /// Recorded on 2026-11-27 with gh 2.106: `gh pr list --head <branch> --state all --limit 5
    /// --json number,state,isDraft,reviewDecision,url,title` per branch, and one batch of the
    /// same five through `gh api graphql` (the query `PullRequestBatch.query` builds).
    private let recordedLists = [
        #"[{"isDraft":false,"number":15005,"reviewDecision":"REVIEW_REQUIRED","state":"CLOSED","title":"fix: handle nil values in nested array field parsing","url":"https://github.com/cli/cli/pull/15005"},{"isDraft":false,"number":14872,"reviewDecision":"REVIEW_REQUIRED","state":"CLOSED","title":"Remove memory.md and SECURITY.md files","url":"https://github.com/cli/cli/pull/14872"},{"isDraft":false,"number":14481,"reviewDecision":"REVIEW_REQUIRED","state":"CLOSED","title":"Authorship and follow-up","url":"https://github.com/cli/cli/pull/14481"},{"isDraft":false,"number":14471,"reviewDecision":"REVIEW_REQUIRED","state":"CLOSED","title":"Create generator-generic-ossf-slsa3-publish.yml","url":"https://github.com/cli/cli/pull/14471"},{"isDraft":false,"number":14310,"reviewDecision":"REVIEW_REQUIRED","state":"CLOSED","title":"Support forced pinned extension installations","url":"https://github.com/cli/cli/pull/14310"}]"#,
        #"[{"isDraft":true,"number":15128,"reviewDecision":"REVIEW_REQUIRED","state":"CLOSED","title":"Add owner information to config documentation","url":"https://github.com/cli/cli/pull/15128"},{"isDraft":false,"number":15003,"reviewDecision":"REVIEW_REQUIRED","state":"CLOSED","title":"Create READ ME","url":"https://github.com/cli/cli/pull/15003"},{"isDraft":false,"number":14873,"reviewDecision":"REVIEW_REQUIRED","state":"CLOSED","title":"Update install_linux.md","url":"https://github.com/cli/cli/pull/14873"},{"isDraft":false,"number":14664,"reviewDecision":"REVIEW_REQUIRED","state":"CLOSED","title":"Update snap installation instructions","url":"https://github.com/cli/cli/pull/14664"},{"isDraft":true,"number":14575,"reviewDecision":"REVIEW_REQUIRED","state":"CLOSED","title":"Rename SECURITY.md to SECURITY.mdbrew install gh","url":"https://github.com/cli/cli/pull/14575"}]"#,
        #"[{"isDraft":false,"number":66,"reviewDecision":"","state":"OPEN","title":"perf: a performance pass over polls, terminals, AI summaries and PR lookups","url":"https://github.com/marcello-a/Planchette/pull/66"}]"#,
        #"[{"isDraft":false,"number":65,"reviewDecision":"","state":"MERGED","title":"fix: review of the unreleased changes before 0.2.56","url":"https://github.com/marcello-a/Planchette/pull/65"}]"#,
        "[]",
    ]

    private let recordedBatch = #"""
    {"data":{"r0":{"pullRequests":{"nodes":[{"number":15005,"state":"CLOSED","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","url":"https://github.com/cli/cli/pull/15005","title":"fix: handle nil values in nested array field parsing"},{"number":14872,"state":"CLOSED","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","url":"https://github.com/cli/cli/pull/14872","title":"Remove memory.md and SECURITY.md files"},{"number":14481,"state":"CLOSED","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","url":"https://github.com/cli/cli/pull/14481","title":"Authorship and follow-up"},{"number":14471,"state":"CLOSED","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","url":"https://github.com/cli/cli/pull/14471","title":"Create generator-generic-ossf-slsa3-publish.yml"},{"number":14310,"state":"CLOSED","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","url":"https://github.com/cli/cli/pull/14310","title":"Support forced pinned extension installations"}]}},"r1":{"pullRequests":{"nodes":[{"number":15128,"state":"CLOSED","isDraft":true,"reviewDecision":"REVIEW_REQUIRED","url":"https://github.com/cli/cli/pull/15128","title":"Add owner information to config documentation"},{"number":15003,"state":"CLOSED","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","url":"https://github.com/cli/cli/pull/15003","title":"Create READ ME"},{"number":14873,"state":"CLOSED","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","url":"https://github.com/cli/cli/pull/14873","title":"Update install_linux.md"},{"number":14664,"state":"CLOSED","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","url":"https://github.com/cli/cli/pull/14664","title":"Update snap installation instructions"},{"number":14575,"state":"CLOSED","isDraft":true,"reviewDecision":"REVIEW_REQUIRED","url":"https://github.com/cli/cli/pull/14575","title":"Rename SECURITY.md to SECURITY.mdbrew install gh"}]}},"r2":{"pullRequests":{"nodes":[{"number":66,"state":"OPEN","isDraft":false,"reviewDecision":null,"url":"https://github.com/marcello-a/Planchette/pull/66","title":"perf: a performance pass over polls, terminals, AI summaries and PR lookups"}]}},"r3":{"pullRequests":{"nodes":[{"number":65,"state":"MERGED","isDraft":false,"reviewDecision":null,"url":"https://github.com/marcello-a/Planchette/pull/65","title":"fix: review of the unreleased changes before 0.2.56"}]}},"r4":{"pullRequests":{"nodes":[]}}}}
    """#

    private func single(_ json: String) -> PullRequests.Lookup {
        PullRequests.parse(Data(json.utf8)).map(PullRequests.Lookup.found) ?? .none
    }

    func testRecordedAnswersAgree() throws {
        let batch = try XCTUnwrap(PullRequestBatch.parse(Data(recordedBatch.utf8), count: recordedLists.count))
        XCTAssertEqual(batch.count, recordedLists.count)
        for (index, list) in recordedLists.enumerated() {
            XCTAssertEqual(batch[index], single(list), "branch \(index)")
        }
        guard case .found(let open) = batch[2] else { return XCTFail("PR 66") }
        XCTAssertEqual(open.number, 66)
        XCTAssertEqual(open.status, .open)
        XCTAssertNil(open.review)
    }

    /// The same PRs rendered both ways — gh's list (`reviewDecision` "" for none, keys
    /// sorted) and GraphQL nodes (null) — for every mix of states, drafts and reviews a
    /// seeded generator makes: both parsers pick the same PR, every time.
    func testGeneratedAnswersAgree() throws {
        var generator = SeededGenerator(seed: 0x9E3779B97F4A7C15)
        let states = ["OPEN", "MERGED", "CLOSED"]
        let reviews: [String?] = [nil, "APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED"]
        var lists: [String] = []
        var nodes: [String] = []
        for _ in 0..<300 {
            let count = Int(generator.next() % 6)
            var listItems: [String] = []
            var nodeItems: [String] = []
            for position in 0..<count {
                let number = 1000 - position * 7 - Int(generator.next() % 5)
                let state = states[Int(generator.next() % 3)]
                let draft = generator.next() % 4 == 0
                let review = reviews[Int(generator.next() % 4)]
                let title = "PR \(number) \"quoted\" ü"
                let titleJSON = String(decoding: try JSONSerialization.data(withJSONObject: [title]), as: UTF8.self)
                    .dropFirst().dropLast()
                let url = "https://github.com/o/n/pull/\(number)"
                listItems.append(#"{"isDraft":\#(draft),"number":\#(number),"reviewDecision":"\#(review ?? "")","state":"\#(state)","title":\#(titleJSON),"url":"\#(url)"}"#)
                nodeItems.append(#"{"number":\#(number),"state":"\#(state)","isDraft":\#(draft),"reviewDecision":\#(review.map { "\"\($0)\"" } ?? "null"),"url":"\#(url)","title":\#(titleJSON)}"#)
            }
            lists.append("[" + listItems.joined(separator: ",") + "]")
            nodes.append("[" + nodeItems.joined(separator: ",") + "]")
        }
        let aliases = nodes.enumerated().map { #""r\#($0.offset)":{"pullRequests":{"nodes":\#($0.element)}}"# }
        let batch = try XCTUnwrap(PullRequestBatch.parse(Data(("{\"data\":{" + aliases.joined(separator: ",") + "}}").utf8),
                                                         count: lists.count))
        for (index, list) in lists.enumerated() {
            XCTAssertEqual(batch[index], single(list), list)
        }
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

// MARK: - The sweep

final class PullRequestBatchSweepTests: XCTestCase {
    private func checkout(_ index: Int, branch: String? = nil) -> PullRequests.Checkout {
        PullRequests.Checkout(directory: "/work/\(index)", branch: branch ?? "feature-\(index)", ids: [UUID()])
    }

    /// An answer that names its request, so a mixed-up alias shows.
    private func answer(for request: PullRequestBatch.Request) -> PullRequests.Lookup {
        .found(PullRequest(number: abs(request.branch.hashValue % 100_000), status: .open, review: nil,
                           url: URL(string: "https://github.com/\(request.repo.owner)/\(request.repo.name)/pull/1")!,
                           title: request.branch))
    }

    func testThePlanSplitsAndShares() {
        let resolutions: [RepoResolution] = (0..<45).map { $0 == 7 ? .uncertain("alias") : .github(repo("o", "n")) }
        var branches = (0..<45).map { "b\($0)" }
        branches[3] = "b2"          // a second clone on b2 shares its alias
        branches[9] = "fork:b9"     // left to gh
        let plan = PullRequestBatch.plan(resolutions: resolutions, branches: branches)
        XCTAssertEqual(plan.calls.map(\.count), [20, 20, 2])
        XCTAssertEqual(Set(plan.calls.flatMap { $0 }).count, 42)
        XCTAssertEqual(plan.alone.keys.sorted(), [7, 9])
        XCTAssertEqual(plan.requestOf[3], plan.requestOf[2])
        XCTAssertNil(plan.requestOf[7])
        XCTAssertEqual(PullRequestBatch.plan(resolutions: resolutions, branches: branches, cap: 50).calls.map(\.count), [42])
        XCTAssertEqual(PullRequestBatch.plan(resolutions: [], branches: []), PullRequestBatch.Plan())
    }

    func testASweepAsksInCallsOfTheCap() {
        let checkouts = (0..<45).map { checkout($0) }
        var calls: [[PullRequestBatch.Request]] = []
        var singles: [String] = []
        let lookups = PullRequests.lookup(
            checkouts, resolutions: checkouts.map { _ in .github(repo("o", "n")) },
            call: { requests in
                calls.append(requests)
                return .answered(Dictionary(uniqueKeysWithValues: requests.enumerated().map { ($0.offset, self.answer(for: $0.element)) }))
            },
            single: { singles.append($0.directory); return .failed })
        XCTAssertEqual(calls.map(\.count), [20, 20, 5])
        XCTAssertEqual(singles, [])
        for (index, lookup) in lookups.enumerated() {
            XCTAssertEqual(lookup, answer(for: .init(repo: repo("o", "n"), branch: "feature-\(index)")), "checkout \(index)")
        }
    }

    func testAnAliasThatFailsFallsBackAloneAndOnlyIt() {
        let checkouts = (0..<5).map { checkout($0) }
        var singles: [Int] = []
        let lookups = PullRequests.lookup(
            checkouts,
            resolutions: [.github(repo("o", "n")), .github(repo("gone", "repo")), .uncertain("GHE"),
                          .github(repo("o", "n")), .github(repo("o", "n"))],
            call: { requests in
                XCTAssertEqual(requests.map(\.branch), ["feature-0", "feature-1", "feature-3", "feature-4"])
                // The repository of alias 1 is gone; alias 3 has no PR.
                return .answered([0: self.answer(for: requests[0]), 2: self.answer(for: requests[2]), 3: .none])
            },
            single: { checkout in
                singles.append(Int(checkout.directory.split(separator: "/").last!)!)
                return checkout.directory == "/work/1" ? .failed : .none
            })
        XCTAssertEqual(singles, [1, 2])
        XCTAssertEqual(lookups, [answer(for: .init(repo: repo("o", "n"), branch: "feature-0")), .failed, .none,
                                 answer(for: .init(repo: repo("o", "n"), branch: "feature-3")), .none])
    }

    func testAWholeCallThatFails() {
        let checkouts = (0..<25).map { checkout($0) }
        let resolutions: [RepoResolution] = checkouts.map { _ in .github(repo("o", "n")) }
        var singles = 0
        // Not reached: every checkout of the call failed, none asked again.
        var lookups = PullRequests.lookup(checkouts, resolutions: resolutions,
                                          call: { _ in .unreachable }, single: { _ in singles += 1; return .none })
        XCTAssertEqual(lookups, Array(repeating: .failed, count: 25))
        XCTAssertEqual(singles, 0)
        // Not understood: the first call's checkouts are asked alone, the second call answered.
        var call = 0
        lookups = PullRequests.lookup(
            checkouts, resolutions: resolutions,
            call: { requests in
                call += 1
                return call == 1 ? .notUnderstood
                    : .answered(Dictionary(uniqueKeysWithValues: requests.indices.map { ($0, PullRequests.Lookup.none) }))
            },
            single: { _ in singles += 1; return .failed })
        XCTAssertEqual(singles, 20)
        XCTAssertEqual(lookups, Array(repeating: .failed, count: 20) + Array(repeating: .none, count: 5))
    }

    func testNothingCertainMeansNoCall() {
        let checkouts = (0..<3).map { checkout($0) }
        let lookups = PullRequests.lookup(
            checkouts, resolutions: checkouts.map { _ in .uncertain("GH_REPO is set") },
            call: { _ in XCTFail("no call"); return .unreachable }, single: { _ in .none })
        XCTAssertEqual(lookups, [.none, .none, .none])
    }

    func testAFallbackIsNewsOncePerReason() {
        var notes = FallbackNotes()
        XCTAssertTrue(notes.isNews(key: "/a", reason: "GHE"))
        XCTAssertFalse(notes.isNews(key: "/a", reason: "GHE"))
        XCTAssertTrue(notes.isNews(key: "/b", reason: "GHE"))
        XCTAssertTrue(notes.isNews(key: "/a", reason: "an alias"))
        XCTAssertFalse(notes.isNews(key: "/a", reason: nil))
        XCTAssertTrue(notes.isNews(key: "/a", reason: "an alias"))
    }
}

// MARK: - Live

/// Asks GitHub for real: `PLANCHETTE_LIVE_GH=1 swift test --filter PullRequestBatchLiveTests`.
/// Compares, for recent branches of this repository (or `PLANCHETTE_LIVE_GH_DIR`), what
/// `gh pr list` in the checkout says with what the batch says.
final class PullRequestBatchLiveTests: XCTestCase {
    func testTheBatchAgreesWithGhPrList() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["PLANCHETTE_LIVE_GH"] == "1", "set PLANCHETTE_LIVE_GH=1 to ask GitHub")
        let gh = try XCTUnwrap(PullRequests.ghPath(), "gh is not installed")
        let here = (#filePath as NSString).deletingLastPathComponent
        let directory = environment["PLANCHETTE_LIVE_GH_DIR"] ?? here
        let root = try XCTUnwrap(Titles.checkoutRoot(forDirectory: directory))
        let home = environment["HOME"] ?? NSHomeDirectory()
        let outer = GhRepoResolver.outerRules(
            paths: GhRepoResolver.outerConfigPaths(environment: environment, home: home), home: home)
        let resolution = GhRepoResolver.resolve(checkoutRoot: root, outer: outer)
        guard case .github(let resolved) = resolution else {
            throw XCTSkip("\(root) falls back (\(resolution)): nothing to compare")
        }

        let listed = try XCTUnwrap(Subprocess.run(
            gh, ["pr", "list", "--state", "all", "--limit", "12", "--json", "headRefName"], in: root, timeout: 60))
        XCTAssertTrue(listed.succeeded, listed.stderrString)
        let heads = (try JSONSerialization.jsonObject(with: listed.stdout) as? [[String: Any]] ?? [])
            .compactMap { $0["headRefName"] as? String }
        var branches = [String]()
        for branch in heads + [Titles.gitBranch(forDirectory: root) ?? "", "main", "planchette-live-no-such-branch-\(UUID().uuidString.prefix(8))"]
        where !branch.isEmpty && !branches.contains(branch) {
            branches.append(branch)
        }
        let checkouts = branches.map { PullRequests.Checkout(directory: root, branch: $0, ids: []) }
        let alone = checkouts.map { PullRequests.lookup(branch: $0.branch, in: $0.directory) }
        let batched = PullRequests.lookup(checkouts, resolutions: checkouts.map { _ in resolution },
                                          call: PullRequests.callGraphQL,
                                          single: { XCTFail("\($0.branch) fell back"); return .failed })
        var found = 0
        for (index, branch) in branches.enumerated() {
            XCTAssertNotEqual(alone[index], .failed, "gh pr list failed for \(branch)")
            XCTAssertEqual(batched[index], alone[index], branch)
            if case .found(let pr) = batched[index] {
                found += 1
                XCTAssertTrue(pr.url.absoluteString.lowercased()
                    .hasPrefix("https://github.com/\(resolved.owner)/\(resolved.name)/pull/".lowercased()), pr.url.absoluteString)
            }
        }
        // The app's own entry point: the same answers.
        XCTAssertEqual(PullRequests.lookup(checkouts), alone)
        print("live: \(resolved.owner)/\(resolved.name), \(branches.count) branches, \(found) with a PR, all equal")
    }

    /// The installed gh is the oracle for the repository choice: for every config, the
    /// repository `gh pr list` asks (read from `GH_DEBUG=api`) is the one the resolver names,
    /// wherever the resolver is certain.
    func testTheResolverPicksWhatGhPicks() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["PLANCHETTE_LIVE_GH"] == "1", "set PLANCHETTE_LIVE_GH=1 to ask GitHub")
        let gh = try XCTUnwrap(PullRequests.ghPath(), "gh is not installed")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("planchette-ghpick-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try fixtureGit(["init", "-q"], in: dir)
        let planchette = "https://github.com/marcello-a/Planchette.git"
        let cli = "git@github.com:cli/cli.git"
        let configs: [(String, String)] = [
            ("origin", "[remote \"origin\"]\n\turl = \(planchette)\n"),
            ("origin+upstream", "[remote \"origin\"]\n\turl = \(planchette)\n[remote \"upstream\"]\n\turl = \(cli)\n"),
            ("origin base", "[remote \"origin\"]\n\turl = \(planchette)\n\tgh-resolved = base\n[remote \"upstream\"]\n\turl = \(cli)\n"),
            ("upstream base", "[remote \"origin\"]\n\turl = \(planchette)\n[remote \"upstream\"]\n\turl = \(cli)\n\tgh-resolved = base\n"),
            ("origin owner/repo", "[remote \"origin\"]\n\turl = \(planchette)\n\tgh-resolved = octocat/Hello-World\n[remote \"upstream\"]\n\turl = \(cli)\n"),
            ("both resolved", "[remote \"origin\"]\n\turl = \(planchette)\n\tgh-resolved = octocat/Hello-World\n[remote \"upstream\"]\n\turl = \(cli)\n\tgh-resolved = base\n"),
            ("github+origin", "[remote \"origin\"]\n\turl = \(planchette)\n[remote \"github\"]\n\turl = https://github.com/cli/cli\n"),
            ("Upstream", "[remote \"origin\"]\n\turl = \(planchette)\n[remote \"Upstream\"]\n\turl = https://github.com/cli/cli/\n"),
            ("old dotted", "[remote.upstream]\n\turl = \(cli)\n[remote \"origin\"]\n\turl = \(planchette)\n"),
            ("local+upstream", "[remote \"origin\"]\n\turl = /tmp/x\n[remote \"upstream\"]\n\turl = https://github.com/cli/cli.git\n"),
            ("scp", "[remote \"origin\"]\n\turl = git@github.com:cli/cli\n"),
            ("ssh port", "[remote \"origin\"]\n\turl = ssh://git@ssh.github.com:443/cli/cli.git\n"),
            ("www", "[remote \"origin\"]\n\turl = https://www.github.com/cli/cli.git\n"),
            ("quoted url", "[remote \"origin\"]\n\turl = \"https://github.com/cli/cli.git\" ; comment\n"),
            ("foo+bar", "[remote \"foo\"]\n\turl = \(planchette)\n[remote \"bar\"]\n\turl = \(cli)\n"),
            ("alias", "[remote \"origin\"]\n\turl = git@github.com-work:cli/cli.git\n"),
            ("local pushurl", "[remote \"origin\"]\n\turl = /tmp/x\n\tpushurl = https://github.com/cli/cli.git\n"),
        ]
        var compared = 0
        for (name, remotes) in configs {
            let config = "[core]\n\trepositoryformatversion = 0\n\tbare = false\n" + remotes
            try config.write(toFile: "\(dir)/.git/config", atomically: true, encoding: .utf8)
            let resolution = GhRepoResolver.resolve(checkoutRoot: dir, outer: .init())
            let run = try XCTUnwrap(Subprocess.run(
                "/usr/bin/env",
                ["-u", "GH_REPO", "-u", "GH_HOST", "GH_DEBUG=api", gh, "pr", "list", "--head", "x",
                 "--state", "all", "--limit", "1", "--json", "number"],
                in: dir, timeout: 60, stderr: .capture))
            let picked = run.stderrString.components(separatedBy: "\n")
                .first { $0.hasPrefix("GraphQL variables: ") }
                .flatMap { line -> GitHubRepo? in
                    let json = Data(line.dropFirst("GraphQL variables: ".count).utf8)
                    guard let variables = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                          let owner = variables["owner"] as? String, let repo = variables["repo"] as? String
                    else { return nil }
                    return GitHubRepo(owner: owner, name: repo)
                }
            if case .github(let ours) = resolution {
                XCTAssertEqual(ours, picked, name)
                compared += 1
            }
            print("gh pick \(name): gh \(picked.map { "\($0.owner)/\($0.name)" } ?? "none"), resolver \(resolution)")
        }
        XCTAssertEqual(compared, 14)
    }
}
