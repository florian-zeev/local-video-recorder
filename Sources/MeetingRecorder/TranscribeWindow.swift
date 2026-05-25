import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Operation {
    case transcribe
    case extractAudio

    var runningLabel: String {
        switch self {
        case .transcribe: return "Transcribing…"
        case .extractAudio: return "Extracting audio…"
        }
    }

    var completedLabel: String {
        switch self {
        case .transcribe: return "Transcription complete"
        case .extractAudio: return "Audio extracted"
        }
    }

    var failedLabel: String {
        switch self {
        case .transcribe: return "Transcription failed"
        case .extractAudio: return "Extraction failed"
        }
    }

    var resultIcon: String {
        switch self {
        case .transcribe: return "doc.text"
        case .extractAudio: return "waveform"
        }
    }

    var resultIconColor: Color {
        switch self {
        case .transcribe: return .blue
        case .extractAudio: return .green
        }
    }
}

@MainActor
final class OperationModel: ObservableObject {
    enum Phase {
        case idle
        case running
        case done
    }

    struct CompletedResult: Identifiable {
        let id = UUID()
        let operation: Operation
        let inputURL: URL
        let outputURL: URL
        let sizeBytes: Int64
    }

    @Published var phase: Phase = .idle
    @Published var operation: Operation = .transcribe
    @Published var statusLine: String = ""
    @Published var log: [String] = []
    @Published var progressFraction: Double?
    @Published var result: CompletedResult?
    @Published var errorMessage: String?

    private var task: Task<Void, Never>?

    func reset() {
        phase = .idle
        statusLine = ""
        log = []
        progressFraction = nil
        result = nil
        errorMessage = nil
    }

    func transcribe(videoURL: URL) {
        guard phase != .running else { return }
        reset()
        operation = .transcribe
        phase = .running
        statusLine = "Preparing…"

        let outputURL = videoURL.deletingPathExtension().appendingPathExtension("txt")

        task = Task { [weak self] in
            guard let self else { return }
            let progress: @Sendable (String) -> Void = { msg in
                Task { @MainActor in
                    self.log.append(msg)
                    self.statusLine = msg
                }
            }
            let fractionUpdate: @Sendable (Double) -> Void = { value in
                Task { @MainActor in
                    self.progressFraction = max(self.progressFraction ?? 0, value)
                }
            }
            do {
                try await Transcriber.transcribe(
                    videoURL: videoURL,
                    outputURL: outputURL,
                    progress: progress,
                    progressFraction: fractionUpdate
                )
                self.finishSuccess(input: videoURL, output: outputURL)
            } catch {
                self.finishFailure(error: error)
            }
        }
    }

    func extractAudio(videoURL: URL) {
        guard phase != .running else { return }
        reset()
        operation = .extractAudio
        phase = .running
        statusLine = "Preparing…"

        let outputURL = videoURL.deletingPathExtension().appendingPathExtension("mp3")

        task = Task { [weak self] in
            guard let self else { return }
            let progress: @Sendable (String) -> Void = { msg in
                Task { @MainActor in
                    self.log.append(msg)
                    self.statusLine = msg
                }
            }
            let fractionUpdate: @Sendable (Double) -> Void = { value in
                Task { @MainActor in
                    self.progressFraction = max(self.progressFraction ?? 0, value)
                }
            }
            do {
                try await AudioExtractor.extract(
                    videoURL: videoURL,
                    outputURL: outputURL,
                    progress: progress,
                    progressFraction: fractionUpdate
                )
                self.finishSuccess(input: videoURL, output: outputURL)
            } catch {
                self.finishFailure(error: error)
            }
        }
    }

