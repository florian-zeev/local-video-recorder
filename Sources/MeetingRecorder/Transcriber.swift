import AVFoundation
import CoreMedia
import Foundation
import Speech

enum TranscriberError: LocalizedError {
    case noAudioTracks
    case localeUnsupported(Locale)
    case noCompatibleAudioFormat
    case assetReaderFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTracks:
            return "The file has no audio tracks."
        case .localeUnsupported(let locale):
            return "Locale \(locale.identifier) is not supported by SpeechTranscriber and no fallback is available."
        case .noCompatibleAudioFormat:
            return "Could not determine an audio format compatible with SpeechTranscriber."
        case .assetReaderFailed(let detail):
            return "AVAssetReader failed: \(detail)"
        }
    }
}

struct TranscriptSegment {
    let trackIndex: Int
    let label: String
    let start: CMTime
    let end: CMTime
    let text: String
}

enum Transcriber {
    static func transcribe(
        videoURL: URL,
        outputURL: URL,
        locale: Locale = .current,
        progress: @escaping @Sendable (String) -> Void,
        progressFraction: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let asset = AVURLAsset(url: videoURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw TranscriberError.noAudioTracks }

        let duration = (try? await asset.load(.duration).seconds) ?? 0
        if duration > 0 {
            progress("Duration: \(String(format: "%.1f", duration))s")
        }

        let chosenLocale = try await resolveLocale(locale)
        progress("Using locale: \(chosenLocale.identifier)")

        let probeTranscriber = makeTranscriber(locale: chosenLocale)

        progress("Checking speech model assets…")
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probeTranscriber]) {
            progress("Downloading speech model… (one-time)")
            try await request.downloadAndInstall()
        }

        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probeTranscriber]) else {
            throw TranscriberError.noCompatibleAudioFormat
        }
        progress("Audio format: \(Int(targetFormat.sampleRate))Hz, \(targetFormat.channelCount)ch")

        progress("Transcribing \(audioTracks.count) track(s)…")
        let trackResults: [[TranscriptSegment]] = try await withThrowingTaskGroup(
            of: (Int, [TranscriptSegment]).self
        ) { group in
            for (idx, track) in audioTracks.enumerated() {
                let label = labelForTrack(idx, total: audioTracks.count)
                group.addTask {
                    let segs = try await runOneTrack(
                        asset: asset,
                        track: track,
                        locale: chosenLocale,
                        targetFormat: targetFormat,
                        trackIndex: idx,
                        label: label,
                        duration: duration,
                        progress: progress,
                        progressFraction: progressFraction
                    )
                    return (idx, segs)
                }
            }
            var collected = Array(repeating: [TranscriptSegment](), count: audioTracks.count)
            for try await (idx, segs) in group {
                collected[idx] = segs
            }
            return collected
        }

        var merged = trackResults.flatMap { $0 }
        merged.sort { CMTimeCompare($0.start, $1.start) < 0 }

        let text = renderTranscript(
            sourceURL: videoURL,
            locale: chosenLocale,
            segments: merged
        )
        try text.write(to: outputURL, atomically: true, encoding: .utf8)
        progress("Saved transcript to \(outputURL.path)")
    }

    private static func resolveLocale(_ requested: Locale) async throws -> Locale {
        if let exact = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
            return exact
        }
        let supported = await SpeechTranscriber.supportedLocales
        if let englishFallback = supported.first(where: { $0.identifier.hasPrefix("en") }) {
            return englishFallback
        }
        if let first = supported.first {
            return first
        }
        throw TranscriberError.localeUnsupported(requested)
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)
    }

    // Recorder writes audio:0 = system audio (others), audio:1 = mic (me).
    private static func labelForTrack(_ index: Int, total: Int) -> String {
        if total == 1 { return "AUDIO" }
        switch index {
        case 0: return "OTHERS"
        case 1: return "ME"
        default: return "TRACK \(index)"
        }
    }

    private static func runOneTrack(
        asset: AVURLAsset,
        track: AVAssetTrack,
        locale: Locale,
        targetFormat: AVAudioFormat,
        trackIndex: Int,
        label: String,
        duration: Double,
        progress: @Sendable (String) -> Void,
        progressFraction: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        let transcriber = makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Decode to interleaved float32 PCM at the source's native rate/channels.
        // Resampling and downmixing happen via AVAudioConverter below; doing both
        // inside AVAssetReader is unreliable for some AAC inputs.
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings)
        trackOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(trackOutput) else {
            throw TranscriberError.assetReaderFailed("cannot add output for track \(trackIndex)")
        }
        reader.add(trackOutput)
        guard reader.startReading() else {
            throw TranscriberError.assetReaderFailed(reader.error?.localizedDescription ?? "startReading failed")
        }
        progress("Track \(trackIndex) (\(label)): reader status=\(reader.status.rawValue)")

        let sourceFormat = try await loadAudioFormat(for: track)
        progress("Track \(trackIndex) (\(label)): source \(Int(sourceFormat.sampleRate))Hz \(sourceFormat.channelCount)ch -> target \(Int(targetFormat.sampleRate))Hz \(targetFormat.channelCount)ch")
        let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        if converter == nil {
            progress("Track \(trackIndex) (\(label)): WARNING could not build AVAudioConverter")
        }

        let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        let collector = Task<[TranscriptSegment], Error> {
            var out: [TranscriptSegment] = []
            for try await result in transcriber.results {
                if duration > 0 {
                    let endSec = result.range.end.seconds
                    progressFraction(min(1.0, endSec / duration))
                }
                guard result.isFinal else { continue }
                let plain = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !plain.isEmpty else { continue }
                out.append(TranscriptSegment(
                    trackIndex: trackIndex,
                    label: label,
                    start: result.range.start,
                    end: result.range.end,
                    text: plain
                ))
            }
            return out
        }

        // Run start() concurrently with the feed loop. Depending on whether
        // start() returns immediately (autonomous mode) or only after the
        // input stream finishes, sequencing them serially would deadlock.
        async let startTask: Void = analyzer.start(inputSequence: inputStream)

        var sampleCount = 0
        var emittedFrames: AVAudioFrameCount = 0
        while let sample = trackOutput.copyNextSampleBuffer() {
            guard CMSampleBufferDataIsReady(sample) else { continue }
            guard let sourcePCM = pcmBuffer(from: sample, format: sourceFormat) else {
                continue
            }
            let targetPCM: AVAudioPCMBuffer
            if let converter, sourceFormat != targetFormat {
                guard let converted = convert(buffer: sourcePCM, using: converter, targetFormat: targetFormat) else {
                    continue
                }
                targetPCM = converted
            } else {
                targetPCM = sourcePCM
            }
            continuation.yield(AnalyzerInput(buffer: targetPCM))
            sampleCount += 1
            emittedFrames += targetPCM.frameLength
            if sampleCount % 50 == 0 {
                await Task.yield()
            }
        }
        if let converter, sourceFormat != targetFormat,
           let tail = flushConverter(converter, targetFormat: targetFormat) {
            continuation.yield(AnalyzerInput(buffer: tail))
            sampleCount += 1
            emittedFrames += tail.frameLength
        }
        continuation.finish()
        let readerStatus = reader.status.rawValue
        let readerError = reader.error?.localizedDescription ?? "none"
        progress("Track \(trackIndex) (\(label)): fed \(sampleCount) buffers (\(emittedFrames) frames), reader=\(readerStatus) err=\(readerError), finalizing…")

        try await startTask

        if reader.status == .failed {
            throw TranscriberError.assetReaderFailed(reader.error?.localizedDescription ?? "reading failed")
        }

        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let segments = try await collector.value
        progress("Track \(trackIndex) (\(label)): \(segments.count) segments")
        return segments
    }

    private static func loadAudioFormat(for track: AVAssetTrack) async throws -> AVAudioFormat {
        let formatDescriptions = try await track.load(.formatDescriptions)
        guard let cmFormat = formatDescriptions.first else {
            throw TranscriberError.assetReaderFailed("track has no format descriptions")
        }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(cmFormat)?.pointee else {
            throw TranscriberError.assetReaderFailed("could not read source ASBD")
        }
        // We requested interleaved float32 PCM from the reader; build a matching format.
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.mSampleRate,
            channels: AVAudioChannelCount(asbd.mChannelsPerFrame),
            interleaved: true
        ) else {
            throw TranscriberError.assetReaderFailed("could not build source AVAudioFormat")
        }
        return format
    }

    private static func renderTranscript(
        sourceURL: URL,
        locale: Locale,
        segments: [TranscriptSegment]
    ) -> String {
        var out = ""
        out += "Transcript of \(sourceURL.lastPathComponent)\n"
        out += "Locale: \(locale.identifier)\n"
        out += "Generated: \(ISO8601DateFormatter().string(from: Date()))\n"
        out += String(repeating: "-", count: 60) + "\n\n"

        var lastLabel: String? = nil
        for seg in segments {
            let stamp = formatTimestamp(seg.start)
            if seg.label != lastLabel {
                if lastLabel != nil { out += "\n" }
                out += "[\(stamp)] \(seg.label):\n"
                lastLabel = seg.label
            }
            out += seg.text + "\n"
        }
        return out
    }

    private static func formatTimestamp(_ time: CMTime) -> String {
        let total = max(time.seconds, 0)
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let s = Int(total) % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

// Reader is configured for interleaved float32; `format` here must match
// (same sampleRate / channelCount / interleaved=true).
private func pcmBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
    let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
    guard frameCount > 0,
          let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
          let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        return nil
    }
    pcm.frameLength = frameCount

    var lengthAtOffset = 0
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<Int8>? = nil
    let status = CMBlockBufferGetDataPointer(
        blockBuffer,
        atOffset: 0,
        lengthAtOffsetOut: &lengthAtOffset,
        totalLengthOut: &totalLength,
        dataPointerOut: &dataPointer
    )
    guard status == kCMBlockBufferNoErr, let data = dataPointer else { return nil }
    guard let dst = pcm.floatChannelData?[0] else { return nil }
    let bytes = Int(frameCount) * Int(format.channelCount) * MemoryLayout<Float32>.size
    memcpy(dst, data, min(bytes, totalLength))
    return pcm
}

private func convert(
    buffer source: AVAudioPCMBuffer,
    using converter: AVAudioConverter,
    targetFormat: AVAudioFormat
) -> AVAudioPCMBuffer? {
    let ratio = targetFormat.sampleRate / source.format.sampleRate
    let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio + 0.5) + 1024
    guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
        return nil
    }
    var sourceProvided = false
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, outStatus in
        if sourceProvided {
            // Don't flush — keep the resampler's internal state for the next call.
            outStatus.pointee = .noDataNow
            return nil
        }
        sourceProvided = true
        outStatus.pointee = .haveData
        return source
    }
    if status == .error || error != nil {
        return nil
    }
    return output
}

private func flushConverter(_ converter: AVAudioConverter, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
    guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 8192) else {
        return nil
    }
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, outStatus in
        outStatus.pointee = .endOfStream
        return nil
    }
    if status == .error || error != nil {
        return nil
    }
    return output.frameLength > 0 ? output : nil
}
