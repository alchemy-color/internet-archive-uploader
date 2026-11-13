import XCTest
@testable import ArchiveUploader

final class MetadataHeaderBuilderTests: XCTestCase {
    private func metadata() -> ItemMetadata {
        var metadata = ItemMetadata()
        metadata.title = "My Item"
        metadata.identifier = "my-item"
        metadata.descriptionText = "A description"
        metadata.creator = "Ada Lovelace"
        metadata.date = "2026-01-02"
        metadata.subjects = ["history", "computing"]
        metadata.collections = "opensource, community"
        metadata.language = "eng"
        metadata.mediatype = .texts
        return metadata
    }

    func testBasicHeaderShapeAndEncoding() {
        let headers = Dictionary(uniqueKeysWithValues: MetadataHeaderBuilder.headers(for: metadata()))
        XCTAssertEqual(headers["x-archive-meta00-title"], "uri(My%20Item)")
        XCTAssertEqual(headers["x-archive-meta00-mediatype"], "texts")
        XCTAssertEqual(headers["x-archive-meta00-creator"], "uri(Ada%20Lovelace)")
        XCTAssertEqual(headers["x-archive-meta00-date"], "2026-01-02")
        XCTAssertEqual(headers["x-archive-meta00-description"], "uri(A%20description)")
        XCTAssertEqual(headers["x-archive-meta00-language"], "eng")
    }

    func testRepeatedFieldsAreNumbered() {
        let headers = MetadataHeaderBuilder.headers(for: metadata())
        XCTAssertEqual(headers.first(where: { $0.0 == "x-archive-meta00-subject" })?.1, "history")
        XCTAssertEqual(headers.first(where: { $0.0 == "x-archive-meta01-subject" })?.1, "computing")
        XCTAssertEqual(headers.first(where: { $0.0 == "x-archive-meta00-collection" })?.1, "opensource")
        XCTAssertEqual(headers.first(where: { $0.0 == "x-archive-meta01-collection" })?.1, "community")
    }

    func testUnderscoresInKeysAreEscaped() {
        var metadata = metadata()
        metadata.customFields = [CustomMetadataField(key: "custom_field", value: "value")]
        let headers = MetadataHeaderBuilder.headers(for: metadata)
        XCTAssertTrue(headers.contains { $0.0 == "x-archive-meta00-custom--field" })
    }

    func testNonASCIIValuesAreURIEncoded() {
        var metadata = metadata()
        metadata.title = "Café ☃"
        let headers = Dictionary(uniqueKeysWithValues: MetadataHeaderBuilder.headers(for: metadata))
        XCTAssertEqual(headers["x-archive-meta00-title"], "uri(Caf%C3%A9%20%E2%98%83)")
    }

    func testSubjectsAreCappedAtTen() {
        var metadata = metadata()
        metadata.subjects = (1...15).map { "subject-\($0)" }
        let subjectHeaders = MetadataHeaderBuilder.headers(for: metadata).filter { $0.0.contains("-subject") }
        XCTAssertEqual(subjectHeaders.count, 10)
    }

    func testTestItemOverridesCollection() {
        var metadata = metadata()
        metadata.isTestItem = true
        let headers = MetadataHeaderBuilder.headers(for: metadata)
        let collections = headers.filter { $0.0.contains("-collection") }.map(\.1)
        XCTAssertEqual(collections, ["test_collection"])
    }

    func testCustomFieldsMergeWithStandardFields() {
        var metadata = metadata()
        metadata.customFields = [CustomMetadataField(key: "subject", value: "third")]
        let subjects = MetadataHeaderBuilder.headers(for: metadata)
            .filter { $0.0.contains("-subject") }
            .map(\.1)
        XCTAssertEqual(subjects, ["history", "computing", "third"])
    }

    func testNoQuotingForSimpleValues() {
        XCTAssertEqual(MetadataHeaderBuilder.encodeValue("plain-value_1.0"), "plain-value_1.0")
        XCTAssertEqual(MetadataHeaderBuilder.encodeValue("with space"), "uri(with%20space)")
    }
}