    private func finishSuccess(input: URL, output: URL) {
        let size = (try? FileManager.default
            .attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
        result = CompletedResult(
            operation: operation,
            inputURL: input,
            outputURL: output,
            sizeBytes: size
        )
        statusLine = "Done"
        progressFraction = 1.0
        phase = .done
    }

    private func finishFailure(error: Error) {
        errorMessage = error.localizedDescription
        statusLine = "Failed"
        phase = .done
    }
}

struct Recording: Identifiable {
    let id: URL
    let url: URL
    let name: String
    let modifiedAt: Date
    let sizeBytes: Int64
}

struct TranscribeContentView: View {
    @StateObject private var model = OperationModel()
    @State private var recordings: [Recording] = []
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .idle: recordingsView
            case .running: processingView
            case .done: resultsView
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var recordingsView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Choose a recording")
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    recordings = Self.loadRecordings()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
                Button {
                    NSWorkspace.shared.open(Recorder.recordingsDirectory)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Open in Finder")
                Button {
                    pickFile()
                } label: {
                    Image(systemName: "doc.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("Pick file outside this folder…")
            }

            if recordings.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(recordings) { rec in
                            recordingRow(rec)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { recordings = Self.loadRecordings() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text("No recordings yet")
                .font(.headline)
            Text("Recordings appear in ~/Movies/Meetings/")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func recordingRow(_ rec: Recording) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "video")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(Self.formatDate(rec.modifiedAt))
                    Text("·")
                    Text(Self.formatSize(rec.sizeBytes))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.transcribe(videoURL: rec.url)
            } label: {
                Label("Transcribe", systemImage: "doc.text")
            }
            .help("Transcribe locally on this Mac")
            Button {
                model.extractAudio(videoURL: rec.url)
            } label: {
                Label("Extract MP3", systemImage: "waveform")
            }
            .help("Extract mono 16 kHz mp3 of all audio tracks")
        }
        .padding(10)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(8)
    }

    private static func loadRecordings() -> [Recording] {
        let dir = Recorder.recordingsDirectory
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let mp4s = urls.filter { $0.pathExtension.lowercased() == "mp4" }
        let recs: [Recording] = mp4s.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = values?.contentModificationDate ?? Date.distantPast
            let size = Int64(values?.fileSize ?? 0)
            return Recording(id: url, url: url, name: url.lastPathComponent, modifiedAt: date, sizeBytes: size)
        }
        return recs.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private static func formatDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    private static func formatSize(_ bytes: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }

    private var processingView: some View {
        VStack(spacing: 18) {
            if let fraction = model.progressFraction {
                VStack(spacing: 6) {
                    ProgressView(value: fraction, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(Color.black)
                    Text("\(Int(fraction * 100))%")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(maxWidth: 320)
            } else {
                ProgressView()
                    .scaleEffect(1.4)
            }
            Text(model.operation.runningLabel)
                .font(.headline)
            Text(model.statusLine)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .padding(.horizontal, 24)

            DisclosureGroup(isExpanded: $showLog) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(model.log.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(idx)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: model.log.count) { _, newCount in
                        if newCount > 0 {
                            proxy.scrollTo(newCount - 1, anchor: .bottom)
                        }
                    }
                }
                .frame(maxHeight: 160)
                .background(Color.gray.opacity(0.08))
                .cornerRadius(8)
            } label: {
                Text("Details")
                    .font(.caption)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.errorMessage == nil ? model.operation.completedLabel : model.operation.failedLabel)
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                Button("Back to recordings") { model.reset() }
                    .controlSize(.regular)
            }

            ScrollView {
                VStack(spacing: 8) {
                    if let result = model.result {
                        resultRow(result: result)
                    }
                    if let err = model.errorMessage {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(err)
                                .font(.caption)
                                .multilineTextAlignment(.leading)
                            Spacer()
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(8)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func resultRow(result: OperationModel.CompletedResult) -> some View {
        HStack(spacing: 12) {
            Image(systemName: result.operation.resultIcon)
                .font(.title2)
                .foregroundStyle(result.operation.resultIconColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.outputURL.lastPathComponent)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Self.formatSize(result.sizeBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
            } label: {
                Label("Show", systemImage: "folder")
            }
            .help("Reveal in Finder")
            Button {
                NSWorkspace.shared.open(result.outputURL)
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
            }
            .help(result.operation == .transcribe ? "Open transcript" : "Open audio")
        }
        .padding(10)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(8)
        .onDrag {
            NSItemProvider(object: result.outputURL as NSURL)
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.directoryURL = Recorder.recordingsDirectory
        if panel.runModal() == .OK, let url = panel.url {
            model.transcribe(videoURL: url)
        }
    }
}

final class TranscribeWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Transcribe Recording"
        window.setFrameAutosaveName("TranscribeWindow")
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: TranscribeContentView())
        self.init(window: window)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
}
