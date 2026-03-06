import Cocoa

// MARK: - Root Server (runs as root when invoked with --server)

class RootServer {
    let socketPath = "/var/run/claude-root-helper.sock"
    let pidPath = "/var/run/claude-root-helper.pid"
    let logPath = "/var/log/claude-root-helper.log"
    let clientInstallPath = "/usr/local/bin/claude-root-cmd"
    let allowedGID: gid_t = 20  // staff group
    let orphanCheckInterval: TimeInterval = 3

    var appPidPath: String
    var allowedUID: uid_t?
    var startTime = Date()
    var cmdCount = 0
    var logHandle: FileHandle?

    init(home: String?) {
        if let home = home {
            appPidPath = "\(home)/.claude-root-helper.pid"
        } else {
            appPidPath = "/tmp/claude-root-helper-app.pid"
        }
    }

    func log(_ message: String, level: String = "INFO") {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss,SSS"
        let line = "\(df.string(from: Date())) [\(level)] \(message)\n"
        if let data = line.data(using: .utf8) {
            logHandle?.write(data)
        }
    }

    func installClient() {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let candidates = [
            (exe as NSString).deletingLastPathComponent + "/../Resources/claude-root-cmd",
            (exe as NSString).deletingLastPathComponent + "/claude-root-cmd",
            (Bundle.main.bundlePath as NSString).deletingLastPathComponent + "/claude-root-cmd"
        ]
        for src in candidates {
            if FileManager.default.fileExists(atPath: src) {
                try? FileManager.default.removeItem(atPath: clientInstallPath)
                try? FileManager.default.copyItem(atPath: src, toPath: clientInstallPath)
                chmod(clientInstallPath, 0o755)
                log("Installed client to \(clientInstallPath)")
                return
            }
        }
    }

    func getPeerUID(_ fd: Int32) -> uid_t? {
        // struct xucred { u_int cr_version; uid_t cr_uid; short cr_ngroups; gid_t cr_groups[16]; }
        let xucredSize = 4 + 4 + 2 + 2 + (16 * 4)  // 76 bytes
        var buf = [UInt8](repeating: 0, count: xucredSize)
        var len = socklen_t(xucredSize)
        let ret = getsockopt(fd, 0 /* SOL_LOCAL */, 0x001 /* LOCAL_PEERCRED */, &buf, &len)
        guard ret == 0 else { return nil }
        return buf.withUnsafeBufferPointer { ptr -> uid_t in
            ptr.baseAddress!.advanced(by: 4).withMemoryRebound(to: uid_t.self, capacity: 1) { $0.pointee }
        }
    }

    func sendResponse(_ fd: Int32, exitCode: Int, stdout: String, stderr: String) {
        let response: [String: Any] = ["exit_code": exitCode, "stdout": stdout, "stderr": stderr]
        if let data = try? JSONSerialization.data(withJSONObject: response),
           var str = String(data: data, encoding: .utf8) {
            str += "\n"
            _ = str.withCString { send(fd, $0, strlen($0), 0) }
        }
    }

    func handleClient(_ clientFd: Int32) {
        defer { close(clientFd) }

        // Check peer UID
        if let peerUID = getPeerUID(clientFd), let allowed = allowedUID {
            if peerUID != allowed && peerUID != 0 {
                log("Rejected connection from UID \(peerUID) (allowed: \(allowed))", level: "WARNING")
                return
            }
        }

        // Read request
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(clientFd, &buf, buf.count, 0)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if data.contains(UInt8(ascii: "\n")) { break }
        }

        guard let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let json = try? JSONSerialization.jsonObject(with: Data(str.utf8)) as? [String: Any],
              let cmd = json["command"] as? String else {
            return
        }

        let timeout = json["timeout"] as? Int ?? 120
        let cwd = json["cwd"] as? String ?? "/"

        if cmd == "__ping__" {
            sendResponse(clientFd, exitCode: 0, stdout: "pong\n", stderr: "")
            return
        }

        if cmd == "__quit__" {
            sendResponse(clientFd, exitCode: 0, stdout: "Shutting down\n", stderr: "")
            log("Quit command received, shutting down")
            cleanup()
            exit(0)
        }

        if cmd == "__status__" {
            let uptime = Int(Date().timeIntervalSince(startTime))
            let info = "{\"uptime\":\(uptime),\"commands\":\(cmdCount),\"pid\":\(getpid())}"
            sendResponse(clientFd, exitCode: 0, stdout: info + "\n", stderr: "")
            return
        }

        cmdCount += 1
        log("CMD: \(cmd) (cwd=\(cwd), timeout=\(timeout))")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", cmd]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()

            // Read stdout/stderr concurrently to avoid pipe buffer deadlock
            var stdoutStr = ""
            var stderrStr = ""
            let group = DispatchGroup()

            group.enter()
            DispatchQueue.global().async {
                let d = outPipe.fileHandleForReading.readDataToEndOfFile()
                stdoutStr = String(data: d, encoding: .utf8) ?? ""
                group.leave()
            }

            group.enter()
            DispatchQueue.global().async {
                let d = errPipe.fileHandleForReading.readDataToEndOfFile()
                stderrStr = String(data: d, encoding: .utf8) ?? ""
                group.leave()
            }

