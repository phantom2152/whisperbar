import AppKit
import AVFoundation

// MARK: - Live waveform

@MainActor
final class WaveformView: NSView {
    private var levels: [CGFloat] = []
    private let barW: CGFloat = 3
    private let gap: CGFloat = 2

    func reset() { levels.removeAll(); needsDisplay = true }

    func push(_ v: CGFloat) {
        levels.append(v)
        let maxBars = max(1, Int(bounds.width / (barW + gap)))
        if levels.count > maxBars { levels.removeFirst(levels.count - maxBars) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let step = barW + gap
        let maxBars = max(1, Int(bounds.width / step))
        for k in 0..<maxBars {
            let idx = levels.count - maxBars + k          // newest bar sits on the right
            let live = idx >= 0
            (live ? NSColor.systemRed : NSColor.tertiaryLabelColor).setFill()
            let h = max(3, (live ? levels[idx] : 0) * bounds.height)
            let r = NSRect(x: bounds.minX + CGFloat(k) * step, y: bounds.midY - h / 2, width: barW, height: h)
            NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
        }
    }
}

// MARK: - The tile

enum ServerState { case stopped, starting, ready, stopping }

@MainActor
final class PanelVC: NSViewController {
    enum Phase { case idle, recording, transcribing, done, failed }
    enum Screen { case home, needsPermission, denied, granted }

    static let W: CGFloat = 292          // content width inside the 14pt insets
    let port: Int

    // Callbacks into the app
    var onToggleServer: (@MainActor () -> Void)?
    var onQuit: (@MainActor () -> Void)?
    var onRecordingChange: (@MainActor (Bool) -> Void)?
    var onPermissionBusy: (@MainActor (Bool) -> Void)?

    // State
    var serverState: ServerState = .stopped
    var phase: Phase = .idle
    var screen: Screen = .home
    var requestingPermission = false
    var lastText = ""
    var failText = ""
    var note = ""

    // Recording
    var recorder: AVAudioRecorder?
    var meterTimer: Timer?
    var startedAt = Date()
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("whisperbar.wav")

    // Screens
    var homeStack: NSStackView!
    var permStack: NSStackView!
    var deniedStack: NSStackView!
    var grantedStack: NSStackView!

    // Home widgets
    let dot = NSTextField(labelWithString: "●")
    let statusLabel = NSTextField(labelWithString: "")
    let serverBtn = NSButton(title: "Start Server", target: nil, action: nil)
    let wave = WaveformView()
    let message = NSTextField(wrappingLabelWithString: "")
    let recBtn = NSButton(title: "Record", target: nil, action: nil)
    let copyBtn = NSButton(title: "Copy", target: nil, action: nil)
    let info = NSTextField(labelWithString: "")

    // Permission widgets
    let allowBtn = NSButton(title: "Allow Microphone", target: nil, action: nil)

    init(port: Int) { self.port = port; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Building blocks

    func fix<V: NSView>(_ v: V) -> V {
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: Self.W).isActive = true
        return v
    }

    func spacer() -> NSView {
        let s = NSView()
        s.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return s
    }

    func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.distribution = .fill
        r.alignment = .centerY
        r.spacing = spacing
        return fix(r)
    }

    func column(_ views: [NSView]) -> NSStackView {
        let c = NSStackView(views: views)
        c.orientation = .vertical
        c.alignment = .leading
        c.spacing = 10
        c.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        c.translatesAutoresizingMaskIntoConstraints = false
        c.widthAnchor.constraint(equalToConstant: 320).isActive = true
        return c
    }

    func separator() -> NSView {
        let b = NSBox()
        b.boxType = .separator
        return fix(b)
    }

