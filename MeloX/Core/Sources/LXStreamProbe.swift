import AudioToolbox
import Foundation

/// Facts read from the media URL returned by the enabled source, not from
/// its name, MIME label or requested tier. Only a bounded prefix is read.
nonisolated struct LXStreamProbe: Sendable {
    enum Container: String, Sendable {
        case flac, mpeg, aac, mpeg4, wave, ogg, text

        var format: String {
            switch self {
            case .mpeg: "mp3"
            case .mpeg4: "m4a"
            case .wave: "wav"
            default: rawValue
            }
        }
    }

    struct FLACInfo: Sendable, Equatable {
        let sampleRate: Int
        let channelCount: Int
        let bitsPerSample: Int
        let duration: TimeInterval?
    }

    struct HTTPFailure: Error {
        let status: Int
    }

    /// Recognized container but not enough bytes to identify the audio
    /// track (e.g. an MP4 whose movie atom is at the end). Not a rejection.
    struct InsufficientMetadata: Error {}

    let length: Int64?
    let container: Container
    let flac: FLACInfo?
    /// Duration from frame/packet counts, never inferred from a file name.
    let duration: TimeInterval?
    let isLossless: Bool
    let nominalBitrate: Int?
    let mimeMismatch: Bool

    private static let headLength = 8_192

    static func run(
        _ url: URL,
        headers: [String: String] = [:],
        session: URLSession,
        timeout: TimeInterval = 8
    ) async throws -> LXStreamProbe {
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout
        )
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        func prefix(at offset: Int) async throws -> (head: [UInt8], length: Int64?, mime: String?) {
            var ranged = request
            ranged.setValue("bytes=\(offset)-\(offset + headLength - 1)", forHTTPHeaderField: "Range")
            let (bytes, response) = try await session.bytes(for: ranged)
            defer { bytes.task.cancel() }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard http.statusCode == 200 || http.statusCode == 206 else {
                throw HTTPFailure(status: http.statusCode)
            }
            let length: Int64?
            let count: Int64?
            if http.statusCode == 206 {
                guard let range = http.value(forHTTPHeaderField: "Content-Range"),
                      let parsed = byteRange(range), parsed.start == Int64(offset) else {
                    throw LXPlaybackError.unplayableStream("无效字节范围")
                }
                length = parsed.total
                count = parsed.end - parsed.start + 1
            } else {
                guard offset == 0 else { throw LXPlaybackError.unplayableStream("无效字节范围") }
                length = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
                count = length
            }
            let limit = Int(min(Int64(headLength), count ?? Int64(headLength)))
            var head: [UInt8] = []
            head.reserveCapacity(limit)
            for try await byte in bytes {
                head.append(byte)
                if head.count == limit { break }
            }
            try Task.checkCancellation()
            guard !head.isEmpty, count == nil || head.count == limit else {
                throw LXPlaybackError.unplayableStream("音频头不完整")
            }
            return (head, length, http.mimeType?.lowercased())
        }

        let first = try await prefix(at: 0)
        var head = first.head
        var length = first.length
        var dataOffset = 0
        if head.starts(with: "ID3".utf8) {
            // A tag alone identifies neither an MP3 nor even audio. For large
            // cover images seek straight past the tag on the *same* media URL.
            guard head.count >= 10, (2...4).contains(head[3]), head[4] != 0xff,
                  head[6..<10].allSatisfy({ $0 < 128 }) else {
                throw LXPlaybackError.unplayableStream("无效 ID3")
            }
            dataOffset = 10 + head[6..<10].reduce(0) { ($0 << 7) | Int($1) }
            if head[3] == 4, head[5] & 0x10 != 0 { dataOffset += 10 }
            guard length.map({ $0 > Int64(dataOffset + 4) }) ?? true else {
                throw LXPlaybackError.unplayableStream("缺少音频帧")
            }
            if head.count >= dataOffset + 1024 {
                head = Array(head.dropFirst(dataOffset))
            } else {
                let audio = try await prefix(at: dataOffset)
                guard length == nil || audio.length == nil || length == audio.length else {
                    throw LXPlaybackError.unplayableStream("文件大小不一致")
                }
                length = length ?? audio.length
                head = audio.head
            }
        }

        guard let kind = container(of: head), kind != .text, kind != .ogg else {
            throw LXPlaybackError.unplayableStream("不支持的音频容器")
        }
        let mismatch = claimsDifferentFormat(first.mime, than: kind)
        if kind == .flac {
            guard head.count >= 42, let info = flacInfo(in: head) else {
                throw LXPlaybackError.unplayableStream("无效 FLAC STREAMINFO")
            }
            guard info.channelCount <= 2 else { throw LXPlaybackError.unplayableStream("多声道") }
            // Even silence needs frames. Reject a header or a cut-off object
            // without applying lossy average-bitrate floors to genuine FLAC.
            let minBlock = Int(head[8]) << 8 | Int(head[9])
            let maxBlock = Int(head[10]) << 8 | Int(head[11])
            guard minBlock >= 16, maxBlock >= minBlock else {
                throw LXPlaybackError.unplayableStream("无效 FLAC 块大小")
            }
            let samples = (info.duration ?? 0) * Double(info.sampleRate)
            let minimumBytes = 42 + 8 * Int64(ceil(samples / Double(maxBlock)))
            guard length.map({ $0 > Int64(dataOffset) + max(42, minimumBytes - 1) }) ?? true else {
                throw LXPlaybackError.unplayableStream("FLAC 数据不完整")
            }
            return Self(length: length, container: kind, flac: info, duration: info.duration,
                        isLossless: true, nominalBitrate: nil, mimeMismatch: mismatch)
        }

        // Use the platform's audio parser rather than treating a RIFF or
        // ISO movie header (or just an audio/* Content-Type) as audio.
        let audio = try audioProperties(in: head, kind: kind)
        guard audio.channels <= 2 else { throw LXPlaybackError.unplayableStream("多声道") }
        return Self(length: length, container: kind, flac: nil, duration: audio.duration,
                    isLossless: audio.lossless, nominalBitrate: audio.bitrate, mimeMismatch: mismatch)
    }

    /// Keep the field reader independent of how many trailing MD5 bytes
    /// the caller has. The network probe requires the entire 34-byte block.
    static func flacInfo(in head: [UInt8]) -> FLACInfo? {
        guard head.count >= 26, head.starts(with: "fLaC".utf8),
              head[4] & 0x7f == 0, head[5...7].elementsEqual([0, 0, 34]) else { return nil }
        let rate = Int(head[18]) << 12 | Int(head[19]) << 4 | Int(head[20]) >> 4
        let bits = (Int(head[20] & 1) << 4 | Int(head[21] >> 4)) + 1
        guard (1...655_350).contains(rate), (4...32).contains(bits) else { return nil }
        let samples = head[22...25].reduce(Int64(head[21] & 0x0f)) { ($0 << 8) | Int64($1) }
        return FLACInfo(sampleRate: rate, channelCount: Int(head[20] >> 1 & 7) + 1,
                        bitsPerSample: bits, duration: samples > 0 ? Double(samples) / Double(rate) : nil)
    }

    static func container(of head: [UInt8]) -> Container? {
        if head.starts(with: "fLaC".utf8) { return .flac }
        if head.starts(with: "OggS".utf8) { return .ogg }
        if head.dropFirst(4).starts(with: "ftyp".utf8) { return .mpeg4 }
        if head.starts(with: "RIFF".utf8), head.dropFirst(8).starts(with: "WAVE".utf8) { return .wave }
        if head.count >= 4, head[0] == 0xff, head[1] & 0xe0 == 0xe0 {
            if head[1] & 0xf6 == 0xf0 { return .aac }
            if head[1] >> 3 & 3 != 1, head[1] >> 1 & 3 != 0,
               head[2] >> 4 != 0xf, head[2] >> 2 & 3 != 3 { return .mpeg }
        }
        if let first = head.first(where: { $0 != 0x20 && !(0x09...0x0d).contains($0) }),
           [UInt8(ascii: "<"), UInt8(ascii: "{"), UInt8(ascii: "[")].contains(first) { return .text }
        return nil
    }

    private static func byteRange(_ header: String) -> (start: Int64, end: Int64, total: Int64?)? {
        let pieces = header.split(separator: " ")
        guard pieces.count == 2, pieces[0].lowercased() == "bytes" else { return nil }
        let range = pieces[1].split(separator: "/", omittingEmptySubsequences: false)
        guard range.count == 2 else { return nil }
        let bounds = range[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start >= 0, end >= start, end < Int64.max else { return nil }
        if range[1] == "*" { return (start, end, nil) }
        guard let total = Int64(range[1]), total > end else { return nil }
        return (start, end, total)
    }

    private static func claimsDifferentFormat(_ mime: String?, than container: Container) -> Bool {
        switch mime {
        case "audio/x-flac", "audio/flac": container != .flac
        case "audio/mpeg", "audio/mp3": container != .mpeg
        case "audio/aac", "audio/aacp": container != .aac
        case "audio/mp4", "audio/m4a", "audio/x-m4a": container != .mpeg4
        case "audio/wav", "audio/x-wav": container != .wave
        case "audio/ogg", "audio/x-ogg": container != .ogg
        default: mime?.hasPrefix("text/") == true || mime?.hasPrefix("video/") == true
        }
    }

    private static func audioProperties(in head: [UInt8], kind: Container) throws
        -> (channels: UInt32, lossless: Bool, duration: TimeInterval?, bitrate: Int?) {
        let hint: AudioFileTypeID = switch kind {
        case .mpeg: kAudioFileMP3Type
        case .aac: kAudioFileAAC_ADTSType
        case .mpeg4: kAudioFileM4AType
        case .wave: kAudioFileWAVEType
        default: 0
        }
        var parser: AudioFileStreamID?
        guard AudioFileStreamOpen(nil, { _, _, _, _ in }, { _, _, _, _, _ in }, hint, &parser) == noErr,
              let parser else { throw URLError(.cannotDecodeContentData) }
        defer { AudioFileStreamClose(parser) }
        guard head.withUnsafeBytes({
            AudioFileStreamParseBytes(parser, UInt32($0.count), $0.baseAddress!, [])
        }) == noErr else { throw LXPlaybackError.unplayableStream("无效音频帧") }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: format))
        guard AudioFileStreamGetProperty(parser, kAudioFileStreamProperty_DataFormat, &size, &format) == noErr,
              format.mChannelsPerFrame > 0, format.mSampleRate > 0 else {
            if kind == .mpeg4 { throw InsufficientMetadata() }
            throw LXPlaybackError.unplayableStream("无法识别音频轨")
        }
        var packets: UInt64 = 0
        size = UInt32(MemoryLayout.size(ofValue: packets))
        let counted = AudioFileStreamGetProperty(parser, kAudioFileStreamProperty_AudioDataPacketCount,
                                                  &size, &packets) == noErr && packets > 0
        let duration = counted && format.mFramesPerPacket > 0
            ? Double(packets) * Double(format.mFramesPerPacket) / format.mSampleRate : nil
        var bitrate: UInt32 = 0
        size = UInt32(MemoryLayout.size(ofValue: bitrate))
        let hasBitrate = AudioFileStreamGetProperty(parser, kAudioFileStreamProperty_BitRate, &size, &bitrate) == noErr
        return (format.mChannelsPerFrame, [kAudioFormatLinearPCM, kAudioFormatAppleLossless].contains(format.mFormatID),
                duration, hasBitrate && bitrate > 0 ? Int(bitrate) : nil)
    }
}
