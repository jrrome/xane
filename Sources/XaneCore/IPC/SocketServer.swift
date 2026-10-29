#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import Dispatch

/// Line-oriented Unix-domain socket server. All socket I/O happens on a private queue; requests are
/// delivered to `handlerQueue` (the main queue in the compositor), so the command executor never
/// touches a file descriptor and a slow client can never block the compositor.
public final class SocketServer {
    public enum Failure: Error, CustomStringConvertible {
        case alreadyRunning(String), system(String, Int32), pathTooLong
        public var description: String {
            switch self {
            case .alreadyRunning(let p): return "another instance is listening on \(p)"
            case .system(let what, let e): return "\(what): \(String(cString: strerror(e)))"
            case .pathTooLong: return "socket path too long"
            }
        }
    }

    public final class Client {
        fileprivate let fd: Int32
        fileprivate weak var server: SocketServer?
        fileprivate var buffer = [UInt8]()
        fileprivate var source: DispatchSourceRead?
        fileprivate var suspended = false
        fileprivate var closed = false
        fileprivate var subscribed = false
        fileprivate var handled = false

        fileprivate init(fd: Int32, server: SocketServer) { self.fd = fd; self.server = server }

        /// Sends the response and closes the connection.
        public func reply(_ line: String) {
            guard let server else { return }
            server.io.async { [self] in
                _ = writeLine(line)
                close()
            }
        }

        /// Keeps the connection open to receive events.
        public func subscribe(greeting: String? = nil) {
            guard let server else { return }
            server.io.async { [self] in
                guard !closed else { return }
                subscribed = true
                server.subscribers.append(self)
                if let g = greeting, !writeLine(g) { close() }
            }
        }

