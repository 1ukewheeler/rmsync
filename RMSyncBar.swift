// RMSyncBar - a menu bar indicator for rmsync.
//
// Shows "RM" in the menu bar, coloured by state, and starts a sync when the
// tablet appears on USB. It does not implement syncing: it shells out to
// rmsync.py, which stays the single source of truth for what a sync is.
//
// Build:  swiftc -O -swift-version 5 -framework Cocoa -o rmsyncbar RMSyncBar.swift

import Cocoa
import Darwin

// MARK: - Tablet reachability

/// Non-blocking TCP connect. The USB web interface answers on port 80 only
/// while it is actually serving, so a successful connect is a real signal --
/// and a refusal comes back immediately rather than hanging.
func tcpReachable(_ host: String, _ port: UInt16, timeout: TimeInterval) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }

    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    var rc: Int32 = -1
    withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            rc = connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if rc == 0 { return true }
    guard errno == EINPROGRESS else { return false }

    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return false }

    var soErr: Int32 = 0
    var len = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
    return soErr == 0
}

// MARK: - State

enum State {
    case away          // no tablet on USB
    case ready         // tablet present, nothing to do
    case syncing       // rmsync.py running
    case done          // last sync succeeded
    case failed        // last sync exited non-zero

    var color: NSColor {
        switch self {
        case .away:    return .tertiaryLabelColor
        case .ready:   return .labelColor
        case .syncing: return .systemBlue
        case .done:    return .systemGreen
        case .failed:  return .systemRed
        }
    }

    var detail: String {
        switch self {
        case .away:    return "Tablet not connected"
        case .ready:   return "Tablet connected"
        case .syncing: return "Syncing…"
        case .done:    return "Last sync succeeded"
        case .failed:  return "Last sync FAILED - see log"
        }
    }
}

// MARK: - App

final class RMSyncBar: NSObject, NSApplicationDelegate {

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let host = "10.11.99.1"
    private let port: UInt16 = 80

    // Paths are discovered from where this binary lives, so moving the folder
    // does not require editing anything.
    private let scriptURL: URL = {
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        let beside = exeDir.appendingPathComponent("rmsync.py")
        if FileManager.default.isReadableFile(atPath: beside.path) { return beside }
        return URL(fileURLWithPath: NSHomeDirectory() + "/rmsync/rmsync.py")
    }()

    private let logURL = URL(fileURLWithPath:
        NSHomeDirectory() + "/Library/Logs/rmsync.log")

    private var state: State = .away { didSet { render() } }
    private var running: Process?
    private var timer: Timer?

    // Reachability flaps (the web interface briefly stops while the tablet
    // renders a large document), so a connect/disconnect is only believed
    // after it holds for several consecutive polls.
    private var hits = 0
    private var misses = 0
    private var connected = false
    private var syncedThisConnection = false

    // --no-auto starts with auto-sync off: useful when a sync is already
    // running by other means, or to observe state without triggering work.
    private var autoSync = !CommandLine.arguments.contains("--no-auto")
    private var lastSummary = "never run"

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        render()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    // MARK: menu bar rendering

    private func render() {
        guard let button = item.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        button.attributedTitle = NSAttributedString(
            string: "RM",
            attributes: [.foregroundColor: state.color, .font: font])
        button.toolTip = "rmsync - \(state.detail)"
        statusLine?.title = state.detail
        summaryLine?.title = "Last: \(lastSummary)"
    }

    private var statusLine: NSMenuItem?
    private var summaryLine: NSMenuItem?
    private var autoLine: NSMenuItem?

    private func buildMenu() {
        let menu = NSMenu()

        statusLine = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
        statusLine!.isEnabled = false
        menu.addItem(statusLine!)

        summaryLine = NSMenuItem(title: "Last: never run", action: nil, keyEquivalent: "")
        summaryLine!.isEnabled = false
        menu.addItem(summaryLine!)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Sync Now",
                                action: #selector(syncNow), keyEquivalent: "s"))

        autoLine = NSMenuItem(title: "Sync When Connected",
                              action: #selector(toggleAuto), keyEquivalent: "")
        autoLine!.state = autoSync ? .on : .off
        menu.addItem(autoLine!)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Remarkable Folder",
                                action: #selector(openFolder), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Open Log",
                                action: #selector(openLog), keyEquivalent: "l"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit rmsync",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        for i in menu.items where i.action != nil { i.target = self }
        item.menu = menu
    }

    // MARK: polling / edge detection

    private func poll() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let up = tcpReachable(self.host, self.port, timeout: 2.0)
            DispatchQueue.main.async { self.observed(up) }
        }
    }

    private func observed(_ up: Bool) {
        if up { hits += 1; misses = 0 } else { misses += 1; hits = 0 }

        // Debounce: 2 good polls to connect, 3 bad ones to disconnect. The
        // asymmetry is deliberate -- a mid-render blip must not look like an
        // unplug and re-trigger a whole sync.
        if !connected && hits >= 2 {
            connected = true
            syncedThisConnection = false
        } else if connected && misses >= 3 {
            connected = false
        }

        if running != nil { return }   // never disturb a sync in flight

        if connected && autoSync && !syncedThisConnection {
            syncedThisConnection = true
            startSync()
            return
        }
        if !connected {
            state = .away
        } else if state == .away {
            state = .ready
        }
    }

    // MARK: running rmsync.py

    @objc private func syncNow() {
        guard running == nil else { return }
        startSync()
    }

    private func startSync() {
        guard running == nil else { return }
        guard FileManager.default.isReadableFile(atPath: scriptURL.path) else {
            lastSummary = "rmsync.py not found"
            state = .failed
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", scriptURL.path]

        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let fh = try? FileHandle(forWritingTo: logURL) {
            fh.seekToEndOfFile()
            let stamp = "\n=== \(Date()) ===\n"
            fh.write(stamp.data(using: .utf8)!)
            p.standardOutput = fh
            p.standardError = fh
        }

        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = nil
                let ok = proc.terminationStatus == 0
                self.lastSummary = (ok ? "OK" : "exit \(proc.terminationStatus)")
                    + " at " + Self.clock.string(from: Date())
                self.state = ok ? .done : .failed
            }
        }

        do {
            try p.run()
            running = p
            state = .syncing
        } catch {
            lastSummary = "could not start: \(error.localizedDescription)"
            state = .failed
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    // MARK: menu actions

    @objc private func toggleAuto() {
        autoSync.toggle()
        autoLine?.state = autoSync ? .on : .off
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath:
            NSHomeDirectory() + "/NotesDev/Remarkable"))
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(logURL)
    }
}

let app = NSApplication.shared
let delegate = RMSyncBar()
app.delegate = delegate
app.run()
