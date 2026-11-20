import AVFoundation
import AppKit

/// The whole tile: home (server + recorder), history, and the microphone-permission screens.
@MainActor
final class PanelViewController: NSViewController {
    enum Phase { case idle, recording, transcribing, done, failed }
    enum Screen { case home, history, settings, needsPermission, denied, granted }

    // Callbacks into the app
    var onModalBusy: (@MainActor (Bool) -> Void)?  // true while a system dialog / save panel is up
    var onDialog: (@MainActor (Bool) -> Void)?  // true while one of our own dialogs is up (tile hides meanwhile)
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
    private var versionText = "whisper.cpp"
    private var work: Task<Void, Never>?

    // Screens
    private var homeStack: NSStackView!
    private var historyStack: NSStackView!
    private var settingsStack: NSStackView!
    private var permStack: NSStackView!
    private var deniedStack: NSStackView!
    private var grantedStack: NSStackView!

    // Home widgets
    private let dot = NSTextField(labelWithString: "●")
    private var powerBtn: IconButton!
    private var copyAddressBtn: IconButton!
    private let openBtn = NSButton(title: "Open web UI", target: nil, action: nil)
    private let versionLabel = UI.label("whisper.cpp", size: 11, color: .tertiaryLabelColor)
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

    // Settings widgets
    private let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let languageHint = UI.paragraph("", size: 11, color: .tertiaryLabelColor)
    private let rootPathLabel = UI.label("", size: 11, color: .secondaryLabelColor)
    private let modelsPathLabel = UI.label("", size: 11, color: .secondaryLabelColor)
    private let pathHint = UI.paragraph("", size: 11, color: .systemRed)
    private let launchSwitch = NSSwitch()
    private let autoCopySwitch = NSSwitch()

    // Permission widgets
    private let allowBtn = NSButton(title: "Allow microphone", target: nil, action: nil)

    // MARK: Init

    init(server: ServerController, store: TranscriptStore) {
        self.server = server
        self.store = store
        super.init(nibName: nil, bundle: nil)

        recorder.onTick = { [weak self] level, elapsed in self?.tick(level: level, elapsed: elapsed)
        }
        store.onChange = { [weak self] in self?.storeChanged() }
        exporter.onBusy = { [weak self] busy in self?.onDialog?(busy) }
        exporter.onResult = { [weak self] text in
            self?.note = text
            self?.render()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: View construction

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: UI.tileWidth, height: 300))
        view = root

        buildHome()
        buildHistory()
        buildSettings()
        buildPermission()
        buildDenied()
        buildGranted()

