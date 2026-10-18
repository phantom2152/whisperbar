import Foundation

enum ServerState { case stopped, starting, ready, stopping }

/// Owns the whisper-server child process.
@MainActor
final class ServerController {
    private(set) var state: ServerState = .stopped
    private(set) var problem: String?
    var onChange: (@MainActor () -> Void)?

    private var process: Process?
    private var logHandle: FileHandle?
    private var restartPending = false

    // MARK: Control

    func toggle() {
        switch state {
        case .stopped: start()
        case .starting, .ready: stop()
        case .stopping: break
        }
    }

    func start() {
        guard state == .stopped else { return }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: Config.serverBinary) else {
            return apply(.stopped, problem: "whisper-server not found:\n\(Config.serverBinary)")
        }
        let model = Settings.modelPath
        guard fm.fileExists(atPath: model) else {
            return apply(.stopped, problem: "Model not found:\n\(model)")
        }
        killStrays()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: Config.serverBinary)
        p.currentDirectoryURL = URL(fileURLWithPath: Config.whisperRoot)
        // “.en” models only speak English, so never pass them another language
        let language = ModelCatalog.isEnglishOnly(model) ? "en" : Settings.language
        p.arguments = ["-m", model, "--port", "\(Config.port)", "-l", language]
            + Config.extraServerArguments.filter { !$0.isEmpty }

        // Log to a file instead of inheriting a terminal
        fm.createFile(atPath: Config.logPath, contents: nil)
        let log = FileHandle(forWritingAtPath: Config.logPath)
        logHandle = log
        p.standardOutput = log
        p.standardError = log

        // Runs on a background thread: capture only the pid, then hop to the main actor
        p.terminationHandler = { [weak self] proc in
            let pid = proc.processIdentifier
            Task { @MainActor [weak self] in self?.handleExit(pid: pid) }
        }

        do {
            try p.run()
            process = p
            apply(.starting)
            waitUntilReady(pid: p.processIdentifier)
        } catch {
            try? logHandle?.close(); logHandle = nil
            apply(.stopped, problem: "Couldn’t start the server: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let p = process, p.isRunning else { return }
        let pid = p.processIdentifier
        apply(.stopping)
        p.terminate()                                   // SIGTERM (graceful)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, let p = self.process, p.processIdentifier == pid, p.isRunning else { return }
            kill(pid, SIGKILL)                          // still alive: force
        }
    }

    /// Applies a changed model/language: stop, then start again once the old process is gone.
    func restartIfRunning() {
        guard state == .starting || state == .ready else { return }
        restartPending = true
        stop()
    }

    /// Used on app quit: no waiting around.
    func terminateNow() {
        if let p = process, p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    /// Kills leftovers from a previous crashed run that still hold our port.
    func killStrays() {
        let k = Process()
        k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        k.arguments = ["-f", "whisper-server.*--port \(Config.port)"]
        try? k.run()
        k.waitUntilExit()
    }

    // MARK: Internals

    private func apply(_ s: ServerState, problem p: String? = nil) {
        state = s
        problem = p
        onChange?()
    }

    private func handleExit(pid: Int32) {
        guard process?.processIdentifier == pid else { return }      // stale process, ignore
        let unexpected = state == .starting || state == .ready
        let restart = restartPending
        restartPending = false
        process = nil
        try? logHandle?.close()
        logHandle = nil
        apply(.stopped, problem: unexpected ? "The server exited unexpectedly.\nOpen the log for details." : nil)
        if restart { start() }
    }

    /// The model takes a moment to load: flip to "ready" once the port answers.
    private func waitUntilReady(pid: Int32) {
        Task { [weak self] in
            for _ in 0..<240 {
                guard let self, self.process?.processIdentifier == pid else { return }
                if await Self.probe() {
                    if self.state == .starting { self.apply(.ready) }
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    nonisolated private static func probe() async -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(Config.port)/")!)
        req.timeoutInterval = 1
        return (try? await URLSession.shared.data(for: req)) != nil   // any HTTP reply = up
    }
}
