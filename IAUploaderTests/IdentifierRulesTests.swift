import XCTest
@testable import ArchiveUploader

final class IdentifierRulesTests: XCTestCase {
    func testValidIdentifiers() {
        XCTAssertNil(IdentifierRules.issue(for: "abcdef"))
        XCTAssertNil(IdentifierRules.issue(for: "my-item_2026.v1"))
        XCTAssertTrue(IdentifierRules.isValid("a1234"))
    }

    func testInvalidIdentifiers() {
        XCTAssertEqual(IdentifierRules.issue(for: ""), .empty)
        XCTAssertEqual(IdentifierRules.issue(for: "abc"), .tooShort)
        XCTAssertEqual(IdentifierRules.issue(for: String(repeating: "a", count: 101)), .tooLong)
        XCTAssertEqual(IdentifierRules.issue(for: "-abcdef"), .mustStartAlphanumeric)
        XCTAssertEqual(IdentifierRules.issue(for: "has space"), .invalidCharacters)
        XCTAssertEqual(IdentifierRules.issue(for: "café-item"), .invalidCharacters)
    }

    func testSuggestionFoldsAccentsAndSpaces() {
        XCTAssertEqual(IdentifierRules.suggestion(from: "Café Society — 1952!"), "cafe-society-1952")
    }

    func testSuggestionTrimsSeparatorsAndPads() {
        XCTAssertEqual(IdentifierRules.suggestion(from: "  Hi  "), "hi-item")
        XCTAssertEqual(IdentifierRules.suggestion(from: "!!!"), "untitled")
        XCTAssertTrue(IdentifierRules.isValid(IdentifierRules.suggestion(from: "!!!")))
    }

    func testSuggestionsAreAlwaysValid() {
        for text in ["A", "UPPER CASE_ok", "日本語", "a/b\\c", "....", String(repeating: "x", count: 300)] {
            XCTAssertTrue(IdentifierRules.isValid(IdentifierRules.suggestion(from: text)), "For input: \(text)")
        }
    }
}

final class RemotePathTests: XCTestCase {
    func testSanitizesSpacesAndSpecialCharacters() {
        XCTAssertEqual(RemotePath.sanitizedComponent("my file #1.pdf"), "my_file_1.pdf")
        XCTAssertEqual(RemotePath.sanitizedComponent("Café  Society.mov"), "Cafe_Society.mov")
    }

    func testPreservesFolderStructure() {
        XCTAssertEqual(RemotePath.sanitized("My Folder/Sub Dir/file one.txt"), "My_Folder/Sub_Dir/file_one.txt")
    }

    func testEncodesEachSegment() {
        XCTAssertEqual(RemotePath.encoded("folder/my file.txt"), "folder/my%20file.txt")
        XCTAssertEqual(RemotePath.encoded("a+b/c&d.txt"), "a%2Bb/c%26d.txt")
    }

    func testDeduplicatesKeys() {
        var used = Set<String>()
        XCTAssertEqual(RemotePath.deduplicated("a.txt", used: &used), "a.txt")
        XCTAssertEqual(RemotePath.deduplicated("a.txt", used: &used), "a-2.txt")
        XCTAssertEqual(RemotePath.deduplicated("a.txt", used: &used), "a-3.txt")
    }

    func testEmptyComponentsBecomeFileName() {
        XCTAssertEqual(RemotePath.sanitizedComponent("..."), "file")
        XCTAssertEqual(RemotePath.sanitizedComponent("___"), "file")
    }
}