            // Timeout
            var timedOut = false
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + .seconds(timeout))
            timer.setEventHandler {
                if process.isRunning {
                    timedOut = true
                    process.terminate()
                }
            }
            timer.resume()

            process.waitUntilExit()
            timer.cancel()
            group.wait()

            if timedOut {
                log("EXIT: timeout")
                sendResponse(clientFd, exitCode: 124, stdout: stdoutStr, stderr: "Command timed out after \(timeout)s\n")
            } else {
                log("EXIT: \(process.terminationStatus)")
                sendResponse(clientFd, exitCode: Int(process.terminationStatus), stdout: stdoutStr, stderr: stderrStr)
            }
        } catch {
            log("Error running command: \(error.localizedDescription)", level: "ERROR")
            sendResponse(clientFd, exitCode: 1, stdout: "", stderr: error.localizedDescription)
        }
    }

    func cleanup() {
        for path in [socketPath, pidPath] {
            unlink(path)
        }
    }

    func appPidAlive(_ pid: pid_t) -> Bool {
        let ret = kill(pid, 0)
        if ret == 0 { return true }
        return errno == EPERM
    }

    func startWatchdog() {
        DispatchQueue.global().async { [weak self] in
            while true {
                Thread.sleep(forTimeInterval: self?.orphanCheckInterval ?? 3)
                guard let self = self else { return }

                guard FileManager.default.fileExists(atPath: self.appPidPath) else {
                    self.log("App PID file gone, shutting down")
                    self.cleanup()
                    exit(0)
                }

                guard let pidStr = try? String(contentsOfFile: self.appPidPath, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      let pid = pid_t(pidStr) else {
                    continue
                }

                if !self.appPidAlive(pid) {
                    self.log("App (PID \(pid)) is no longer running, shutting down")
                    self.cleanup()
                    exit(0)
                }
            }
        }
    }

    func run() -> Never {
        // Set up logging
        FileManager.default.createFile(atPath: logPath, contents: nil)
        logHandle = FileHandle(forWritingAtPath: logPath)
        logHandle?.seekToEndOfFile()

        installClient()

        // Determine allowed UID from PID file owner
        if let attrs = try? FileManager.default.attributesOfItem(atPath: appPidPath),
           let uid = attrs[.ownerAccountID] as? NSNumber {
            allowedUID = uid.uint32Value
            log("Restricting access to UID \(allowedUID!)")
        } else {
            log("App PID file not found, allowing any staff-group user", level: "WARNING")
        }

        // Clean up old socket
        unlink(socketPath)

        // Write PID file
        try? "\(getpid())".write(toFile: pidPath, atomically: true, encoding: .utf8)

        // Create and bind socket
        let serverFd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            log("Failed to create socket", level: "ERROR")
            exit(1)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            socketPath.withCString { strcpy(ptr, $0) }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            log("Failed to bind socket: \(String(cString: strerror(errno)))", level: "ERROR")
            exit(1)
        }

        chmod(socketPath, 0o660)
        chown(socketPath, 0, allowedGID)
        listen(serverFd, 5)

        startWatchdog()

        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        termSource.setEventHandler { [weak self] in
            self?.log("SIGTERM received, shutting down")
            self?.cleanup()
            exit(0)
        }
        termSource.resume()

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        intSource.setEventHandler { [weak self] in
            self?.log("SIGINT received, shutting down")
            self?.cleanup()
            exit(0)
        }
        intSource.resume()

        log("Root helper started (PID \(getpid()))")

        while true {
            let clientFd = accept(serverFd, nil, nil)
            if clientFd >= 0 {
                handleClient(clientFd)
            }
        }
    }
}

// MARK: - GUI App

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

        statusDot = NSTextField(labelWithString: "\u{25CF}")
        statusDot.font = .systemFont(ofSize: 16)
        statusDot.textColor = .systemGray
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(statusDot)

        statusText = NSTextField(labelWithString: "Starting\u{2026}")
        statusText.font = .systemFont(ofSize: 13, weight: .medium)
        statusText.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(statusText)

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

    func startHelper() {
        appendLog("Requesting administrator privileges\u{2026}", color: .systemYellow)

        let exe = Bundle.main.executablePath!
        let escaped = exe.replacingOccurrences(of: "'", with: "'\\''")
        let home = NSHomeDirectory().replacingOccurrences(of: "'", with: "'\\''")

        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [
                "-e",
                "do shell script \"'\(escaped)' --server --home '\(home)' </dev/null >/dev/null 2>&1 &\" with administrator privileges"
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
        try? FileManager.default.removeItem(atPath: appPidPath)
        if helperRunning {
            sendSocketCommand("__quit__")
        }
    }
}

// MARK: - Entry Point

if CommandLine.arguments.contains("--server") {
    // Server mode — running as root
    var home: String?
    if let idx = CommandLine.arguments.firstIndex(of: "--home"),
       idx + 1 < CommandLine.arguments.count {
        home = CommandLine.arguments[idx + 1]
    }
    let server = RootServer(home: home)
    server.run()
} else {
    // GUI mode
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