    func title(_ s: String, size: CGFloat = 15) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: size, weight: .semibold)
        return t
    }

    func body(_ s: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .systemFont(ofSize: 13)
        t.textColor = .secondaryLabelColor
        t.preferredMaxLayoutWidth = Self.W
        return fix(t)
    }

    func backRow() -> NSView {
        let b = NSButton(title: "Back", target: self, action: #selector(backTapped))
        b.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        b.imagePosition = .imageLeading
        b.isBordered = false
        b.contentTintColor = .secondaryLabelColor
        return row([b, spacer()])
    }

    // MARK: View

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 260))
        view = root

        buildHome()
        buildPermission()
        buildDenied()
        buildGranted()

        for s in [homeStack!, permStack!, deniedStack!, grantedStack!] {
            root.addSubview(s)
            NSLayoutConstraint.activate([
                s.topAnchor.constraint(equalTo: root.topAnchor),
                s.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                s.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
        }
        render()
    }

    func buildHome() {
        // Header: title ........ ● status
        dot.font = .systemFont(ofSize: 10)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        let header = row([title("Whisper"), spacer(), dot, statusLabel], spacing: 5)

        // Server button
        serverBtn.target = self; serverBtn.action = #selector(serverTapped)
        serverBtn.bezelStyle = .rounded
        _ = fix(serverBtn)

        // Recorder slot: waveform while recording, text otherwise
        let slot = NSView()
        _ = fix(slot)
        for v in [wave, message] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            slot.addSubview(v)
        }
        message.font = .systemFont(ofSize: 14)
        message.maximumNumberOfLines = 4
        message.lineBreakMode = .byTruncatingTail
        message.cell?.truncatesLastVisibleLine = true
        message.isSelectable = true
        message.preferredMaxLayoutWidth = Self.W
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

        // Record / Copy / info
        recBtn.target = self; recBtn.action = #selector(recordTapped)
        recBtn.keyEquivalent = "\r"
        copyBtn.target = self; copyBtn.action = #selector(copyText)
        info.font = .systemFont(ofSize: 12)
        info.textColor = .secondaryLabelColor
        info.lineBreakMode = .byTruncatingTail
        info.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let controls = row([recBtn, copyBtn, info], spacing: 10)

        // Footer
        let foot = NSTextField(labelWithString: "whisper.cpp · localhost:\(port)")
        foot.font = .systemFont(ofSize: 11)
        foot.textColor = .tertiaryLabelColor
        let quit = NSButton(title: "Quit", target: self, action: #selector(quitTapped))
        let footer = row([foot, spacer(), quit])

        homeStack = column([header, serverBtn, separator(), slot, controls, separator(), footer])
    }

    func buildPermission() {
        allowBtn.target = self; allowBtn.action = #selector(allowTapped)
        permStack = column([
            backRow(),
            title("Microphone access needed"),
            body("WhisperBar records your voice and sends it to your local whisper server. macOS will ask you to confirm."),
            allowBtn,
        ])
    }

    func buildDenied() {
        let open = NSButton(title: "Open System Settings", target: self, action: #selector(openSettings))
        deniedStack = column([
            backRow(),
            title("Microphone access is off"),
            body("Turn it on for WhisperBar in System Settings → Privacy & Security → Microphone, then come back."),
            open,
        ])
    }

    func buildGranted() {
        let t = title("✓ Microphone access granted")
        t.textColor = .systemGreen
        grantedStack = column([t, body("You can start recording now.")])
    }

    // MARK: Rendering (everything is derived from serverState / phase / screen)

    func render() {
        guard homeStack != nil else { return }

        homeStack.isHidden = screen != .home
        permStack.isHidden = screen != .needsPermission
        deniedStack.isHidden = screen != .denied
        grantedStack.isHidden = screen != .granted

        // Server header + button
        switch serverState {
        case .stopped:
            dot.textColor = .tertiaryLabelColor; statusLabel.stringValue = "Stopped"
            serverBtn.title = "Start Server"; serverBtn.isEnabled = true
        case .starting:
            dot.textColor = .systemOrange; statusLabel.stringValue = "Starting…"
            serverBtn.title = "Stop Server"; serverBtn.isEnabled = true
        case .ready:
            dot.textColor = .systemGreen; statusLabel.stringValue = "Ready"
            serverBtn.title = "Stop Server"; serverBtn.isEnabled = true
        case .stopping:
            dot.textColor = .systemOrange; statusLabel.stringValue = "Stopping…"
            serverBtn.title = "Stopping…"; serverBtn.isEnabled = false
        }

        // Recorder
        let recording = phase == .recording
        wave.isHidden = !recording
        message.isHidden = recording
        message.toolTip = nil
        recBtn.title = recording ? "Stop" : "Record"
        recBtn.bezelColor = recording ? .systemRed : nil
        recBtn.isEnabled = recording || (serverState == .ready && phase != .transcribing)
        copyBtn.isEnabled = !lastText.isEmpty && !recording
        info.stringValue = note

        switch phase {
        case .recording:
            break
        case .transcribing:
            message.stringValue = "Transcribing…"; message.textColor = .secondaryLabelColor
        case .done:
            message.stringValue = lastText; message.textColor = .labelColor; message.toolTip = lastText
        case .failed:
            message.stringValue = failText; message.textColor = .systemRed
        case .idle:
            message.stringValue = serverState == .ready ? "Press Record, then speak." : "Start the server to record."
            message.textColor = .secondaryLabelColor
        }

        updateSize()
    }

    func updateSize() {
        let current: NSStackView
        switch screen {
        case .home: current = homeStack
        case .needsPermission: current = permStack
        case .denied: current = deniedStack
        case .granted: current = grantedStack
        }
        current.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: 320, height: current.fittingSize.height)
    }

    func go(_ s: Screen) { screen = s; render() }

    // MARK: Called by the app

    func setServer(_ s: ServerState) { serverState = s; render() }

    func serverDied() {
        serverState = .stopped
        cancelRecording()
    }

    func cancelRecording() {
        if recorder != nil { endRecording() }
        if phase == .recording { phase = .idle }
        note = ""
        render()
    }

    func prepareForOpen() {
        if !requestingPermission, screen != .home { go(.home) }
    }

    // MARK: Actions

    @objc func serverTapped() { onToggleServer?() }
    @objc func quitTapped() { onQuit?() }
    @objc func backTapped() { go(.home) }

    @objc func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func recordTapped() {
        if phase == .recording { stopAndTranscribe(); return }
        guard serverState == .ready else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            begin()
        case .notDetermined:
            go(.needsPermission)            // ask only when the user clicks Allow
        default:
            go(.denied)
        }
    }

    @objc func allowTapped() {
        allowBtn.isEnabled = false
        requestingPermission = true
        onPermissionBusy?(true)             // keep the tile open while the system dialog is up

        AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.requestingPermission = false
                self.onPermissionBusy?(false)
                self.allowBtn.isEnabled = true
                NSApp.activate(ignoringOtherApps: true)

                if ok {
                    self.go(.granted)
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if self.screen == .granted { self.go(.home) }
                    }
                } else {
                    self.go(.denied)
                }
            }
        }
    }

    // MARK: Recording

    func begin() {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let r = try AVAudioRecorder(url: fileURL, settings: settings)
            r.isMeteringEnabled = true
            r.record()
            recorder = r
            startedAt = Date()
            wave.reset()

            let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            meterTimer = t

            phase = .recording
            note = "0:00"
            render()
            onRecordingChange?(true)
        } catch { fail("Recorder error: \(error.localizedDescription)") }
    }

    func tick() {
        guard let r = recorder, r.isRecording else { return }
        r.updateMeters()
        let db = r.averagePower(forChannel: 0)              // roughly -160 … 0 dB
        wave.push(CGFloat(max(0, (db + 50) / 50)))
        let s = Int(Date().timeIntervalSince(startedAt))
        note = String(format: "%d:%02d", s / 60, s % 60)
        info.stringValue = note
    }

    func endRecording() {
        meterTimer?.invalidate(); meterTimer = nil
        recorder?.stop(); recorder = nil
        onRecordingChange?(false)
    }

    func stopAndTranscribe() {
        endRecording()
        phase = .transcribing
        note = ""
        render()
        upload()
    }

    // MARK: Upload

    func upload() {
        guard let audio = try? Data(contentsOf: fileURL) else { return fail("No audio captured") }
        let boundary = UUID().uuidString
        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n")
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"rec.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(audio)
        add("\r\n--\(boundary)--\r\n")

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let t0 = Date()
        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error { return self.fail("Server error: \(error.localizedDescription)") }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let text = json["text"] as? String else { return self.fail("Bad response") }

                self.lastText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                self.copyText()
                self.phase = .done
                self.note = String(format: "Done in %.1fs · copied", Date().timeIntervalSince(t0))
                self.render()
            }
        }.resume()
    }

    @objc func copyText() {
        guard !lastText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastText, forType: .string)
    }

    func fail(_ msg: String) {
        phase = .failed
        failText = msg
        note = ""
        render()
    }
}

