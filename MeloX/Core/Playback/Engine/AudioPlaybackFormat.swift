@preconcurrency import AVFoundation

enum AudioPlaybackFormat {
    static func load(
        from url: URL,
        headers: [String: String] = [:]
    ) async -> AVAudioFormat? {
        let format: AVAudioFormat
        if url.isFileURL {
            guard let file = try? AVAudioFile(forReading: url) else { return nil }
            format = file.processingFormat
        } else {
            let asset = headers.isEmpty
                ? AVURLAsset(url: url)
                : AVURLAsset(
                    url: url,
                    options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
                )
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let description = try? await track.load(.formatDescriptions).first else { return nil }
            format = AVAudioFormat(cmAudioFormatDescription: description)
        }
        rigTrace("format", "source rate=\(format.sampleRate) channels=\(format.channelCount) layoutTag=\(String(describing: format.channelLayout?.layoutTag))")
        // Some files are opened without their format being read: QQ's 5.1
        // FLAC comes back with no channels and no sample rate. Playing to a
        // format built from that crashed the player, so the player is left
        // to its own.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            return nil
        }
        if let layout = format.channelLayout {
            return AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: format.sampleRate,
                interleaved: true,
                channelLayout: layout
            )
        }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: format.channelCount,
            interleaved: true
        )
    }
}