final class UploadPlanBuilderTests: XCTestCase {
    private func file(_ name: String, size: Int64 = 10) -> PickedFile {
        PickedFile(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            rootName: nil,
            rawRelativePath: name,
            byteSize: size,
            contentType: "text/plain"
        )
    }

    private func metadata() -> ItemMetadata {
        var metadata = ItemMetadata()
        metadata.title = "Title"
        metadata.identifier = "valid-id"
        metadata.descriptionText = "Description"
        metadata.subjects = ["tag"]
        return metadata
    }

    func testPlanSanitizesAndDeduplicates() {
        let files = [file("my file.txt"), file("my_file.txt")]
        let plan = UploadPlanBuilder.build(
            identifier: "valid-id",
            metadata: metadata(),
            files: files,
            sanitizeNames: true,
            options: .default
        )
        XCTAssertEqual(plan.files.map(\.remotePath), ["my_file.txt", "my_file-2.txt"])
        XCTAssertEqual(plan.totalBytes, 20)
        XCTAssertEqual(plan.identifier, "valid-id")
    }

    func testPlanKeepsNamesWhenSanitizingDisabled() {
        let plan = UploadPlanBuilder.build(
            identifier: "valid-id",
            metadata: metadata(),
            files: [file("my file.txt")],
            sanitizeNames: false,
            options: .default
        )
        XCTAssertEqual(plan.files.first?.remotePath, "my file.txt")
    }
}

final class RetryPolicyTests: XCTestCase {
    func testRetryableStatuses() {
        for status in [408, 425, 429, 500, 502, 503, 504] {
            XCTAssertTrue(RetryPolicy.shouldRetry(status: status), "\(status)")
        }
        for status in [200, 400, 401, 403, 404, 409] {
            XCTAssertFalse(RetryPolicy.shouldRetry(status: status), "\(status)")
        }
    }

    func testDelayGrowsAndIsCapped() {
        XCTAssertLessThanOrEqual(RetryPolicy.delay(forAttempt: 1), 2.7)
        XCTAssertLessThanOrEqual(RetryPolicy.delay(forAttempt: 3), 8.7)
        XCTAssertEqual(RetryPolicy.delay(forAttempt: 20), RetryPolicy.maxDelay)
        XCTAssertEqual(RetryPolicy.delay(forAttempt: 2, retryAfter: 7), 7)
    }

    func testRetryAfterHeader() {
        let response = HTTPURLResponse(
            url: URL(string: "https://s3.us.archive.org")!,
            statusCode: 503,
            httpVersion: nil,
            headerFields: ["Retry-After": "42"]
        )!
        XCTAssertEqual(RetryPolicy.retryAfter(from: response), 42)
    }

    func testRetryableURLErrors() {
        XCTAssertTrue(RetryPolicy.isRetryable(URLError(.timedOut)))
        XCTAssertTrue(RetryPolicy.isRetryable(URLError(.networkConnectionLost)))
        XCTAssertFalse(RetryPolicy.isRetryable(URLError(.cancelled)))
        XCTAssertFalse(RetryPolicy.isRetryable(URLError(.userAuthenticationRequired)))
    }
}

final class S3ErrorParserTests: XCTestCase {
    func testParsesIAS3ErrorXML() {
        let xml = """
        <?xml version='1.0' encoding='UTF-8'?>
        <Error><Code>SlowDown</Code><Message>Please reduce your request rate.</Message><RequestId>abc</RequestId></Error>
        """
        let error = S3ErrorParser.parse(Data(xml.utf8))
        XCTAssertEqual(error?.code, "SlowDown")
        XCTAssertEqual(error?.message, "Please reduce your request rate.")
        XCTAssertEqual(error?.requestID, "abc")
    }

    func testReturnsNilForNonErrorBody() {
        XCTAssertNil(S3ErrorParser.parse(Data("OK".utf8)))
    }
}
