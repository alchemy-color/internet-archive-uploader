import Foundation

struct S3Error: Equatable, Sendable {
    var code: String?
    var message: String?
    var requestID: String?
}

enum S3ErrorParser {
    /// IAS3 returns a small XML document on failure:
    /// `<Error><Code>...</Code><Message>...</Message></Error>`.
    static func parse(_ data: Data) -> S3Error? {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return nil }
        let error = S3Error(
            code: value(of: "Code", in: text),
            message: value(of: "Message", in: text),
            requestID: value(of: "RequestId", in: text)
        )
        if error.code == nil && error.message == nil { return nil }
        return error
    }

    private static func value(of tag: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(tag)>"),
              let end = text.range(of: "</\(tag)>", range: start.upperBound..<text.endIndex) else {
            return nil
        }
        let raw = String(text[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }
}
