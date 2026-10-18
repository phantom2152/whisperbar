import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let quitMenu = NSMenu()
    private let server = ServerController()
    private let store = TranscriptStore()
    private var panel: PanelViewController!

    private var signalSources: [DispatchSourceSignal] = []
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var autoCloseSuspended = false      // true while a system dialog / save panel is up
    private var isRecording = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        server.killStrays()

        // Menu bar icon: left click toggles the tile, right click shows a tiny Quit menu
        if let button = item.button {
            button.target = self
            button.action = #selector(statusClicked)
            _ = button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        quitMenu.addItem(NSMenuItem(title: "Quit WhisperBar", action: #selector(NSApplication.terminate(_:)),
                                    keyEquivalent: "q"))
        updateIcon()

        panel = PanelViewController(server: server, store: store)
        panel.onQuit = { NSApp.terminate(nil) }
        panel.onModalBusy = { [weak self] busy in self?.autoCloseSuspended = busy }
        panel.onRecordingChange = { [weak self] recording in
            self?.isRecording = recording
            self?.updateIcon()
        }
        server.onChange = { [weak self] in
            self?.panel.serverChanged()
            self?.updateIcon()
        }
        _ = panel.view                                   // build the UI now so early updates have somewhere to land

        popover.contentViewController = panel
        popover.behavior = .applicationDefined           // we decide when it closes

        // pkill / Ctrl+C take the normal quit path, so the server dies with the app
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { Task { @MainActor in NSApp.terminate(nil) } }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.terminateNow()
    }

    // MARK: Menu bar icon

    private func updateIcon() {
        let state: MenuBarIcon.State
        if isRecording { state = .recording }
        else if server.state == .ready { state = .ready }
        else { state = .off }
        item.button?.image = MenuBarIcon.image(state)
        item.button?.toolTip = "WhisperBar"
    }

    // MARK: Tile open / close

    @objc private func statusClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            item.menu = quitMenu
            item.button?.performClick(nil)
            item.menu = nil
            return
        }
        if popover.isShown { closePopover() } else { showPopover() }
    }

    private func showPopover() {
        guard let button = item.button else { return }
        panel.prepareForOpen()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // A click in ANOTHER app closes the tile (clicks inside our own windows never reach this)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.autoCloseSuspended else { return }
                self.closePopover()
            }
        }
        // Esc closes the tile (ignored while a dialog is up, so Esc still cancels the dialog)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] (event: NSEvent) -> NSEvent? in
            guard event.keyCode == 53 else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.popover.isShown, !self.autoCloseSuspended else { return false }
                self.closePopover()
                return true
            }
            return handled ? nil : event
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}
