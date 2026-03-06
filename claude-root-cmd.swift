import Foundation

let socketPath = "/var/run/claude-root-helper.sock"

var args = Array(CommandLine.arguments.dropFirst())
var cwd = FileManager.default.currentDirectoryPath
var timeout = 120

while !args.isEmpty {
    if args[0] == "--cwd" && args.count > 1 {
        cwd = args[1]
        args.removeFirst(2)
    } else if args[0] == "--timeout" && args.count > 1 {
        timeout = Int(args[1]) ?? 120
        args.removeFirst(2)
    } else {
        break
    }
}

guard !args.isEmpty else {
    fputs("Usage: claude-root-cmd [--cwd DIR] [--timeout SECS] <command>\n", stderr)
    exit(1)
}

let cmd = args.joined(separator: " ")

guard FileManager.default.fileExists(atPath: socketPath) else {
    fputs("Error: Root helper not running. Launch ClaudeRootHelper.app first.\n", stderr)
    exit(1)
}

let sock = socket(AF_UNIX, SOCK_STREAM, 0)
guard sock >= 0 else {
    fputs("Error: Failed to create socket.\n", stderr)
    exit(1)
}

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
    socketPath.withCString { strcpy(ptr, $0) }
}

let connectResult = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}

guard connectResult == 0 else {
    let err = errno
    if err == EACCES {
        fputs("Error: Permission denied connecting to root helper socket.\n", stderr)
    } else if err == ECONNREFUSED {
        fputs("Error: Root helper not accepting connections. Relaunch the app.\n", stderr)
    } else {
        fputs("Error: Failed to connect to root helper: \(String(cString: strerror(err)))\n", stderr)
    }
    close(sock)
    exit(1)
}

let request: [String: Any] = ["command": cmd, "cwd": cwd, "timeout": timeout]
guard let jsonData = try? JSONSerialization.data(withJSONObject: request),
      var jsonStr = String(data: jsonData, encoding: .utf8) else {
    fputs("Error: Failed to serialize request.\n", stderr)
    close(sock)
    exit(1)
}
jsonStr += "\n"
_ = jsonStr.withCString { send(sock, $0, strlen($0), 0) }
shutdown(sock, SHUT_WR)

var data = Data()
var buf = [UInt8](repeating: 0, count: 65536)
while true {
    let n = recv(sock, &buf, buf.count, 0)
    if n <= 0 { break }
    data.append(contentsOf: buf[0..<n])
}
close(sock)

guard let responseStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
      let response = try? JSONSerialization.jsonObject(with: Data(responseStr.utf8)) as? [String: Any] else {
    fputs("Error: Invalid response from root helper.\n", stderr)
    exit(1)
}

if let stdout = response["stdout"] as? String, !stdout.isEmpty {
    print(stdout, terminator: "")
}
if let stderr_str = response["stderr"] as? String, !stderr_str.isEmpty {
    fputs(stderr_str, stderr)
}

let exitCode = response["exit_code"] as? Int ?? 1
exit(Int32(exitCode))
