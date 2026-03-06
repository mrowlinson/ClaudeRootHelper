import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusDot: NSTextField!
    var statusText: NSTextField!
    var scrollView: NSScrollView!
    var textView: NSTextView!
    var logTimer: Timer?
    var lastLogOffset: UInt64 = 0
    var helperRunning = false
    let appPidPath = NSHomeDirectory() + "/.claude-root-helper.pid"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        writeAppPid()
        setupMenuBar()
        setupWindow()

        if pingHelper() {
            // Adopt the existing helper — update the app PID it watches
            helperRunning = true
            setStatus(running: true, text: "Connected to existing helper")
            appendLog("Connected to already-running root helper", color: .systemGreen)
            startLogMonitor()
        } else {
            DispatchQueue.main.async { self.startHelper() }
        }
    }

    func writeAppPid() {
        try? "\(ProcessInfo.processInfo.processIdentifier)".write(
            toFile: appPidPath, atomically: true, encoding: .utf8)
    }

    // MARK: - UI Setup

    func setupMenuBar() {
        let menuBar = NSMenu()
        let appMenuItem = NSMenuItem()
        menuBar.addItem(appMenuItem)
        let appMenu = NSMenu(title: "Claude Root Helper")
        appMenu.addItem(withTitle: "Quit Claude Root Helper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = menuBar
    }

    func setupWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Claude Root Helper"
        window.center()
        window.minSize = NSSize(width: 400, height: 250)
        let cv = window.contentView!

        // Status bar
        statusDot = NSTextField(labelWithString: "\u{25CF}")
        statusDot.font = .systemFont(ofSize: 16)
        statusDot.textColor = .systemGray
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(statusDot)

        statusText = NSTextField(labelWithString: "Starting\u{2026}")
        statusText.font = .systemFont(ofSize: 13, weight: .medium)
        statusText.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(statusText)

        // Log view
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.autohidesScrollers = false

        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.backgroundColor = NSColor(white: 0.08, alpha: 1.0)
        textView.textColor = NSColor(white: 0.7, alpha: 1.0)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        scrollView.documentView = textView
        cv.addSubview(scrollView)

        NSLayoutConstraint.activate([
            statusDot.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 14),
            statusDot.topAnchor.constraint(equalTo: cv.topAnchor, constant: 10),
            statusText.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 6),
            statusText.centerYAnchor.constraint(equalTo: statusDot.centerYAnchor),
            statusText.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -14),
            scrollView.topAnchor.constraint(equalTo: statusDot.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 14),
            scrollView.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -14),
            scrollView.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -14),
        ])

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setStatus(running: Bool, text: String) {
        statusDot.textColor = running ? .systemGreen : .systemRed
        statusText.stringValue = text
    }

    func appendLog(_ text: String, color: NSColor = NSColor(white: 0.7, alpha: 1.0)) {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        let line = "[\(df.string(from: Date()))] \(text)\n"
        textView.textStorage?.append(NSAttributedString(
            string: line,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: color
            ]
        ))
        textView.scrollToEndOfDocument(nil)
    }

    // MARK: - Helper Management

    func serverScriptPath() -> String {
        // Check inside .app bundle first, then next to the binary
        if let bundled = Bundle.main.path(forResource: "server", ofType: "py") {
            return bundled
        }
        let alongside = (Bundle.main.executablePath! as NSString)
            .deletingLastPathComponent + "/server.py"
        if FileManager.default.fileExists(atPath: alongside) {
            return alongside
        }
        // Fall back to project directory
        return (Bundle.main.bundlePath as NSString)
            .deletingLastPathComponent + "/server.py"
    }

    func startHelper() {
        appendLog("Requesting administrator privileges\u{2026}", color: .systemYellow)

        let path = serverScriptPath()
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")

        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            let home = NSHomeDirectory().replacingOccurrences(of: "'", with: "'\\''")
            process.arguments = [
                "-e",
                "do shell script \"/usr/bin/python3 '\(escaped)' --home '\(home)' </dev/null >/dev/null 2>&1 &\" with administrator privileges"
            ]
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                DispatchQueue.main.async {
                    self.setStatus(running: false, text: "Failed to start")
                    self.appendLog("Error launching osascript: \(error.localizedDescription)", color: .systemRed)
                }
                return
            }

            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            // Give server a moment to bind the socket
            Thread.sleep(forTimeInterval: 1.5)

            DispatchQueue.main.async {
                if self.pingHelper() {
                    self.helperRunning = true
                    self.setStatus(running: true, text: "Running")
                    self.appendLog("Root helper is running", color: .systemGreen)
                    self.startLogMonitor()
                } else {
                    self.setStatus(running: false, text: "Failed to start")
                    if !errStr.isEmpty {
                        self.appendLog("Error: \(errStr)", color: .systemRed)
                    } else {
                        self.appendLog("Helper did not respond. Check /var/log/claude-root-helper.log", color: .systemRed)
                    }
                }
            }
        }
    }

    func pingHelper() -> Bool {
        let sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { Darwin.close(sock) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            "/var/run/claude-root-helper.sock".withCString { strcpy(ptr, $0) }
        }

        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { return false }

        let msg = "{\"command\":\"__ping__\"}\n"
        _ = msg.withCString { Darwin.send(sock, $0, Int(strlen($0)), 0) }
        Darwin.shutdown(sock, SHUT_WR)

        var buf = [UInt8](repeating: 0, count: 1024)
        let n = Darwin.recv(sock, &buf, buf.count, 0)
        guard n > 0 else { return false }
        return String(bytes: buf[0..<n], encoding: .utf8)?.contains("pong") ?? false
    }

    func sendSocketCommand(_ command: String) {
        let sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return }
        defer { Darwin.close(sock) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            "/var/run/claude-root-helper.sock".withCString { strcpy(ptr, $0) }
        }

        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { return }

        let payload: [String: String] = ["command": command]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }
        let msg = jsonStr + "\n"
        _ = msg.withCString { Darwin.send(sock, $0, Int(strlen($0)), 0) }
    }

    // MARK: - Log Monitoring

    func startLogMonitor() {
        let logPath = "/var/log/claude-root-helper.log"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
           let size = attrs[.size] as? UInt64 {
            lastLogOffset = size
        }
        logTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollLog()
        }
    }

    func pollLog() {
        guard let fh = FileHandle(forReadingAtPath: "/var/log/claude-root-helper.log") else { return }
        defer { fh.closeFile() }
        fh.seek(toFileOffset: lastLogOffset)
        let data = fh.readDataToEndOfFile()
        lastLogOffset = fh.offsetInFile
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }

        DispatchQueue.main.async { [weak self] in
            for line in text.components(separatedBy: "\n") where !line.isEmpty {
                let color: NSColor = line.contains("CMD:") ? .systemCyan :
                                     line.contains("ERROR") ? .systemRed :
                                     NSColor(white: 0.55, alpha: 1.0)
                self?.textView.textStorage?.append(NSAttributedString(
                    string: line + "\n",
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                        .foregroundColor: color
                    ]
                ))
            }
            self?.textView.scrollToEndOfDocument(nil)
        }
    }

    // MARK: - Lifecycle

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        logTimer?.invalidate()
        // Remove app PID file — watchdog will kill the server within seconds
        // Also send quit directly as a fast path
        try? FileManager.default.removeItem(atPath: appPidPath)
        if helperRunning {
            sendSocketCommand("__quit__")
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
