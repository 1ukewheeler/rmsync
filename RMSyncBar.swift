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

/// One probe, on a raw socket, answering both questions at once:
///   present -- did TCP connect?  serving -- did HTTP return 200?
///
/// This deliberately does NOT use URLSession. CFNetwork was observed timing
/// out against 10.11.99.1 in the same seconds that curl fetched it in 5ms,
/// with identical headers; it appears to prefer the primary interface rather
/// than the specific route to the tablet over en7. Plain BSD sockets follow
/// the routing table, which is what we want.
///
/// A TCP connect alone is not readiness: the interface reaches a wedged state
/// where it accepts connections but never answers. Both signals are needed --
/// present && !serving is exactly the "toggle USB file access" case.
func probe(_ host: String, _ port: UInt16, timeout: TimeInterval)
    -> (present: Bool, serving: Bool) {

    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return (false, false) }
    defer { close(fd) }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return (false, false) }

    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    var rc: Int32 = -1
    withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            rc = connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if rc != 0 {
        guard errno == EINPROGRESS else { return (false, false) }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return (false, false) }
        var soErr: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
        guard soErr == 0 else { return (false, false) }
    }
    // TCP is up from here on; anything further failing means "wedged".

    _ = fcntl(fd, F_SETFL, flags)          // back to blocking, with timeouts
    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    // HTTP/1.0 + close: the server hangs up after replying, no keep-alive to
    // get stuck behind.
    let request = "GET / HTTP/1.0\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
    let sent: Int = request.withCString { cs in
        send(fd, cs, strlen(cs), 0)
    }
    guard sent > 0 else { return (true, false) }

    var buf = [UInt8](repeating: 0, count: 256)
    let n = recv(fd, &buf, buf.count - 1, 0)
    guard n > 0 else { return (true, false) }

    let head = String(decoding: buf[0..<n], as: UTF8.self)
    return (true, head.hasPrefix("HTTP/") && head.contains(" 200"))
}

// MARK: - State

enum State {
    case away          // no tablet on USB
    case wedged        // tablet present, web interface not serving
    case ready         // tablet present, nothing to do
    case syncing       // rmsync.py running
    case done          // last sync succeeded
    case failed        // last sync exited non-zero

    var color: NSColor {
        switch self {
        case .away:    return .tertiaryLabelColor
        case .wedged:  return .systemOrange
        case .ready:   return .labelColor
        case .syncing: return .systemBlue
        case .done:    return .systemGreen
        case .failed:  return .systemRed
        }
    }

    var detail: String {
        switch self {
        case .away:    return "Tablet not connected"
        case .wedged:  return "USB file access wedged - toggle it on the tablet"
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
    private var tabletPresent = false
    private var syncedThisConnection = false

    // --no-auto starts with auto-sync off: useful when a sync is already
    // running by other means, or to observe state without triggering work.
    private var autoSync = !CommandLine.arguments.contains("--no-auto")
    private let verbose = CommandLine.arguments.contains("--verbose")
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
            let r = probe(self.host, 80, timeout: 4.0)
            DispatchQueue.main.async { self.observed(r.serving, present: r.present) }
        }
    }

    private func log(_ msg: String) {
        let t = Self.clock.string(from: Date())
        FileHandle.standardOutput.write("[\(t)] \(msg)\n".data(using: .utf8)!)
    }

    private func observed(_ up: Bool, present: Bool) {
        if up { hits += 1; misses = 0 } else { misses += 1; hits = 0 }
        tabletPresent = present
        if verbose {
            log("poll up=\(up) hits=\(hits) misses=\(misses) "
                + "connected=\(connected) synced=\(syncedThisConnection) "
                + "running=\(running != nil) state=\(state)")
        }

        // Debounce: 2 good polls to connect, 3 bad ones to disconnect. The
        // asymmetry is deliberate -- a mid-render blip must not look like an
        // unplug and re-trigger a whole sync.
        if !connected && hits >= 2 {
            connected = true
            syncedThisConnection = false
            log("tablet connected")
        } else if connected && misses >= 3 {
            connected = false
            log("tablet gone")
        }

        if running != nil { return }   // never disturb a sync in flight

        if connected && autoSync && !syncedThisConnection {
            syncedThisConnection = true
            startSync()
            return
        }
        if !connected {
            // Distinguish an absent tablet from one whose interface has
            // wedged: the second is fixable, and saying so is the whole point.
            state = tabletPresent ? .wedged : .away
        } else if state == .away || state == .wedged {
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
                let code = proc.terminationStatus

                // Exit 3 means another rmsync holds the lock -- a terminal run,
                // or a sync this app started before being restarted. That is
                // the lock working, not a failure, and must not show as red.
                if code == 3 {
                    self.lastSummary = "another sync already running"
                    self.state = .syncing
                    self.log("sync deferred: lock held elsewhere; retrying in 30s")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                        self.syncedThisConnection = false   // try again once free
                    }
                    return
                }

                let ok = code == 0
                self.lastSummary = (ok ? "OK" : "exit \(code)")
                    + " at " + Self.clock.string(from: Date())
                self.state = ok ? .done : .failed
                self.log("sync finished: \(self.lastSummary)")
            }
        }

        do {
            try p.run()
            running = p
            state = .syncing
            log("sync started: \(scriptURL.path)")
        } catch {
            lastSummary = "could not start: \(error.localizedDescription)"
            state = .failed
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
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
