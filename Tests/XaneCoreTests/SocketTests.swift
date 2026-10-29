#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import XCTest
@testable import XaneCore

final class SocketTests: XCTestCase {
    func roundTrip(_ path: String, _ line: String, readAll: Bool = true) -> [String] {
        #if canImport(Darwin)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in path.utf8.enumerated() { raw[i] = b }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(ok, 0)
        let req = Array((line + "\n").utf8)
        _ = req.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var out = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out += buf[0..<n]
            if !readAll, out.filter({ $0 == 10 }).count >= 2 { break }
        }
        close(fd)
        return String(decoding: out, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    func testRequestResponseAndSubscribe() throws {
        let path = NSTemporaryDirectory() + "xanewm-test-\(getpid()).sock"
        let q = DispatchQueue(label: "handler")
        let server = SocketServer(path: path, handlerQueue: q)
        server.onLine = { line, client in
            if line == "subscribe" {
                client.subscribe(greeting: Wire.ok())
                server.broadcast("{\"event\":\"hello\"}")
            } else if line == "big" {
                client.reply(Wire.ok(data: Wire.encode(String(repeating: "x", count: 300_000))))
            } else {
                client.reply(Wire.ok(data: Wire.encode(line)))
            }
        }
        try server.start()
        defer { server.stop() }

        XCTAssertEqual(roundTrip(path, "focus left"), [#"{"data":"focus left","ok":true}"#])
        // Large responses go out whole even though the socket buffer is small.
        XCTAssertEqual(roundTrip(path, "big").first?.count, 300_000 + 21)
        XCTAssertEqual(roundTrip(path, "subscribe", readAll: false), [#"{"ok":true}"#, #"{"event":"hello"}"#])

        // A second instance refuses to start while the first one is alive.
        XCTAssertThrowsError(try SocketServer(path: path).start())
    }

    func testStaleSocketIsReplaced() throws {
        let path = NSTemporaryDirectory() + "xanewm-stale-\(getpid()).sock"
        FileManager.default.createFile(atPath: path, contents: Data())
        let s = SocketServer(path: path, handlerQueue: DispatchQueue(label: "h"))
        s.onLine = { _, c in c.reply(Wire.ok()) }
        XCTAssertNoThrow(try s.start())
        XCTAssertEqual(roundTrip(path, "x"), [#"{"ok":true}"#])
        s.stop()
    }
}