        /// Writes a whole line, waiting (bounded) for the socket to drain when its buffer is full.
        fileprivate func writeLine(_ line: String) -> Bool {
            guard !closed else { return false }
            let bytes = Array((line + "\n").utf8)
            var off = 0
            // Give up only after 2 s *without progress* (real time, not loop iterations): macOS
            // Unix sockets have an 8 KB buffer, so big replies need many drain cycles.
            func deadline() -> UInt64 { DispatchTime.now().uptimeNanoseconds + 2_000_000_000 }
            var giveUpAt = deadline()
            while off < bytes.count {
                #if canImport(Darwin)
                let n = bytes[off...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                #else
                let n = bytes[off...].withUnsafeBytes { Glibc.send(fd, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
                #endif
                let err = errno
                if n > 0 { off += n; giveUpAt = deadline(); continue }
                if n < 0 && err == EINTR { continue }
                // macOS reports a full Unix-socket buffer as ENOBUFS as well as EAGAIN.
                if n < 0 && (err == EAGAIN || err == EWOULDBLOCK || err == ENOBUFS) {
                    if DispatchTime.now().uptimeNanoseconds > giveUpAt { return false }
                    var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&p, 1, 50)
                    if err == ENOBUFS { usleep(1000) }   // poll may say "writable" while buffers are short
                    continue
                }
                return false
            }
            return true
        }

        fileprivate func stopReading() {
            guard let s = source, !suspended else { return }
            s.suspend()
            suspended = true
        }

        fileprivate func close() {
            guard !closed else { return }
            closed = true
            server?.subscribers.removeAll { $0 === self }
            if let s = source {
                if suspended { s.resume(); suspended = false }
                s.cancel()   // the cancel handler closes the descriptor
                source = nil
            } else {
                closeFD(fd)
            }
        }
    }

    public let path: String
    public var onLine: ((String, Client) -> Void)?
    private let handlerQueue: DispatchQueue
    fileprivate let io = DispatchQueue(label: "xanewm.ipc")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    fileprivate var subscribers: [Client] = []
    private var clients: [ObjectIdentifier: Client] = [:]
    public static let maxLine = 64 * 1024

    public init(path: String, handlerQueue: DispatchQueue = .main) {
        self.path = path
        self.handlerQueue = handlerQueue
    }

    deinit { stop() }

    public func start() throws {
        signal(SIGPIPE, SIG_IGN)
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw Failure.pathTooLong }
        addr.sun_family = sa_family_t(AF_UNIX)
        #if canImport(Darwin)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }

        // A socket file from a crashed run is removed; a live one means we are already running.
        if FileManager.default.fileExists(atPath: path) {
            let probe = socket(AF_UNIX, SocketServer.streamType, 0)
            let alive = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                }
            }
            closeFD(probe)
            if alive { throw Failure.alreadyRunning(path) }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SocketServer.streamType, 0)
        guard fd >= 0 else { throw Failure.system("socket", errno) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { let e = errno; closeFD(fd); throw Failure.system("bind", e) }
        chmod(path, 0o600)
        guard listen(fd, 32) == 0 else { let e = errno; closeFD(fd); throw Failure.system("listen", e) }
        setNonBlocking(fd)
        listenFD = fd

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: io)
        src.setEventHandler { [weak self] in self?.acceptAll() }
        src.setCancelHandler { closeFD(fd) }
        acceptSource = src
        src.resume()
    }

    public func stop() {
        io.sync {
            acceptSource?.cancel()
            acceptSource = nil
            for c in clients.values { c.close() }
            clients.removeAll()
            subscribers.removeAll()
        }
        if listenFD >= 0 { unlink(path); listenFD = -1 }
    }

    /// Sends an event line to every subscriber (dead ones are dropped).
    public func broadcast(_ line: String) {
        io.async { [self] in
            for c in subscribers where !c.writeLine(line) { c.close() }
        }
    }

    public var hasSubscribers: Bool { io.sync { !subscribers.isEmpty } }

    private func acceptAll() {
        while true {
            let cfd = accept(listenFD, nil, nil)
            if cfd < 0 { return }   // EAGAIN: drained
            #if canImport(Darwin)
            var one: Int32 = 1
            setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
            // Non-blocking; writeLine waits at most ~1 s for a full buffer, then drops the client.
            setNonBlocking(cfd)
            let client = Client(fd: cfd, server: self)
            let id = ObjectIdentifier(client)
            clients[id] = client
            let src = DispatchSource.makeReadSource(fileDescriptor: cfd, queue: io)
            src.setEventHandler { [weak self, weak client] in
                guard let self, let client else { return }
                self.read(client)
            }
            src.setCancelHandler { [weak self] in
                closeFD(cfd)
                self?.clients[id] = nil
            }
            client.source = src
            src.resume()
            // Clients that connect and say nothing are dropped.
            io.asyncAfter(deadline: .now() + 5) { [weak client] in
                if let c = client, !c.handled, !c.closed { c.close() }
            }
        }
    }

    private func read(_ c: Client) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            #if canImport(Darwin)
            let n = Darwin.read(c.fd, &chunk, chunk.count)
            #else
            let n = Glibc.read(c.fd, &chunk, chunk.count)
            #endif
            if n > 0 {
                guard !c.handled else { continue }   // one request per connection
                c.buffer += chunk[0..<n]
                if let nl = c.buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    deliver(c, Array(c.buffer[..<nl]))
                } else if c.buffer.count > SocketServer.maxLine {
                    _ = c.writeLine(Wire.error("request too long")); c.close(); return
                }
                continue
            }
            if n == 0 {
                // EOF. Stop reading (a closed peer is readable forever); a pending reply still goes out.
                c.stopReading()
                if !c.handled {
                    if c.buffer.isEmpty { c.close() } else { deliver(c, c.buffer) }
                } else if c.subscribed {
                    c.close()
                }
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            c.close(); return
        }
    }

    private func deliver(_ c: Client, _ bytes: [UInt8]) {
        c.handled = true
        c.buffer.removeAll()
        let line = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        handlerQueue.async { [weak self] in
            guard let self, let onLine = self.onLine else { c.reply(Wire.error("not ready")); return }
            onLine(line, c)
        }
    }

    private func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    #if canImport(Darwin)
    static let streamType = SOCK_STREAM
    #else
    static let streamType = Int32(SOCK_STREAM.rawValue)
    #endif
}

@inline(__always) private func closeFD(_ fd: Int32) {
    #if canImport(Darwin)
    _ = Darwin.close(fd)
    #else
    _ = Glibc.close(fd)
    #endif
}
