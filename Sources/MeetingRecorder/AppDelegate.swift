import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var startItem: NSMenuItem!
    private var stopItem: NSMenuItem!
    private var hotkey: Hotkey?
    private let recorder = Recorder()
    private var transcribeWindowController: TranscribeWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon(recording: false)

        let menu = NSMenu()
        startItem = NSMenuItem(title: "Start Recording", action: #selector(toggle), keyEquivalent: "")
        startItem.target = self
        stopItem = NSMenuItem(title: "Stop Recording", action: #selector(toggle), keyEquivalent: "")
        stopItem.target = self
        stopItem.isEnabled = false
        menu.addItem(startItem)
        menu.addItem(stopItem)
        menu.addItem(.separator())
        let openItem = NSMenuItem(title: "Open Recordings Folder", action: #selector(openFolder), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        let transcribeItem = NSMenuItem(title: "Transcribe Recording…", action: #selector(openTranscribeWindow), keyEquivalent: "")
        transcribeItem.target = self
        menu.addItem(transcribeItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.autoenablesItems = false
        statusItem.menu = menu

        // ⌃⌥⌘R = control+option+command+R
        let mods: UInt32 = UInt32(controlKey | optionKey | cmdKey)
        hotkey = Hotkey(keyCode: UInt32(kVK_ANSI_R), modifiers: mods)
        hotkey?.onPress = { [weak self] in self?.toggle() }

        recorder.onStateChange = { [weak self] recording in
            DispatchQueue.main.async { self?.updateUI(recording: recording) }
        }
    }

    @objc private func toggle() {
        if recorder.isRecording {
            recorder.stop()
        } else {
            recorder.start()
        }
    }

    @objc private func openFolder() {
        let dir = Recorder.recordingsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func openTranscribeWindow() {
        if transcribeWindowController == nil {
            transcribeWindowController = TranscribeWindowController()
        }
        transcribeWindowController?.showWindow(nil)
    }

    private func updateUI(recording: Bool) {
        startItem.isEnabled = !recording
        stopItem.isEnabled = recording
        updateStatusIcon(recording: recording)
    }

    private func updateStatusIcon(recording: Bool) {
        guard let button = statusItem.button else { return }
        let symbol = recording ? "record.circle.fill" : "record.circle"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Meeting Recorder")
        if recording {
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            button.image = img?.withSymbolConfiguration(config)
        } else {
            img?.isTemplate = true
            button.image = img
        }
    }
}
