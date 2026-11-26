import Foundation

/// What a stream URL answers when asked for its first bytes.
///
/// A source reports success for whatever its backend returned: an address
/// that has expired, a page of JSON, QQ's short preview clip. Asking the
/// address itself, before the player is pointed at it, is the only way to
/// tell.
nonisolated struct LXStreamProbe: Sendable {
    /// What the first bytes of the file show it to be.
    enum Container: Sendable {
        case flac
        /// MPEG audio, or anything behind an ID3 tag.
        case mpeg
        case mpeg4
        case wave
        /// An Ogg stream, which the player cannot decode.
        case ogg
        /// A page of text where a file should be.
        case text
    }

    /// What a FLAC file states about itself in its first block.
    struct FLACInfo: Sendable, Equatable {
        let sampleRate: Int
        let channelCount: Int
        let bitsPerSample: Int
        /// Nil when the encoder did not record the length.
        let duration: TimeInterval?
    }

    /// The size of the whole file, when the server states it.
    let length: Int64?
    let contentType: String?
    let container: Container?
    let flac: FLACInfo?

    /// Reaches the end of the stream information a FLAC file opens with.
    /// The other containers are told apart within the first twelve bytes.
    private static let headLength = 42

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
        request.setValue(
            "bytes=0-\(headLength - 1)",
            forHTTPHeaderField: "Range"
        )
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        // A server that ignores the range would otherwise send the whole
        // file.
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }

        guard let http = response as? HTTPURLResponse else {
            throw LXPlaybackError.unplayableStream("没有收到有效响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LXPlaybackError.unplayableStream(
                "HTTP \(http.statusCode)"
            )
        }

        var head: [UInt8] = []
        head.reserveCapacity(headLength)
        for try await byte in bytes {
            head.append(byte)
            if head.count == headLength { break }
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let container = container(of: head)

        // The bytes are believed over the label. QQ's own servers send
        // their FLAC files as `audio/x-ogg`, so the label alone would turn
        // every lossless stream away.
        switch container {
        case .ogg:
            throw LXPlaybackError.unplayableStream("ogg")
        case .text:
            throw LXPlaybackError.unplayableStream(contentType ?? "text")
        case .flac, .mpeg, .mpeg4, .wave:
            break
        case nil:
            if let contentType,
               contentType.hasPrefix("text/")
                || contentType.hasSuffix("json")
                || contentType.hasSuffix("xml") {
                throw LXPlaybackError.unplayableStream(contentType)
            }
        }

        return LXStreamProbe(
            length: totalLength(of: http),
            contentType: contentType,
            container: container,
            flac: container == .flac ? flacInfo(in: head) : nil
        )
    }

    /// Reads the STREAMINFO block, which the format requires to come first:
    /// after the four-byte marker and a four-byte block header, ten bytes of
    /// block and frame sizes, then 20 bits of sample rate, 3 of channel
    /// count less one, 5 of sample size less one and 36 of sample count.
    static func flacInfo(in head: [UInt8]) -> FLACInfo? {
        guard head.count >= 26, head[4] & 0x7F == 0 else { return nil }
        let sampleRate = Int(head[18]) << 12
            | Int(head[19]) << 4
            | Int(head[20]) >> 4
        guard sampleRate > 0 else { return nil }
        let sampleCount = Int64(head[21] & 0x0F) << 32
            | Int64(head[22]) << 24
            | Int64(head[23]) << 16
            | Int64(head[24]) << 8
            | Int64(head[25])
        return FLACInfo(
            sampleRate: sampleRate,
            channelCount: Int(head[20] >> 1 & 0x07) + 1,
            bitsPerSample: Int(head[20] & 0x01) << 4
                + Int(head[21] >> 4) + 1,
            duration: sampleCount > 0
                ? TimeInterval(sampleCount) / TimeInterval(sampleRate)
                : nil
        )
    }

    static func container(of head: [UInt8]) -> Container? {
        func has(_ signature: String, at offset: Int = 0) -> Bool {
            let bytes = Array(signature.utf8)
            return head.count >= offset + bytes.count
                && head[offset..<offset + bytes.count].elementsEqual(bytes)
        }
        if has("fLaC") { return .flac }
        if has("OggS") { return .ogg }
        if has("ftyp", at: 4) { return .mpeg4 }
        if has("RIFF") { return .wave }
        if has("ID3") { return .mpeg }
        // An MPEG audio frame opens with eleven set bits.
        if head.count >= 2, head[0] == 0xFF, head[1] & 0xE0 == 0xE0 {
            return .mpeg
        }
        if let first = head.first(where: { !$0.isASCIIWhitespace }),
           first == UInt8(ascii: "<") || first == UInt8(ascii: "{")
            || first == UInt8(ascii: "[") {
            return .text
        }
        return nil
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

private extension UInt8 {
    nonisolated var isASCIIWhitespace: Bool {
        self == 0x20 || (0x09...0x0D).contains(self)
    }
}
