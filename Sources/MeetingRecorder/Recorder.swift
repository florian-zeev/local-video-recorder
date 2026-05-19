import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox

final class Recorder: NSObject {
    static let recordingsDirectory: URL =
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/Meetings", isDirectory: true)

    private let writerQueue = DispatchQueue(label: "recorder.writer")
    private let micQueue = DispatchQueue(label: "recorder.mic")

    private var stream: SCStream?
    private var streamOutput: StreamOutput?

    private var captureSession: AVCaptureSession?
    private var micOutput: AVCaptureAudioDataOutput?

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var sysAudioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?

    private var sessionStarted = false
    private var firstVideoPTS: CMTime = .invalid
    private(set) var isRecording = false
    private var currentURL: URL?

    // Diagnostic counters (accessed only on writerQueue)
    private var videoSamplesAppended = 0
    private var videoSamplesSkipped = 0
    private var sysAudioSamplesAppended = 0
    private var micSamplesAppended = 0

    var onStateChange: ((Bool) -> Void)?

    func start() {
        guard !isRecording else { return }
        Task { @MainActor in
            do {
                try await self.beginRecording()
            } catch {
                NSLog("MeetingRecorder start failed: \(error)")
                self.isRecording = false
                self.onStateChange?(false)
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        // UI gates on isRecording; flip stopping flag instead so in-flight samples can still drain.
        onStateChange?(false)
        Task { await self.finalize() }
    }

    private func finalize() async {
        // 1. Stop SCStream and wait for it
        if let stream = self.stream {
            do {
                try await stream.stopCapture()
                NSLog("MeetingRecorder SCStream stopCapture returned")
            } catch {
                NSLog("MeetingRecorder SCStream stopCapture error: \(error)")
            }
        }

        // 2. Stop AVCaptureSession (mic)
        captureSession?.stopRunning()

        // 3. Drain in-flight samples on writerQueue and on micQueue
        micQueue.sync {}
        writerQueue.sync {}

        // 4. From here on, no more samples should be appended
        isRecording = false

        // 5. Finalize on writerQueue so we don't race with any callback path
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerQueue.async { [weak self] in
                guard let self else { continuation.resume(); return }
                guard let writer = self.writer else {
                    NSLog("MeetingRecorder finalize: writer is nil")
                    self.cleanup()
                    continuation.resume()
                    return
                }

                NSLog("MeetingRecorder counters: video appended=\(self.videoSamplesAppended) skipped=\(self.videoSamplesSkipped), sysAudio appended=\(self.sysAudioSamplesAppended), mic appended=\(self.micSamplesAppended)")

                // Session-never-started case: writer file is invalid; drop it.
                if !self.sessionStarted {
                    NSLog("MeetingRecorder ERROR: no video sample ever arrived; session never started. Discarding output.")
                    if let err = writer.error {
                        NSLog("MeetingRecorder writer.error pre-discard: \(err)")
                    }
                    // Cancel the writer to release resources and remove file.
                    writer.cancelWriting()
                    if let url = self.currentURL {
                        try? FileManager.default.removeItem(at: url)
                    }
                    self.cleanup()
                    continuation.resume()
                    return
                }

                self.videoInput?.markAsFinished()
                self.sysAudioInput?.markAsFinished()
                self.micInput?.markAsFinished()

                NSLog("MeetingRecorder pre-finishWriting status=\(writer.status.rawValue)")
                if writer.status == .failed {
                    NSLog("MeetingRecorder pre-finishWriting FAILED: \(String(describing: writer.error))")
                }
                if let err = writer.error {
                    NSLog("MeetingRecorder pre-finishWriting writer.error: \(err)")
                }

                let url = self.currentURL
                writer.finishWriting { [weak self] in
                    guard let self else { continuation.resume(); return }
                    NSLog("MeetingRecorder finishWriting completed: status=\(writer.status.rawValue)")
                    if writer.status == .failed {
                        NSLog("MeetingRecorder finishWriting FAILED: \(String(describing: writer.error))")
                    }
                    if let err = writer.error {
                        NSLog("MeetingRecorder post-finishWriting writer.error: \(err)")
                    }
                    if writer.status == .completed, let url {
                        NSLog("MeetingRecorder file finalized at \(url.path)")
                        self.runFFmpeg(input: url)
                    } else if let url {
                        NSLog("MeetingRecorder writer did not complete cleanly; leaving file at \(url.path) for inspection")
                    }
                    self.cleanup()
                    continuation.resume()
                }
            }
        }
    }

    private func cleanup() {
        stream = nil
        streamOutput = nil
        captureSession = nil
        micOutput = nil
        writer = nil
        videoInput = nil
        sysAudioInput = nil
        micInput = nil
        sessionStarted = false
        firstVideoPTS = .invalid
        currentURL = nil
        videoSamplesAppended = 0
        videoSamplesSkipped = 0
        sysAudioSamplesAppended = 0
        micSamplesAppended = 0
    }

    private func beginRecording() async throws {
        try FileManager.default.createDirectory(at: Self.recordingsDirectory,
                                                withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        let ts = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = Self.recordingsDirectory.appendingPathComponent("\(ts).mp4")
        currentURL = url

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "Recorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "No displays"])
        }

        let pixelWidth = CGDisplayPixelsWide(display.displayID)
        let pixelHeight = CGDisplayPixelsHigh(display.displayID)

        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2

        let filter = SCContentFilter(display: display, excludingWindows: [])

        // Build writer
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 800_000,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel
            ] as [String: Any]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let sysAudioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]
        let sysAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: sysAudioSettings)
        sysAudioInput.expectsMediaDataInRealTime = true

        // Mic: probe device channel count for fallback to mono
        let micDevice = AVCaptureDevice.default(for: .audio)
        var micChannels = 2
        if let micDevice {
            for fmt in micDevice.formats {
                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt.formatDescription)?.pointee
                if let ch = asbd?.mChannelsPerFrame, ch > 0 {
                    micChannels = Int(ch) >= 2 ? 2 : 1
                    break
                }
            }
        }
        let micSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: micChannels,
            AVEncoderBitRateKey: 128_000
        ]
        let micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
        micInput.expectsMediaDataInRealTime = true

        if writer.canAdd(videoInput) { writer.add(videoInput) }
        if writer.canAdd(sysAudioInput) { writer.add(sysAudioInput) }
        if writer.canAdd(micInput) { writer.add(micInput) }

        self.writer = writer
        self.videoInput = videoInput
        self.sysAudioInput = sysAudioInput
        self.micInput = micInput

        guard writer.startWriting() else {
            NSLog("MeetingRecorder writer.startWriting() returned false; error=\(String(describing: writer.error))")
            throw writer.error ?? NSError(domain: "Recorder", code: 2)
        }
        NSLog("MeetingRecorder writer started, status=\(writer.status.rawValue)")

        // Setup mic capture
        if let micDevice {
            let session = AVCaptureSession()
            session.beginConfiguration()
            if let input = try? AVCaptureDeviceInput(device: micDevice), session.canAddInput(input) {
                session.addInput(input)
            }
            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: micQueue)
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
            session.commitConfiguration()
            session.startRunning()
            self.captureSession = session
            self.micOutput = output
        }

        // Setup SCStream
        let streamOutput = StreamOutput(recorder: self)
        let stream = SCStream(filter: filter, configuration: config, delegate: streamOutput)
        try stream.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: writerQueue)
        try stream.addStreamOutput(streamOutput, type: .audio, sampleHandlerQueue: writerQueue)
        self.stream = stream
        self.streamOutput = streamOutput

        // Set isRecording BEFORE startCapture so early samples aren't dropped.
        isRecording = true
        onStateChange?(true)

        do {
            try await stream.startCapture()
            NSLog("MeetingRecorder SCStream startCapture returned")
        } catch {
            NSLog("MeetingRecorder SCStream startCapture failed: \(error)")
            isRecording = false
            onStateChange?(false)
            throw error
        }
    }

    fileprivate func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard isRecording, let writer, let input = videoInput else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        // Filter SCK frame status — only append .complete frames
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int {
            if let status = SCFrameStatus(rawValue: raw), status != .complete {
                videoSamplesSkipped += 1
                return
            }
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !sessionStarted {
            NSLog("MeetingRecorder first video sample pts=\(pts.seconds) starting session")
            firstVideoPTS = pts
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
            if writer.status == .failed {
                NSLog("MeetingRecorder writer FAILED after startSession: \(String(describing: writer.error))")
            }
        }
        if input.isReadyForMoreMediaData {
            if input.append(sampleBuffer) {
                videoSamplesAppended += 1
            } else {
                NSLog("MeetingRecorder video append failed: status=\(writer.status.rawValue) error=\(String(describing: writer.error))")
            }
        }
    }

    fileprivate func handleSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        guard isRecording, sessionStarted, let input = sysAudioInput else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if CMTimeCompare(pts, firstVideoPTS) < 0 { return }
        if input.isReadyForMoreMediaData {
            if input.append(sampleBuffer) {
                sysAudioSamplesAppended += 1
            } else if let writer = self.writer {
                NSLog("MeetingRecorder sysAudio append failed: status=\(writer.status.rawValue) error=\(String(describing: writer.error))")
            }
        }
    }

    fileprivate func handleMic(_ sampleBuffer: CMSampleBuffer) {
        writerQueue.async { [weak self] in
            guard let self, self.isRecording, self.sessionStarted, let input = self.micInput else { return }
            guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if CMTimeCompare(pts, self.firstVideoPTS) < 0 { return }
            if input.isReadyForMoreMediaData {
                if input.append(sampleBuffer) {
                    self.micSamplesAppended += 1
                } else if let writer = self.writer {
                    NSLog("MeetingRecorder mic append failed: status=\(writer.status.rawValue) error=\(String(describing: writer.error))")
                }
            }
        }
    }

    private func runFFmpeg(input: URL) {
        DispatchQueue.global(qos: .utility).async {
            let output = input.deletingPathExtension().appendingPathExtension("m4a")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
            p.arguments = [
                "-i", input.path,
                "-filter_complex", "[0:a:0][0:a:1]amix=inputs=2:duration=longest[a]",
                "-map", "[a]",
                "-c:a", "aac",
                "-b:a", "160k",
                output.path
            ]
            NSLog("MeetingRecorder ffmpeg starting: \(input.path) -> \(output.path)")
            do {
                try p.run()
                p.waitUntilExit()
                NSLog("MeetingRecorder ffmpeg exited code=\(p.terminationStatus)")
            } catch {
                NSLog("MeetingRecorder ffmpeg failed to launch: \(error)")
            }
        }
    }
}

extension Recorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        handleMic(sampleBuffer)
    }
}

private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    weak var recorder: Recorder?

    init(recorder: Recorder) {
        self.recorder = recorder
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        switch type {
        case .screen:
            recorder?.handleVideo(sampleBuffer)
        case .audio:
            recorder?.handleSystemAudio(sampleBuffer)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("MeetingRecorder SCStream stopped with error: \(error)")
    }
}