// MARK: - App

@MainActor
final class App: NSObject, NSApplicationDelegate {
    let root = "/Users/anishgowda/playground/ThirdParty/whisper.cpp"
    let port = 9458

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    let quitMenu = NSMenu()
    var panel: PanelVC!
    var server: Process?
    var sigSources: [DispatchSourceSignal] = []
    var clickMonitor: Any?
    var suppressAutoClose = false

    func applicationDidFinishLaunching(_ n: Notification) {
        killStrays()

        // Icon: click toggles the tile, right-click shows a tiny Quit menu
        if let b = item.button {
            b.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
            b.target = self
            b.action = #selector(statusClicked)
            _ = b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        quitMenu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        panel = PanelVC(port: port)
        panel.onToggleServer = { [weak self] in self?.flip() }
        panel.onQuit = { NSApp.terminate(nil) }
        panel.onPermissionBusy = { [weak self] busy in self?.suppressAutoClose = busy }
        // Red mic in the menu bar while recording (the tile may be closed)
        panel.onRecordingChange = { [weak self] on in
            self?.item.button?.image = NSImage(systemSymbolName: on ? "mic.fill" : "mic", accessibilityDescription: nil)
            self?.item.button?.contentTintColor = on ? .systemRed : nil
        }

        popover.contentViewController = panel
        popover.behavior = .applicationDefined      // we decide when it closes

        // pkill / Ctrl+C go through the normal quit path so the server dies too
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                Task { @MainActor in NSApp.terminate(nil) }
            }
            src.resume()
            sigSources.append(src)
        }
    }

    // MARK: Tile open / close

    @objc func statusClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            item.menu = quitMenu
            item.button?.performClick(nil)
            item.menu = nil
            return
        }
        if popover.isShown { closePopover() } else { showPopover() }
    }

    func showPopover() {
        guard let button = item.button else { return }
        panel.prepareForOpen()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // Clicks in OTHER apps close the tile (clicks inside our own windows never reach this)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.suppressAutoClose else { return }
                self.closePopover()
            }
        }
    }

    func closePopover() {
        popover.performClose(nil)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    // MARK: Server lifecycle

    func flip() {
        if let s = server, s.isRunning { stopServer(s) } else { startServer() }
    }

    func startServer() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "\(root)/build/bin/whisper-server")
        p.currentDirectoryURL = URL(fileURLWithPath: root)
        p.arguments = ["-m", "\(root)/models/ggml-base.en.bin", "--convert",
                       "--port", "\(port)"]

        let logPath = "/tmp/whisperbar.log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let log = FileHandle(forWritingAtPath: logPath)
        p.standardOutput = log
        p.standardError = log

        // Runs on a background thread: capture only the pid, then hop to main
        p.terminationHandler = { proc in
            let pid = proc.processIdentifier
            Task { @MainActor in
                guard let me = NSApp.delegate as? App,
                      me.server?.processIdentifier == pid else { return }  // ignore stale processes
                me.server = nil
                me.panel.serverDied()
            }
        }
        do {
            try p.run()
            server = p
            panel.setServer(.starting)
            waitUntilReady(pid: p.processIdentifier)
        } catch {
            NSLog("Failed to start whisper-server: \(error)")
            panel.setServer(.stopped)
        }
    }

    /// The model takes a moment to load; flip to "Ready" once the port answers
    func waitUntilReady(pid: Int32) {
        Task {
            for _ in 0..<120 {
                guard server?.processIdentifier == pid else { return }
                if await probe() {
                    if panel.serverState == .starting { panel.setServer(.ready) }
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func probe() async -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        req.timeoutInterval = 1
        do { _ = try await URLSession.shared.data(for: req); return true }   // any HTTP reply = up
        catch { return false }
    }

    func stopServer(_ s: Process) {
        panel.setServer(.stopping)
        panel.cancelRecording()

        let pid = s.processIdentifier
        s.terminate()                                    // SIGTERM (graceful)
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }  // still alive → force
        }
    }

    func killStrays() {
        let k = Process()
        k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        k.arguments = ["-f", "whisper-server.*--port \(port)"]
        try? k.run(); k.waitUntilExit()
    }

    func applicationWillTerminate(_ n: Notification) {
        if let s = server, s.isRunning { kill(s.processIdentifier, SIGKILL) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()