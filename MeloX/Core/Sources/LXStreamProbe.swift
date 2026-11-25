import Foundation

/// What a stream URL answers when asked for its first two bytes.
///
/// A source reports success for whatever its backend returned: an address
/// that has expired, a page of JSON, QQ's short preview clip. Asking the
/// address itself, before the player is pointed at it, is the only way to
/// tell.
nonisolated struct LXStreamProbe: Sendable {
    /// The size of the whole file, when the server states it.
    let length: Int64?
    let contentType: String?

    static func run(
        _ url: URL,
        headers: [String: String] = [:],
        session: URLSession,
        timeout: TimeInterval = 8
    ) async throws -> LXStreamProbe {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        // Only the headers are wanted. A server that ignores the range
        // would otherwise send the whole file.
        let (bytes, response) = try await session.bytes(for: request)
        bytes.task.cancel()

        guard let http = response as? HTTPURLResponse else {
            throw LXPlaybackError.unplayableStream("没有收到有效响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LXPlaybackError.unplayableStream(
                "HTTP \(http.statusCode)"
            )
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if let contentType,
           contentType.hasPrefix("text/")
            || contentType.hasSuffix("json")
            || contentType.hasSuffix("xml")
            || contentType.hasSuffix("ogg") {
            throw LXPlaybackError.unplayableStream(contentType)
        }

        return LXStreamProbe(
            length: Self.totalLength(of: http),
            contentType: contentType
        )
    }

    private static func totalLength(of response: HTTPURLResponse) -> Int64? {
        if response.statusCode == 206,
           let range = response.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last,
           let length = Int64(total), length > 0 {
            return length
        }
        guard response.statusCode == 200,
              response.expectedContentLength > 0 else {
            return nil
        }
        return response.expectedContentLength
    }
}
