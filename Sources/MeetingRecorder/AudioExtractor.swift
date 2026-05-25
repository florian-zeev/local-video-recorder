import AVFoundation
import Foundation

enum AudioExtractorError: LocalizedError {
    case ffmpegNotFound
    case ffprobeNotFound
    case noAudioTracks
    case ffmpegFailed(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "ffmpeg not found. Install with: brew install ffmpeg"
        case .ffprobeNotFound:
            return "ffprobe not found. Install with: brew install ffmpeg"
        case .noAudioTracks:
            return "No audio tracks in file."
        case .ffmpegFailed(let detail):
            return "ffmpeg failed: \(detail)"
        }
    }
}

enum AudioExtractor {
    static func extract(
        videoURL: URL,
        outputURL: URL,
        progress: @escaping @Sendable (String) -> Void,
        progressFraction: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard let ffmpegPath = findExecutable("ffmpeg") else {
            throw AudioExtractorError.ffmpegNotFound
        }
        guard let ffprobePath = findExecutable("ffprobe") else {
            throw AudioExtractorError.ffprobeNotFound
        }

        progress("Probing audio tracks…")
        let trackCount = try await probeTrackCount(ffprobePath: ffprobePath, videoURL: videoURL)
        progress("Found \(trackCount) audio track(s)")
        guard trackCount > 0 else { throw AudioExtractorError.noAudioTracks }

        let duration = (try? await AVURLAsset(url: videoURL).load(.duration).seconds) ?? 0

        var args = ["-y", "-i", videoURL.path]
        if trackCount == 1 {
            args += ["-map", "0:a:0"]
        } else {
            args += [
                "-filter_complex",
                "[0:a]amix=inputs=\(trackCount):duration=longest:normalize=0[a]",
                "-map", "[a]"
            ]
        }
        // Mono 16 kHz 32 kbps mp3 — sized for cloud transcription services
        // (e.g. ElevenLabs Scribe, Deepgram).
        args += ["-ac", "1", "-ar", "16000", "-b:a", "32k"]
        args += ["-progress", "pipe:1", "-nostats", outputURL.path]

        progress("Running ffmpeg…")
        try await runFFmpeg(
            executable: ffmpegPath,
            args: args,
            duration: duration,
            progressFraction: progressFraction
        )
        progress("Extracted audio to \(outputURL.lastPathComponent)")
    }

    private static func findExecutable(_ name: String) -> String? {
        for path in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func probeTrackCount(
        ffprobePath: String,
        videoURL: URL
    ) async throws -> Int {
        let stdout = try await runCapturing(
            executable: ffprobePath,
            args: [
                "-i", videoURL.path,
                "-show_entries", "stream=index",
                "-select_streams", "a",
                "-of", "csv=p=0",
                "-loglevel", "error"
            ]
        )
        return stdout.split(separator: "\n").filter { !$0.isEmpty }.count
    }

    private static func runFFmpeg(
        executable: String,
        args: [String],
        duration: Double,
        progressFraction: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                if duration > 0 {
                    let buffer = ProgressBuffer()
                    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        if chunk.isEmpty {
                            handle.readabilityHandler = nil
                            return
                        }
                        buffer.append(chunk) { line in
                            if let seconds = parseFFmpegProgress(line: line) {
                                progressFraction(min(1.0, seconds / duration))
                            }
                        }
                    }
                }

                do {
                    try process.run()
                    process.waitUntilExit()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    if process.terminationStatus != 0 {
                        let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        let text = String(data: data, encoding: .utf8) ?? "unknown ffmpeg error"
                        let tail = text.split(separator: "\n").suffix(3).joined(separator: " ")
                        cont.resume(throwing: AudioExtractorError.ffmpegFailed(String(tail)))
                    } else {
                        cont.resume(returning: ())
                    }
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func runCapturing(executable: String, args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = Pipe()
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = stdout.fileHandleForReading.readDataToEndOfFile()
                    let text = String(data: data, encoding: .utf8) ?? ""
                    if process.terminationStatus != 0 {
                        cont.resume(throwing: AudioExtractorError.ffmpegFailed("exit \(process.terminationStatus)"))
                    } else {
                        cont.resume(returning: text)
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

// Line-buffered accumulator for the ffmpeg `-progress pipe:1` stdout stream.
// readabilityHandler delivers arbitrary byte chunks; we need whole lines.
private final class ProgressBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data, onLine: (String) -> Void) {
        lock.lock()
        data.append(chunk)
        while let nl = data.firstIndex(of: 0x0A) {
            let lineData = data.subdata(in: data.startIndex..<nl)
            data.removeSubrange(data.startIndex...nl)
            if let str = String(data: lineData, encoding: .utf8) {
                onLine(str)
            }
        }
        lock.unlock()
    }
}

// ffmpeg emits `out_time_us=12345000` lines; convert to seconds.
private func parseFFmpegProgress(line: String) -> Double? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let eq = trimmed.firstIndex(of: "=") else { return nil }
    let key = trimmed[..<eq]
    let value = trimmed[trimmed.index(after: eq)...]
    guard key == "out_time_us" || key == "out_time_ms" else { return nil }
    guard let micros = Double(value), micros > 0 else { return nil }
    return micros / 1_000_000
}
