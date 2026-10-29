// xanectl — talks to the running compositor over its Unix socket (like swaymsg / riverctl).
//
//   xanectl focus left
//   xanectl "view 2; focus main"
//   xanectl query windows | jq
//   xanectl subscribe
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

func usage() -> Never {
    let text = """
    usage: xanectl [-s socket] [-p] <command> [args…]
           xanectl subscribe          stream events as JSON lines
      -s   socket path (default: $XANEWM_SOCKET or /tmp/xanewm-<uid>.sock)
      -p   pretty-print JSON responses
    examples: xanectl focus left · xanectl layout tile · xanectl query windows
    """
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
var socketPath = ProcessInfo.processInfo.environment["XANEWM_SOCKET"].flatMap { $0.isEmpty ? nil : $0 }
    ?? "/tmp/xanewm-\(getuid()).sock"
var pretty = false
while let a = args.first, a.hasPrefix("-"), a.count > 1, Double(a) == nil {
    args.removeFirst()
    switch a {
    case "-s", "--socket": guard !args.isEmpty else { usage() }; socketPath = args.removeFirst()
    case "-p", "--pretty": pretty = true
    case "-h", "--help": usage()
    default: usage()
    }
}
guard !args.isEmpty else { usage() }

// Re-quote arguments so the server tokenizes exactly what the shell gave us. A single argument
// is passed through untouched so "view 2; focus main" works as one line.
func quote(_ s: String) -> String {
    if !s.isEmpty && !s.contains(where: { $0.isWhitespace || "\"'\\".contains($0) }) { return s }
    return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}
let line = args.count == 1 ? args[0] : args.map(quote).joined(separator: " ")

#if canImport(Darwin)
let streamType = SOCK_STREAM
#else
let streamType = Int32(SOCK_STREAM.rawValue)
#endif
// A compositor that quits mid-request must produce an error, not kill us with SIGPIPE.
signal(SIGPIPE, SIG_IGN)
let fd = socket(AF_UNIX, streamType, 0)
guard fd >= 0 else { perror("socket"); exit(1) }
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
#if canImport(Darwin)
addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
#endif
let pathBytes = Array(socketPath.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
    FileHandle.standardError.write(Data("xanectl: socket path too long\n".utf8)); exit(1)
}
withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    for (i, b) in pathBytes.enumerated() { raw[i] = b }
    raw[pathBytes.count] = 0
}
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else {
    FileHandle.standardError.write(Data("xanectl: cannot connect to \(socketPath) — is XaneWM running?\n".utf8))
    exit(1)
}

let request = Array((line + "\n").utf8)
var sent = 0
while sent < request.count {
    let n = request[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    guard n > 0 else { perror("write"); exit(1) }
    sent += n
}

var buffer = [UInt8]()
var chunk = [UInt8](repeating: 0, count: 65536)
var failed = false

func emit(_ lineBytes: ArraySlice<UInt8>) {
    guard let text = String(bytes: lineBytes, encoding: .utf8), !text.isEmpty else { return }
    let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8))
    if let dict = obj as? [String: Any], let ok = dict["ok"] as? Bool {
        if !ok {
            failed = true
            FileHandle.standardError.write(Data("xanectl: \(dict["error"] as? String ?? "error")\n".utf8))
            return
        }
        guard let data = dict["data"] else { return }
        output(data)
        return
    }
    if let obj { output(obj) } else { print(text) }
    fflush(stdout)
}

func output(_ value: Any) {
    if let s = value as? String { print(s); return }
    var opts: JSONSerialization.WritingOptions = [.sortedKeys]
    if pretty { opts.insert(.prettyPrinted) }
    if JSONSerialization.isValidJSONObject(value), let d = try? JSONSerialization.data(withJSONObject: value, options: opts),
       let s = String(data: d, encoding: .utf8) {
        print(s)
    } else {
        print(value)
    }
}

while true {
    let n = read(fd, &chunk, chunk.count)
    if n <= 0 { break }
    buffer += chunk[0..<n]
    while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
        emit(buffer[..<nl])
        buffer.removeSubrange(...nl)
    }
}
if !buffer.isEmpty { emit(buffer[...]) }
close(fd)
exit(failed ? 1 : 0)
