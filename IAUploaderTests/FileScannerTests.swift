import XCTest
@testable import ArchiveUploader

final class FileScannerTests: XCTestCase {
    func testPreservesNestedFolderStructure() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("My Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub dir"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appendingPathComponent("readme.txt"))
        try Data("b".utf8).write(to: folder.appendingPathComponent("sub dir").appendingPathComponent("img 1.jpg"))
        try Data("c".utf8).write(to: root.appendingPathComponent("standalone.pdf"))

        let result = FileScanner.scan(urls: [folder], includeHidden: false)
        let paths = Set(result.files.map(\.relativePath))
        XCTAssertEqual(paths, [
            "My Folder/readme.txt",
            "My Folder/sub dir/img 1.jpg"
        ])
    }

    func testHiddenFilesRespected() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let hidden = root.appendingPathComponent(".secret")
        try Data("x".utf8).write(to: hidden)
        try Data("y".utf8).write(to: root.appendingPathComponent("visible.txt"))

        let withoutHidden = FileScanner.scan(urls: [root], includeHidden: false)
        XCTAssertEqual(withoutHidden.files.map(\.relativePath), ["\(root.lastPathComponent)/visible.txt"])

        let withHidden = FileScanner.scan(urls: [root], includeHidden: true)
        XCTAssertEqual(Set(withHidden.files.map(\.relativePath)), Set([
            "\(root.lastPathComponent)/.secret",
            "\(root.lastPathComponent)/visible.txt"
        ]))
    }
}
