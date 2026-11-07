import CryptoKit
import Foundation

final class CopyContext: @unchecked Sendable {
    let control: OperationControl
    let tracker: ProgressTracker
    let errors: ErrorCollector
    var topSource: URL
    var ledger: CommitLedger?

    init(control: OperationControl, tracker: ProgressTracker, errors: ErrorCollector, topSource: URL) {
        self.control = control
        self.tracker = tracker
        self.errors = errors
        self.topSource = topSource
    }

    func handle(what: Int32, stage: Int32, state: copyfile_state_t?, src: UnsafePointer<CChar>?, dst: UnsafePointer<CChar>?) -> Int32 {
        if control.isCancelled { return COPYFILE_QUIT }
        switch stage {
        case COPYFILE_ERR:
            let code = errno
            let path = src.map { String(cString: $0) } ?? dst.map { String(cString: $0) } ?? topSource.path
            errors.add(.posix(code, url: URL(fileURLWithPath: path)))
            return COPYFILE_SKIP
        case COPYFILE_PROGRESS:
            if what == COPYFILE_COPY_DATA, let state {
                var copied: off_t = 0
                if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 {
                    tracker.setFileBytes(Int64(copied))
                }
            }
            do { try control.checkpoint() } catch { return COPYFILE_QUIT }
            return COPYFILE_CONTINUE
        case COPYFILE_START:
            if what == COPYFILE_RECURSE_FILE, let src { tracker.setCurrent(URL(fileURLWithPath: String(cString: src)).lastPathComponent) }
            return COPYFILE_CONTINUE
        case COPYFILE_FINISH:
            if what == COPYFILE_RECURSE_FILE, let src {
                var st = stat()
                if lstat(src, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG { tracker.settleFile(Int64(st.st_size)) }
                if let dst { ledger?.record(path: String(cString: dst)) }
            }
            return COPYFILE_CONTINUE
        default:
            return COPYFILE_CONTINUE
        }
    }
}

private let copyfileStatusCallback: copyfile_callback_t = { what, stage, state, src, dst, ctx in
    guard let ctx else { return COPYFILE_CONTINUE }
    let context = Unmanaged<CopyContext>.fromOpaque(ctx).takeUnretainedValue()
    return context.handle(what: what, stage: stage, state: state, src: src, dst: dst)
}

enum CopyEngine {
    nonisolated(unsafe) static var flags: copyfile_flags_t = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_NOFOLLOW_SRC | COPYFILE_EXCL)

    @discardableResult
    static func copy(from src: URL, to dst: URL, context: CopyContext) throws -> Bool {
        try context.control.checkpoint()
        guard let state = copyfile_state_alloc() else { throw POSIXError(.ENOMEM) }
        defer { copyfile_state_free(state) }
        let cb = unsafeBitCast(copyfileStatusCallback, to: UnsafeRawPointer.self)
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), cb)
        let ctxPtr = Unmanaged.passUnretained(context).toOpaque()
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), ctxPtr)
        let result = copyfile(src.path, dst.path, state, flags)
        let code = errno
        if context.control.isCancelled { throw OperationAbort.cancelled }
        let hadNested = context.errors.all.contains { FS.isDescendant($0.url, of: src) }
        if result != 0 && !hadNested { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        return !hadNested
    }
}

enum Verifier {
    static func verify(source: URL, destination: URL, control: OperationControl, tracker: ProgressTracker) throws {
        guard let st = FS.lstatInfo(source.path) else { return }
        let type = st.st_mode & S_IFMT
        if type == S_IFDIR {
            let children = (try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? []
            for name in children {
                try control.checkpoint()
                try verify(source: source.appendingPathComponent(name), destination: destination.appendingPathComponent(name), control: control, tracker: tracker)
            }
        } else if type == S_IFREG {
            tracker.setCurrent("Verifying " + source.lastPathComponent)
            let a = try digest(of: source, control: control, tracker: tracker)
            let b = try digest(of: destination, control: control, tracker: nil)
            if a != b { throw ChecksumMismatch(url: destination) }
        }
    }

    static func digest(of url: URL, control: OperationControl, tracker: ProgressTracker?) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try control.checkpoint()
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            tracker?.addExtra(Int64(chunk.count))
        }
        return hasher.finalize()
    }
}
