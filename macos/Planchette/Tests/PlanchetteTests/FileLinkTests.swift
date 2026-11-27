import XCTest
@testable import Planchette

final class FileLinkTests: XCTestCase {
    // MARK: parse

    func testABareRelativePathWithALine() {
        XCTAssertEqual(FileLink.parse("src/Module/Foo.php:42"),
                       FileLink(path: "src/Module/Foo.php", line: 42, column: nil))
    }

    func testLineAndColumn() {
        XCTAssertEqual(FileLink.parse("./web/app.ts:3:7"),
                       FileLink(path: "./web/app.ts", line: 3, column: 7))
    }

    func testAPathWithoutAPosition() {
        XCTAssertEqual(FileLink.parse("/var/www/html/src/Foo.php"),
                       FileLink(path: "/var/www/html/src/Foo.php", line: nil, column: nil))
    }

    func testRootedForms() {
        XCTAssertEqual(FileLink.parse("~/notes/todo.md:2")?.path, "~/notes/todo.md")
        XCTAssertEqual(FileLink.parse("../shared/a.swift:9")?.line, 9)
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertEqual(FileLink.parse("  src/Foo.php:1  ")?.path, "src/Foo.php")
    }

    func testLineZeroMeansNoPosition() {
        XCTAssertEqual(FileLink.parse("src/Foo.php:0:5"),
                       FileLink(path: "src/Foo.php", line: nil, column: nil))
    }

    func testURLsAreNotPaths() {
        XCTAssertNil(FileLink.parse("https://example.com/a/b"))
        XCTAssertNil(FileLink.parse("file:///Users/me/a.txt"))
        XCTAssertNil(FileLink.parse("mailto:a@b.c"))
        XCTAssertNil(FileLink.parse("//host/share"))
    }

    func testTextWithoutASlashIsNotAPath() {
        XCTAssertNil(FileLink.parse("Foo.php:42"))
        XCTAssertNil(FileLink.parse(""))
    }

    func testADirectoryIsNotAFileLink() {
        XCTAssertNil(FileLink.parse("src/Module/"))
    }

    // MARK: resolve

    private func resolve(_ path: String, cwd: String? = "/repo", project: String? = "/repo",
                         files: Set<String>) -> String? {
        FileLink.resolve(path, cwd: cwd, project: project, home: "/Users/me", isFile: files.contains)
    }

    func testARelativePathResolvesFromTheTerminalsFolder() {
        XCTAssertEqual(resolve("src/Foo.php", cwd: "/repo/sub", files: ["/repo/sub/src/Foo.php"]),
                       "/repo/sub/src/Foo.php")
    }

    func testThenFromTheProject() {
        XCTAssertEqual(resolve("src/Foo.php", cwd: "/repo/tests", files: ["/repo/src/Foo.php"]),
                       "/repo/src/Foo.php")
    }

    func testDotSegmentsAreStandardized() {
        XCTAssertEqual(resolve("./src/../src/Foo.php", files: ["/repo/src/Foo.php"]), "/repo/src/Foo.php")
    }

    func testAnAbsolutePathThatExistsIsKept() {
        XCTAssertEqual(resolve("/etc/hosts", files: ["/etc/hosts"]), "/etc/hosts")
    }

    func testTheHomeIsExpanded() {
        XCTAssertEqual(resolve("~/notes/todo.md", files: ["/Users/me/notes/todo.md"]),
                       "/Users/me/notes/todo.md")
    }

    func testAContainerPathFindsItsFileInTheProject() {
        XCTAssertEqual(
            resolve("/var/www/html/src/Module/Foo.php",
                    files: ["/repo/src/Module/Foo.php", "/repo/Module/Foo.php"]),
            "/repo/src/Module/Foo.php", "the longest tail that exists wins")
    }

    func testATailKeepsTwoParts() {
        XCTAssertNil(resolve("/var/www/html/Foo.php", files: ["/repo/Foo.php"]),
                     "a bare file name never stands for a file of the same name elsewhere")
    }

    func testNothingFoundIsNil() {
        XCTAssertNil(resolve("src/Missing.php", files: []))
        XCTAssertNil(resolve("src/Foo.php", cwd: nil, project: nil, files: ["/repo/src/Foo.php"]))
    }

    // MARK: open requests

    private func ide(_ bundleID: String) -> IDE {
        IDEs.ide(bundleID: bundleID)!
    }

    func testJetBrainsUsesItsLauncherWithLineAndColumn() {
        XCTAssertEqual(
            FileOpenRequest.make(file: "/repo/src/Foo.php", line: 42, column: 7,
                                 ide: ide("com.jetbrains.PhpStorm"),
                                 appPath: "/Applications/PhpStorm.app",
                                 executable: "/Applications/PhpStorm.app/Contents/MacOS/phpstorm"),
            .launcher(executable: "/Applications/PhpStorm.app/Contents/MacOS/phpstorm",
                      arguments: ["--line", "42", "--column", "7", "/repo/src/Foo.php"]))
    }

    func testJetBrainsWithoutALineOpensTheFile() {
        XCTAssertEqual(
            FileOpenRequest.make(file: "/repo/a.php", line: nil, column: nil,
                                 ide: ide("com.jetbrains.intellij"), appPath: "/A.app", executable: "/A.app/x"),
            .launcher(executable: "/A.app/x", arguments: ["/repo/a.php"]))
    }

    func testVSCodeFamilyUsesItsURL() {
        let request = FileOpenRequest.make(
            file: "/repo/my dir/a.ts", line: 3, column: 7, ide: ide("com.microsoft.VSCode"),
            appPath: "/A.app", executable: nil)
        XCTAssertEqual(request, .url(URL(string: "vscode://file/repo/my%20dir/a.ts:3:7")!))
        XCTAssertEqual(
            FileOpenRequest.make(file: "/r/a.ts", line: 1, column: nil,
                                 ide: ide("com.todesktop.230313mzl4w4u92"), appPath: "/A.app", executable: nil),
            .url(URL(string: "cursor://file/r/a.ts:1")!))
    }

    func testAnIDEWithoutALineSyntaxOpensThePlainFile() {
        XCTAssertEqual(
            FileOpenRequest.make(file: "/r/a.ts", line: 1, column: nil, ide: ide("com.jetbrains.PhpStorm"),
                                 appPath: "/A.app", executable: nil),
            .plain, "no executable in the bundle: open the file at least")
    }
}
