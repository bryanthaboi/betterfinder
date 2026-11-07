import Foundation

public final class StdioTransport: @unchecked Sendable {
    private let server: MCPServer
    private let inputFD: Int32
    private let output: FileHandle
    private let writeLock = NSLock()
    private let maxLine = MCPSession.maxMessageBytes

    public init(server: MCPServer, input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        self.server = server
        self.inputFD = input.fileDescriptor
        self.output = output
    }

    func write(_ data: Data) {
        var line = data
        line.append(0x0A)
        writeLock.lock()
        defer { writeLock.unlock() }
        try? output.write(contentsOf: line)
    }

    enum Line {
        case message(Data)
        case oversize
    }

    public func run() async {
        let session = server.makeSession()
        let (stream, continuation) = AsyncStream<Line>.makeStream()
        let fd = inputFD
        let limit = maxLine
        let reader = Thread {
            var buffer = Data()
            var discarding = false
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                for byte in chunk[0..<n] {
                    if byte == 0x0A {
                        if discarding { continuation.yield(.oversize); discarding = false }
                        else if !buffer.isEmpty {
                            var line = buffer
                            if line.last == 0x0D { line.removeLast() }
                            if !line.isEmpty { Self.dispatch(line, session: session, continuation: continuation) }
                        }
                        buffer.removeAll(keepingCapacity: true)
                    } else if !discarding {
                        buffer.append(byte)
                        if buffer.count > limit { discarding = true; buffer.removeAll(keepingCapacity: false) }
                    }
                }
            }
            if !buffer.isEmpty, !discarding { Self.dispatch(buffer, session: session, continuation: continuation) }
            continuation.finish()
        }
        reader.stackSize = 1 << 20
        reader.start()
        for await line in stream {
            switch line {
            case .oversize:
                write(RPC.encode(RPC.error(id: nil, code: RPCCode.invalidRequest, message: "message larger than \(maxLine) bytes")))
            case .message(let data):
                if let reply = await session.handle(data) { write(reply) }
            }
            if session.isClosed { break }
        }
        session.close()
    }

    static func dispatch(_ data: Data, session: MCPSession, continuation: AsyncStream<Line>.Continuation) {
        if let text = String(data: data.prefix(512), encoding: .utf8), text.contains("notifications/cancelled") {
            Task { _ = await session.handle(data) }
            return
        }
        continuation.yield(.message(data))
    }
}
