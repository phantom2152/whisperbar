import AppKit
import AVFoundation

/// The whole tile: home (server + recorder), history, and the microphone-permission screens.
@MainActor
final class PanelViewController: NSViewController {
    enum Phase { case idle, recording, transcribing, done, failed }
    enum Screen { case home, history, needsPermission, denied, granted }

    // Callbacks into the app
    var onModalBusy: (@MainActor (Bool) -> Void)?          // true while a system dialog / save panel is up
    var onRecordingChange: (@MainActor (Bool) -> Void)?
    var onQuit: (@MainActor () -> Void)?

    private let server: ServerController
    private let store: TranscriptStore
    private let recorder = AudioRecorder()
    private let exporter = ExportController()

    // State
    private var phase: Phase = .idle
    private var screen: Screen = .home
    private var latest: Transcript?
    private var failText = ""
    private var note = ""
    private var requestingPermission = false
    private var work: Task<Void, Never>?

    // Screens
    private var homeStack: NSStackView!
    private var historyStack: NSStackView!
    private var permStack: NSStackView!
    private var deniedStack: NSStackView!
    private var grantedStack: NSStackView!

    // Home widgets
    private let dot = NSTextField(labelWithString: "●")
    private let statusLabel = UI.label("", size: 12, color: .secondaryLabelColor)
    private let serverBtn = NSButton(title: "Start server", target: nil, action: nil)
    private let wave = WaveformView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let info = UI.label("", size: 12, color: .secondaryLabelColor)
    private var recBtn: IconButton!
    private var discardBtn: IconButton!
    private var copyBtn: IconButton!
    private var exportBtn: IconButton!
    private var historyBtn: IconButton!

    // History widgets
    private let historyList = FlippedStackView()
    private var exportAllBtn: IconButton!
    private var clearBtn: IconButton!

    // Permission widgets
    private let allowBtn = NSButton(title: "Allow microphone", target: nil, action: nil)

    // MARK: Init

    init(server: ServerController, store: TranscriptStore) {
        self.server = server
        self.store = store
        super.init(nibName: nil, bundle: nil)

        recorder.onTick = { [weak self] level, elapsed in self?.tick(level: level, elapsed: elapsed) }
        store.onChange = { [weak self] in self?.storeChanged() }
        exporter.onBusy = { [weak self] busy in self?.onModalBusy?(busy) }
        exporter.onResult = { [weak self] text in self?.note = text; self?.render() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: View construction

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: UI.tileWidth, height: 300))
        view = root

        buildHome()
        buildHistory()
        buildPermission()
        buildDenied()
        buildGranted()