        for s in [
            homeStack!, historyStack!, settingsStack!, permStack!, deniedStack!, grantedStack!,
        ] {
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
        // Header: name + status dot ........ power button
        dot.font = .systemFont(ofSize: 9)
        powerBtn = IconButton(
            symbol: "power", tooltip: "Start server", side: 30, symbolSize: 15,
            target: self, action: #selector(serverTapped))
        let header = UI.row(
            [UI.label("WhisperBar", size: 15, weight: .semibold), dot, UI.spacer(), powerBtn],
            spacing: 6)

        // Address: localhost:9458 [copy] ........ Open web UI
        let address = UI.label("localhost:\(Config.port)", size: 12, color: .secondaryLabelColor)
        copyAddressBtn = IconButton(
            symbol: "doc.on.doc", tooltip: "Copy server address", side: 22, symbolSize: 11,
            target: self, action: #selector(copyAddressTapped))
        openBtn.target = self
        openBtn.action = #selector(openWebUITapped)
        openBtn.isBordered = false
        openBtn.attributedTitle = NSAttributedString(
            string: "Open web UI",
            attributes: [
                .foregroundColor: NSColor.controlAccentColor,
                .font: NSFont.systemFont(ofSize: 13),
            ])
        let addressRow = UI.row([address, copyAddressBtn, UI.spacer(), openBtn], spacing: 4)

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

        recBtn = IconButton(
            symbol: "mic.fill", tooltip: "Record", side: 40, symbolSize: 17,
            fill: .controlAccentColor, target: self, action: #selector(recordTapped))
        recBtn.keyEquivalent = "\r"
        discardBtn = IconButton(
            symbol: "xmark", tooltip: "Discard recording",
            target: self, action: #selector(discardTapped))
        copyBtn = IconButton(
            symbol: "doc.on.doc", tooltip: "Copy", target: self, action: #selector(copyTapped))
        exportBtn = IconButton(
            symbol: "square.and.arrow.up", tooltip: "Export…",
            target: self, action: #selector(exportTapped))
        historyBtn = IconButton(
            symbol: "clock.arrow.circlepath", tooltip: "History",
            target: self, action: #selector(historyTapped))
        info.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        info.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(1), for: .horizontal)
        let controls = UI.row(
            [recBtn, discardBtn, info, copyBtn, exportBtn, historyBtn], spacing: 6)

        // Footer: whisper.cpp version ........ log · settings · quit
        versionLabel.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(1), for: .horizontal)
        let logBtn = IconButton(
            symbol: "doc.text.magnifyingglass", tooltip: "Open server log",
            side: 24, symbolSize: 12, target: self, action: #selector(openLogTapped))
        let settingsBtn = IconButton(
            symbol: "gearshape", tooltip: "Settings",
            side: 24, symbolSize: 12, target: self, action: #selector(settingsTapped))
        let quitBtn = IconButton(
            symbol: "xmark.circle", tooltip: "Quit WhisperBar",
            side: 24, symbolSize: 12, target: self, action: #selector(quitTapped))
        let footer = UI.row([versionLabel, UI.spacer(), logBtn, settingsBtn, quitBtn], spacing: 4)

        homeStack = UI.column([
            header, addressRow, UI.separator(), slot, controls, UI.separator(), footer,
        ])
    }

    private func buildHistory() {
        let back = IconButton(
            symbol: "chevron.left", tooltip: "Back", target: self, action: #selector(backTapped))
        exportAllBtn = IconButton(
            symbol: "square.and.arrow.up", tooltip: "Export all…",
            target: self, action: #selector(exportAllTapped))
        clearBtn = IconButton(
            symbol: "trash", tooltip: "Clear history", target: self, action: #selector(clearTapped))
        let header = UI.row(
            [
                back, UI.label("History", size: 15, weight: .semibold), UI.spacer(), exportAllBtn,
                clearBtn,
            ],
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

    private func buildSettings() {
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)
        UI.fixedWidth(modelPopup)
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        UI.fixedWidth(languagePopup)
        for l in Languages.all {
            languagePopup.addItem(withTitle: l.name)
            languagePopup.lastItem?.representedObject = l.code
        }
        launchSwitch.target = self
        launchSwitch.action = #selector(launchToggled)
        autoCopySwitch.target = self
        autoCopySwitch.action = #selector(autoCopyToggled)

        let launchRow = UI.row(
            [UI.label("Start server on launch"), UI.spacer(), launchSwitch], spacing: 8)
        let copyRow = UI.row(
            [UI.label("Copy transcripts automatically"), UI.spacer(), autoCopySwitch], spacing: 8)

        for l in [rootPathLabel, modelsPathLabel] {
            l.lineBreakMode = .byTruncatingMiddle
            l.setContentCompressionResistancePriority(
                NSLayoutConstraint.Priority(1), for: .horizontal)
        }
        let rootChoose = IconButton(
            symbol: "folder", tooltip: "Choose whisper.cpp folder…", side: 24, symbolSize: 12,
            target: self, action: #selector(chooseRootTapped))
        let modelsChoose = IconButton(
            symbol: "folder", tooltip: "Choose models folder…", side: 24, symbolSize: 12,
            target: self, action: #selector(chooseModelsTapped))
        let modelsReveal = IconButton(
            symbol: "arrow.up.forward.square", tooltip: "Show in Finder", side: 24, symbolSize: 12,
            target: self, action: #selector(showModelsFolderTapped))
        let rootRow = UI.row([rootPathLabel, UI.spacer(), rootChoose], spacing: 4)
        let modelsRow = UI.row(
            [modelsPathLabel, UI.spacer(), modelsReveal, modelsChoose], spacing: 4)

        let resetBtn = NSButton(
            title: "Reset folders", target: self, action: #selector(resetPathsTapped))
        resetBtn.bezelStyle = .rounded
        resetBtn.image = Symbols.image("arrow.counterclockwise", size: 12)
        resetBtn.imagePosition = .imageLeading

        settingsStack = UI.column([
            backRow("Settings"),
            UI.separator(),
            UI.label("Model", size: 12, color: .secondaryLabelColor),
            modelPopup,
            UI.label("Language", size: 12, color: .secondaryLabelColor),
            languagePopup,
            languageHint,
            UI.separator(),
            launchRow,
            copyRow,
            UI.separator(),
            UI.label("whisper.cpp folder", size: 12, color: .secondaryLabelColor),
            rootRow,
            UI.label("Models folder", size: 12, color: .secondaryLabelColor),
            modelsRow,
            pathHint,
            resetBtn,
            UI.paragraph(
                "Changing the model, language or folders restarts the server.", size: 11,
                color: .tertiaryLabelColor),
        ])
    }

    private func backRow(_ title: String) -> NSView {
        let back = IconButton(
            symbol: "chevron.left", tooltip: "Back", target: self, action: #selector(backTapped))
        return UI.row(
            [back, UI.label(title, size: 15, weight: .semibold), UI.spacer()], spacing: 6)
    }

    private func buildPermission() {
        allowBtn.target = self
        allowBtn.action = #selector(allowTapped)
        allowBtn.bezelStyle = .rounded
        allowBtn.image = Symbols.image("mic.fill", size: 12)
        allowBtn.imagePosition = .imageLeading
        permStack = UI.column([
            backRow("Microphone access"),
            UI.paragraph(
                "WhisperBar records your voice and sends it to your local whisper server. macOS will ask you to confirm."
            ),
            allowBtn,
        ])
    }

    private func buildDenied() {
        let open = NSButton(
            title: "Open System Settings", target: self, action: #selector(openSettingsTapped))
        open.bezelStyle = .rounded
        open.image = Symbols.image("gearshape", size: 12)
        open.imagePosition = .imageLeading
        deniedStack = UI.column([
            backRow("Microphone is off"),
            UI.paragraph(
                "Turn it on for WhisperBar in System Settings → Privacy & Security → Microphone, then come back."
            ),
            open,
        ])
    }

    private func buildGranted() {
        let title = UI.label(
            "✓ Microphone access granted", size: 15, weight: .semibold, color: .systemGreen)
        grantedStack = UI.column([title, UI.paragraph("You can start recording now.")])
    }

    // MARK: Rendering (everything derives from server.state / phase / screen)

    private func render() {
        guard isViewLoaded else { return }

        homeStack.isHidden = screen != .home
        historyStack.isHidden = screen != .history
        settingsStack.isHidden = screen != .settings
        permStack.isHidden = screen != .needsPermission
        deniedStack.isHidden = screen != .denied
        grantedStack.isHidden = screen != .granted

        // Server header: dot + power button
        switch server.state {
        case .stopped:
            dot.isHidden = true
            powerBtn.setTint(.secondaryLabelColor)
            powerBtn.toolTip = "Start server"
            powerBtn.isEnabled = true
        case .starting:
            dot.isHidden = false
            dot.textColor = .systemOrange
            powerBtn.setTint(.systemOrange)
            powerBtn.toolTip = "Stop server"
            powerBtn.isEnabled = true
        case .ready:
            dot.isHidden = false
            dot.textColor = .systemGreen
            powerBtn.setTint(.systemGreen)
            powerBtn.toolTip = "Stop server"
            powerBtn.isEnabled = true
        case .stopping:
            dot.isHidden = false
            dot.textColor = .systemOrange
            powerBtn.setTint(.systemOrange)
            powerBtn.toolTip = "Stopping…"
            powerBtn.isEnabled = false
        }
        openBtn.isEnabled = server.state == .ready
        openBtn.alphaValue = server.state == .ready ? 1 : 0.35

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
                switch server.state {
                case .ready: message.stringValue = "Press the mic, then speak."
                case .stopping: message.stringValue = "Stopping server…"
                default: message.stringValue = "Start the server (top right) to begin."
                }
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
            historyList.addArrangedSubview(
                UI.paragraph("No transcripts yet. Your takes will show up here."))
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
        case .settings: current = settingsStack
        case .needsPermission: current = permStack
        case .denied: current = deniedStack
        case .granted: current = grantedStack
        }
        current.layoutSubtreeIfNeeded()
        let height = current.fittingSize.height
        if abs(preferredContentSize.height - height) > 0.5
            || preferredContentSize.width != UI.tileWidth
        {
            preferredContentSize = NSSize(width: UI.tileWidth, height: height)
        }
    }

    private func go(_ s: Screen) {
        screen = s
        render()
    }

    // MARK: Called by the app

    func serverChanged() {
        if server.state == .stopped || server.state == .stopping {
            if recorder.isRecording { discardRecording() }
            if phase == .transcribing {
                work?.cancel()
                phase = .idle
            }
        }
        render()
    }

    func setVersion(_ v: String) {
        versionText = "whisper.cpp \(v)"
        versionLabel.stringValue = versionText
        versionLabel.toolTip = versionText
    }

    /// Reopening the tile always lands on the home screen (unless the system dialog is up).
    func prepareForOpen() {
        guard !requestingPermission, screen != .home else { return }
        go(.home)
    }

    private func storeChanged() {
        if let l = latest, !store.items.contains(where: { $0.id == l.id }) {
            latest = nil
            if phase == .done {
                phase = .idle
                note = ""
            }
        }
        render()
    }

    // MARK: Actions

    @objc private func serverTapped() { server.toggle() }
    @objc private func quitTapped() { onQuit?() }
    @objc private func backTapped() { go(.home) }
    @objc private func historyTapped() { go(.history) }
    @objc private func settingsTapped() {
        refreshSettings()
        go(.settings)
    }

    @objc private func copyAddressTapped() {
        copyToPasteboard("http://localhost:\(Config.port)")
        copyAddressBtn.setSymbol("checkmark")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.copyAddressBtn.setSymbol("doc.on.doc")
        }
    }

    @objc private func openWebUITapped() {
        if let url = URL(string: "http://localhost:\(Config.port)/") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Settings

    private func refreshSettings() {
        var models = ModelCatalog.scan()
        let current = Settings.modelPath
        if !models.contains(where: { $0.path == current }) {
            models.insert(
                ModelInfo(path: current, name: ModelCatalog.displayName(for: current), size: ""),
                at: 0)
        }
        modelPopup.removeAllItems()
        for m in models {
            modelPopup.addItem(withTitle: m.size.isEmpty ? m.name : "\(m.name)  ·  \(m.size)")
            modelPopup.lastItem?.representedObject = m.path
        }
        if let i = models.firstIndex(where: { $0.path == current }) { modelPopup.selectItem(at: i) }

        refreshLanguage()
        launchSwitch.state = Settings.startServerOnLaunch ? .on : .off
        autoCopySwitch.state = Settings.autoCopy ? .on : .off
        refreshPaths()
    }

    private func refreshLanguage() {
        let englishOnly = ModelCatalog.isEnglishOnly(Settings.modelPath)
        let code = englishOnly ? "en" : Settings.language
        if let i = Languages.all.firstIndex(where: { $0.code == code }) {
            languagePopup.selectItem(at: i)
        }
        languagePopup.isEnabled = !englishOnly
        languageHint.isHidden = !englishOnly
        languageHint.stringValue =
            "English-only model. Pick one without “.en” in its name for other languages."
        updateSize()
    }

    @objc private func modelChanged() {
        guard let path = modelPopup.selectedItem?.representedObject as? String,
            path != Settings.modelPath
        else { return }
        Settings.modelPath = path
        server.restartIfRunning()
        refreshLanguage()
    }

    @objc private func languageChanged() {
        guard let code = languagePopup.selectedItem?.representedObject as? String,
            code != Settings.language
        else { return }
        Settings.language = code
        server.restartIfRunning()
    }

    @objc private func launchToggled() { Settings.startServerOnLaunch = launchSwitch.state == .on }
    @objc private func autoCopyToggled() { Settings.autoCopy = autoCopySwitch.state == .on }

    @objc private func showModelsFolderTapped() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Config.modelsDirectory))
    }
    // MARK: Folders

    private func refreshPaths() {
        rootPathLabel.stringValue = (Settings.whisperRoot as NSString).abbreviatingWithTildeInPath
        rootPathLabel.toolTip = Settings.whisperRoot
        modelsPathLabel.stringValue =
            (Settings.modelsDirectory as NSString).abbreviatingWithTildeInPath
        modelsPathLabel.toolTip = Settings.modelsDirectory

        var problems: [String] = []
        if !FileManager.default.isExecutableFile(atPath: Config.serverBinary) {
            problems.append("whisper-server not found at build/bin/ in this folder.")
        }
        if ModelCatalog.scan().isEmpty {
            problems.append("No ggml-*.bin models in the models folder.")
        }
        pathHint.stringValue = problems.joined(separator: "\n")
        pathHint.isHidden = problems.isEmpty
        updateSize()
    }

    @objc private func chooseRootTapped() {
        guard
            let url = pickFolder(
                title: "Choose your whisper.cpp folder", start: Settings.whisperRoot)
        else { return }
        Settings.whisperRoot = url.path
        pathsChanged()
    }

    @objc private func chooseModelsTapped() {
        guard
            let url = pickFolder(
                title: "Choose the folder with your ggml models", start: Settings.modelsDirectory)
        else { return }
        Settings.modelsDirectory = url.path
        pathsChanged()
    }

    @objc private func resetPathsTapped() {
        Settings.resetPaths()
        pathsChanged()
    }

    private func pickFolder(title: String, start: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: start, isDirectory: true)

        onDialog?(true)  // tile hides while the dialog is up
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        onDialog?(false)
        return response == .OK ? panel.url : nil
    }

    /// A folder changed: make sure the selected model still exists in the models folder, then apply.
    private func pathsChanged() {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: Settings.modelsDirectory).standardizedFileURL.path
        let current = URL(fileURLWithPath: Settings.modelPath).standardizedFileURL
        if current.deletingLastPathComponent().path != dir || !fm.fileExists(atPath: current.path) {
            let candidates = [Config.defaultModelPath] + ModelCatalog.scan().map(\.path)
            if let ok = candidates.first(where: { fm.fileExists(atPath: $0) }) {
                Settings.modelPath = ok
            }
        }
        server.restartIfRunning()
        refreshVersion()
        refreshSettings()
    }

    private func refreshVersion() {
        Task { [weak self] in
            let version = await Task.detached { WhisperInfo.versionString() }.value
            self?.setVersion(version)
        }
    }

    @objc private func openLogTapped() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Config.logPath))
    }

    @objc private func openSettingsTapped() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        {
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

        onDialog?(true)
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        onDialog?(false)
        if response == .alertFirstButtonReturn { store.clear() }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Microphone permission

    @objc private func recordTapped() {
        if recorder.isRecording {
            stopAndTranscribe()
            return
        }
        guard server.state == .ready, phase != .transcribing else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: beginRecording()
        case .notDetermined: go(.needsPermission)  // only ask when the user taps Allow
        default: go(.denied)
        }
    }

    @objc private func allowTapped() {
        allowBtn.isEnabled = false
        requestingPermission = true
        onModalBusy?(true)  // keep the tile open behind the system dialog

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
                if self.screen == .granted { self.go(.home) }  // never starts recording by itself
            } else {
                self.go(.denied)
            }
        }
    }

    // MARK: Recording

    private func beginRecording() {
        do {
            try recorder.start()
            server.setBusy(true)
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
        server.setBusy(false)
        onRecordingChange?(false)
        phase = .idle
        note = ""
        render()
    }

    private func stopAndTranscribe() {
        let duration = recorder.stop()
        onRecordingChange?(false)
        if duration < 0.4 {
            fail("That was too short. Hold on a little longer.")
            return
        }

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
        guard !text.isEmpty else {
            fail("No speech detected.")
            return
        }

        let t = store.add(text: text, duration: duration)
        latest = t
        if Settings.autoCopy { copyToPasteboard(text) }
        server.setBusy(false)
        phase = .done
        note = String(format: "Done in %.1fs", took) + (Settings.autoCopy ? " · copied" : "")
        render()
    }

    private func fail(_ message: String) {
        server.setBusy(false)
        phase = .failed
        failText = message
        note = ""
        render()
    }

    /// Collapses whitespace and drops whisper's non-speech markers like [BLANK_AUDIO].
    private static func clean(_ raw: String) -> String {
        let t = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let wrapped =
            (t.hasPrefix("[") && t.hasSuffix("]")) || (t.hasPrefix("(") && t.hasSuffix(")"))
        return wrapped && t.count < 40 ? "" : t
    }
}
