import Foundation

public enum SocketError: Error, CustomStringConvertible {
    case connectFailed(String)
    case timeout
    case closed
    case io(String)

    public var description: String {
        switch self {
        case .connectFailed(let m): return "connect failed: \(m)"
        case .timeout: return "timed out"
        case .closed: return "connection closed by camera"
        case .io(let m): return "socket error: \(m)"
        }
    }
}

/// Minimal blocking TCP socket with connect/read timeouts. Used from a dedicated thread.
final class TCPSocket {
    private var fd: Int32 = -1

    init(host: String, port: UInt16, timeout: TimeInterval) throws {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else {
            throw SocketError.connectFailed("cannot resolve \(host)")
        }
        defer { freeaddrinfo(res) }

        fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard fd >= 0 else { throw SocketError.connectFailed(String(cString: strerror(errno))) }

        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var rcvbuf: Int32 = 0x80000
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))

        // Non-blocking connect so we can bound the wait.
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
        if rc != 0 && errno != EINPROGRESS {
            let msg = String(cString: strerror(errno)); close()
            throw SocketError.connectFailed(msg)
        }
        if rc != 0 {
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let n = poll(&pfd, 1, Int32(timeout * 1000))
            if n <= 0 { close(); throw SocketError.connectFailed("no answer from \(host):\(port)") }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            if err != 0 { let msg = String(cString: strerror(err)); close(); throw SocketError.connectFailed(msg) }
        }
        _ = fcntl(fd, F_SETFL, flags)
    }

    deinit { close() }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    /// Unblocks a thread sitting in `read` from another thread.
    func shutdown() {
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
    }

    func write(_ data: [UInt8]) throws {
        var off = 0
        while off < data.count {
            let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + off, data.count - off) }
            if n <= 0 { throw SocketError.io(String(cString: strerror(errno))) }
            off += n
        }
    }

    /// Bounds how long `write` may block when the peer stops reading.
    func setSendTimeout(_ timeout: TimeInterval) {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Waits up to `timeout` for data; returns false on timeout.
    func waitReadable(_ timeout: TimeInterval) throws -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let n = poll(&pfd, 1, Int32(timeout * 1000))
        if n < 0 { throw SocketError.io(String(cString: strerror(errno))) }
        return n > 0
    }

    /// Reads whatever is available (at most `max`), waiting up to `timeout` for the first byte.
    func readSome(max: Int, timeout: TimeInterval) throws -> [UInt8] {
        guard try waitReadable(timeout) else { throw SocketError.timeout }
        var buf = [UInt8](repeating: 0, count: max)
        let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, max) }
        if n == 0 { throw SocketError.closed }
        if n < 0 { throw SocketError.io(String(cString: strerror(errno))) }
        return Array(buf[0..<n])
    }

    /// Reads exactly `count` bytes into `buf` starting at `offset`; each wait for more data is bounded by `timeout`.
    func readExact(into buf: inout [UInt8], offset: Int = 0, count: Int, timeout: TimeInterval) throws {
        var got = 0
        while got < count {
            guard try waitReadable(timeout) else { throw SocketError.timeout }
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + offset + got, count - got) }
            if n == 0 { throw SocketError.closed }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw SocketError.io(String(cString: strerror(errno)))
            }
            got += n
        }
    }
}