        for s in [homeStack!, historyStack!, permStack!, deniedStack!, grantedStack!] {
            root.addSubview(s)
            NSLayoutConstraint.activate([
                s.topAnchor.constraint(equalTo: root.topAnchor),
                s.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                s.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
        }
        render()
    }

    private func buildHome() {
        dot.font = .systemFont(ofSize: 9)
        let header = UI.row([UI.label("WhisperBar", size: 15, weight: .semibold), UI.spacer(), dot, statusLabel],
                            spacing: 5)

        serverBtn.target = self
        serverBtn.action = #selector(serverTapped)
        serverBtn.bezelStyle = .rounded
        serverBtn.imagePosition = .imageLeading
        UI.fixedWidth(serverBtn)

        // One fixed slot: waveform while recording, text otherwise
        let slot = UI.fixedWidth(NSView())
        for v in [wave, message] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            slot.addSubview(v)
        }
        message.font = .systemFont(ofSize: 14)
        message.maximumNumberOfLines = 4
        message.lineBreakMode = .byTruncatingTail
        message.cell?.truncatesLastVisibleLine = true
        message.isSelectable = true
        message.preferredMaxLayoutWidth = UI.contentWidth
        NSLayoutConstraint.activate([
            slot.heightAnchor.constraint(equalToConstant: 72),
            wave.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
            wave.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
            wave.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
            wave.heightAnchor.constraint(equalToConstant: 48),
            message.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
            message.topAnchor.constraint(equalTo: slot.topAnchor),
        ])

        recBtn = IconButton(symbol: "mic.fill", tooltip: "Record", side: 40, symbolSize: 17,
                            fill: .controlAccentColor, target: self, action: #selector(recordTapped))
        recBtn.keyEquivalent = "\r"
        discardBtn = IconButton(symbol: "xmark", tooltip: "Discard recording",
                                target: self, action: #selector(discardTapped))
        copyBtn = IconButton(symbol: "doc.on.doc", tooltip: "Copy", target: self, action: #selector(copyTapped))
        exportBtn = IconButton(symbol: "square.and.arrow.up", tooltip: "Export…",
                               target: self, action: #selector(exportTapped))
        historyBtn = IconButton(symbol: "clock.arrow.circlepath", tooltip: "History",
                                target: self, action: #selector(historyTapped))
        info.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        info.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let controls = UI.row([recBtn, discardBtn, info, copyBtn, exportBtn, historyBtn], spacing: 6)

        let foot = UI.label("localhost:\(Config.port)", size: 11, color: .tertiaryLabelColor)
        let logBtn = IconButton(symbol: "doc.text.magnifyingglass", tooltip: "Open server log",
                                side: 24, symbolSize: 12, target: self, action: #selector(openLogTapped))
        let quitBtn = IconButton(symbol: "xmark.circle", tooltip: "Quit WhisperBar",
                                 side: 24, symbolSize: 12, target: self, action: #selector(quitTapped))
        let footer = UI.row([foot, UI.spacer(), logBtn, quitBtn], spacing: 4)

        homeStack = UI.column([header, serverBtn, UI.separator(), slot, controls, UI.separator(), footer])
    }

    private func buildHistory() {
        let back = IconButton(symbol: "chevron.left", tooltip: "Back", target: self, action: #selector(backTapped))
        exportAllBtn = IconButton(symbol: "square.and.arrow.up", tooltip: "Export all…",
                                  target: self, action: #selector(exportAllTapped))
        clearBtn = IconButton(symbol: "trash", tooltip: "Clear history", target: self, action: #selector(clearTapped))
        let header = UI.row([back, UI.label("History", size: 15, weight: .semibold), UI.spacer(), exportAllBtn, clearBtn],
                            spacing: 6)

        historyList.orientation = .vertical
        historyList.alignment = .leading
        historyList.spacing = 6
        historyList.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = historyList
        UI.fixedWidth(scroll)
        scroll.heightAnchor.constraint(equalToConstant: 250).isActive = true
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            historyList.topAnchor.constraint(equalTo: clip.topAnchor),
            historyList.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            historyList.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
        ])

        historyStack = UI.column([header, UI.separator(), scroll])
    }

    private func backRow(_ title: String) -> NSView {
        let back = IconButton(symbol: "chevron.left", tooltip: "Back", target: self, action: #selector(backTapped))
        return UI.row([back, UI.label(title, size: 15, weight: .semibold), UI.spacer()], spacing: 6)
    }

    private func buildPermission() {
        allowBtn.target = self
        allowBtn.action = #selector(allowTapped)
        allowBtn.bezelStyle = .rounded
        allowBtn.image = Symbols.image("mic.fill", size: 12)
        allowBtn.imagePosition = .imageLeading
        permStack = UI.column([
            backRow("Microphone access"),
            UI.paragraph("WhisperBar records your voice and sends it to your local whisper server. macOS will ask you to confirm."),
            allowBtn,
        ])
    }

    private func buildDenied() {
        let open = NSButton(title: "Open System Settings", target: self, action: #selector(openSettingsTapped))
        open.bezelStyle = .rounded
        open.image = Symbols.image("gearshape", size: 12)
        open.imagePosition = .imageLeading
        deniedStack = UI.column([
            backRow("Microphone is off"),
            UI.paragraph("Turn it on for WhisperBar in System Settings → Privacy & Security → Microphone, then come back."),
            open,
        ])
    }

    private func buildGranted() {
        let title = UI.label("✓ Microphone access granted", size: 15, weight: .semibold, color: .systemGreen)
        grantedStack = UI.column([title, UI.paragraph("You can start recording now.")])
    }

    // MARK: Rendering (everything derives from server.state / phase / screen)

    private func render() {
        guard isViewLoaded else { return }

        homeStack.isHidden = screen != .home
        historyStack.isHidden = screen != .history
        permStack.isHidden = screen != .needsPermission
        deniedStack.isHidden = screen != .denied
        grantedStack.isHidden = screen != .granted

        // Server header + button
        switch server.state {
        case .stopped:
            dot.textColor = .tertiaryLabelColor; statusLabel.stringValue = "Stopped"
            serverBtn.title = "Start server"; serverBtn.isEnabled = true
        case .starting:
            dot.textColor = .systemOrange; statusLabel.stringValue = "Starting…"
            serverBtn.title = "Stop server"; serverBtn.isEnabled = true
        case .ready:
            dot.textColor = .systemGreen; statusLabel.stringValue = "Ready"
            serverBtn.title = "Stop server"; serverBtn.isEnabled = true
        case .stopping:
            dot.textColor = .systemOrange; statusLabel.stringValue = "Stopping…"
            serverBtn.title = "Stopping…"; serverBtn.isEnabled = false
        }
        serverBtn.image = Symbols.image(server.state == .stopped ? "power" : "stop.fill", size: 12)

        // Recorder
        let recording = phase == .recording
        wave.isHidden = !recording
        message.isHidden = recording
        message.toolTip = nil
        recBtn.setSymbol(recording ? "stop.fill" : "mic.fill")
        recBtn.setFill(recording ? .systemRed : .controlAccentColor)
        recBtn.toolTip = recording ? "Stop and transcribe" : "Record"
        recBtn.isEnabled = recording || (server.state == .ready && phase != .transcribing)
        discardBtn.isHidden = !recording
        copyBtn.isEnabled = latest != nil && !recording
        exportBtn.isEnabled = latest != nil && !recording
        info.stringValue = note

        switch phase {
        case .recording:
            break
        case .transcribing:
            message.stringValue = "Transcribing…"
            message.textColor = .secondaryLabelColor
        case .done:
            message.stringValue = latest?.text ?? ""
            message.textColor = .labelColor
            message.toolTip = latest?.text
        case .failed:
            message.stringValue = failText
            message.textColor = .systemRed
        case .idle:
            if let problem = server.problem {
                message.stringValue = problem
                message.textColor = .systemRed
            } else {
                message.stringValue = server.state == .ready ? "Press the mic, then speak." : "Start the server to begin."
                message.textColor = .secondaryLabelColor
            }
        }

        if screen == .history { rebuildHistory() }
        updateSize()
    }

    private func rebuildHistory() {
        for v in historyList.arrangedSubviews {
            historyList.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        let items = store.items
        exportAllBtn.isEnabled = !items.isEmpty
        clearBtn.isEnabled = !items.isEmpty

        if items.isEmpty {
            historyList.addArrangedSubview(UI.paragraph("No transcripts yet. Your takes will show up here."))
            return
        }
        for t in items {
            let row = TranscriptRow(transcript: t)
            row.onCopy = { [weak self] in self?.copyToPasteboard(t.text) }
            row.onExport = { [weak self] anchor in self?.exporter.showMenu(for: [t], from: anchor) }
            row.onDelete = { [weak self] in self?.store.remove(t.id) }
            historyList.addArrangedSubview(row)
        }
    }

    private func updateSize() {
        let current: NSStackView
        switch screen {
        case .home: current = homeStack
        case .history: current = historyStack
        case .needsPermission: current = permStack
        case .denied: current = deniedStack
        case .granted: current = grantedStack
        }
        current.layoutSubtreeIfNeeded()
        let height = current.fittingSize.height
        if abs(preferredContentSize.height - height) > 0.5 || preferredContentSize.width != UI.tileWidth {
            preferredContentSize = NSSize(width: UI.tileWidth, height: height)
        }
    }

    private func go(_ s: Screen) { screen = s; render() }

    // MARK: Called by the app

    func serverChanged() {
        if server.state == .stopped || server.state == .stopping {
            if recorder.isRecording { discardRecording() }
            if phase == .transcribing { work?.cancel(); phase = .idle }
        }
        render()
    }

    /// Reopening the tile always lands on the home screen (unless the system dialog is up).
    func prepareForOpen() {
        guard !requestingPermission, screen != .home else { return }
        go(.home)
    }

    private func storeChanged() {
        if let l = latest, !store.items.contains(where: { $0.id == l.id }) {
            latest = nil
            if phase == .done { phase = .idle; note = "" }
        }
        render()
    }

    // MARK: Actions

    @objc private func serverTapped() { server.toggle() }
    @objc private func quitTapped() { onQuit?() }
    @objc private func backTapped() { go(.home) }
    @objc private func historyTapped() { go(.history) }
    @objc private func openLogTapped() { NSWorkspace.shared.open(URL(fileURLWithPath: Config.logPath)) }

    @objc private func openSettingsTapped() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func copyTapped() {
        guard let latest else { return }
        copyToPasteboard(latest.text)
        note = "Copied"
        render()
    }

    @objc private func exportTapped() {
        guard let latest else { return }
        exporter.showMenu(for: [latest], from: exportBtn)
    }

    @objc private func exportAllTapped() {
        exporter.showMenu(for: store.items, from: exportAllBtn)
    }

    @objc private func clearTapped() {
        guard !store.items.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear all transcripts?"
        alert.informativeText = "This removes \(store.items.count) saved takes. It can’t be undone."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")

        onModalBusy?(true)
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        onModalBusy?(false)
        if response == .alertFirstButtonReturn { store.clear() }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Microphone permission

    @objc private func recordTapped() {
        if recorder.isRecording { stopAndTranscribe(); return }
        guard server.state == .ready, phase != .transcribing else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: beginRecording()
        case .notDetermined: go(.needsPermission)          // only ask when the user taps Allow
        default: go(.denied)
        }
    }

    @objc private func allowTapped() {
        allowBtn.isEnabled = false
        requestingPermission = true
        onModalBusy?(true)                                  // keep the tile open behind the system dialog

        Task { [weak self] in
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard let self else { return }
            self.requestingPermission = false
            self.onModalBusy?(false)
            self.allowBtn.isEnabled = true
            NSApp.activate(ignoringOtherApps: true)

            if granted {
                self.go(.granted)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if self.screen == .granted { self.go(.home) }    // never starts recording by itself
            } else {
                self.go(.denied)
            }
        }
    }

    // MARK: Recording

    private func beginRecording() {
        do {
            try recorder.start()
            phase = .recording
            wave.reset()
            note = "0:00"
            render()
            onRecordingChange?(true)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func tick(level: CGFloat, elapsed: TimeInterval) {
        wave.push(level)
        note = Formats.duration(elapsed)
        info.stringValue = note
    }

    @objc private func discardTapped() { discardRecording() }

    private func discardRecording() {
        recorder.cancel()
        onRecordingChange?(false)
        phase = .idle
        note = ""
        render()
    }

    private func stopAndTranscribe() {
        let duration = recorder.stop()
        onRecordingChange?(false)
        if duration < 0.4 { fail("That was too short. Hold on a little longer."); return }

        phase = .transcribing
        note = ""
        render()

        let url = recorder.fileURL
        let started = Date()
        work = Task { [weak self] in
            do {
                let raw = try await TranscriptionClient.transcribe(fileURL: url, port: Config.port)
                self?.finish(raw: raw, duration: duration, took: Date().timeIntervalSince(started))
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
                self?.fail(error.localizedDescription)
            }
        }
    }

    private func finish(raw: String, duration: TimeInterval, took: TimeInterval) {
        let text = Self.clean(raw)
        guard !text.isEmpty else { fail("No speech detected."); return }

        let t = store.add(text: text, duration: duration)
        latest = t
        copyToPasteboard(text)
        phase = .done
        note = String(format: "Done in %.1fs · copied", took)
        render()
    }

    private func fail(_ message: String) {
        phase = .failed
        failText = message
        note = ""
        render()
    }

    /// Collapses whitespace and drops whisper's non-speech markers like [BLANK_AUDIO].
    private static func clean(_ raw: String) -> String {
        let t = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let wrapped = (t.hasPrefix("[") && t.hasSuffix("]")) || (t.hasPrefix("(") && t.hasSuffix(")"))
        return wrapped && t.count < 40 ? "" : t
    }
}
