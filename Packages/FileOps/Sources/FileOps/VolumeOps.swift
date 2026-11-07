import AppKit
import DiskArbitration
import Foundation

public enum VolumeOps {
    public struct BlockingProcess: Sendable, Hashable {
        public let pid: Int32
        public let name: String
        public init(pid: Int32, name: String) {
            self.pid = pid
            self.name = name
        }
    }

    public enum EjectError: Error, LocalizedError {
        case notAVolume(URL)
        case busy(volume: String, processes: [BlockingProcess], message: String?)
        case failed(volume: String, message: String)

        public var canRetryWithForce: Bool {
            if case .busy = self { return true }
            return false
        }

        public var blockingProcesses: [BlockingProcess] {
            if case .busy(_, let p, _) = self { return p }
            return []
        }

        public var errorDescription: String? {
            switch self {
            case .notAVolume(let u):
                return "“\(u.lastPathComponent)” is not a volume."
            case .busy(let volume, let processes, let message):
                if processes.isEmpty { return "“\(volume)” is in use and can’t be ejected." + (message.map { " (\($0))" } ?? "") }
                let names = Array(Set(processes.map(\.name))).sorted().joined(separator: ", ")
                return "“\(volume)” can’t be ejected because it’s being used by: \(names)."
            case .failed(let volume, let message):
                return "“\(volume)” couldn’t be ejected: \(message)"
            }
        }
    }

    private struct DAOutcome {
        var failed = false
        var status: Int32 = 0
        var message: String?
        var busy: Bool { status == Int32(bitPattern: 0xF8DA0005) || message?.lowercased().contains("busy") == true }
    }

    private final class Box {
        let continuation: CheckedContinuation<DAOutcome, Never>
        init(_ c: CheckedContinuation<DAOutcome, Never>) { continuation = c }
    }

    private static func wait(_ body: (UnsafeMutableRawPointer) -> Void) async -> DAOutcome {
        await withCheckedContinuation { (cont: CheckedContinuation<DAOutcome, Never>) in
            let box = Unmanaged.passRetained(Box(cont))
            body(box.toOpaque())
        }
    }

    private static func outcome(_ dissenter: DADissenter?) -> DAOutcome {
        guard let dissenter else { return DAOutcome() }
        var o = DAOutcome()
        o.failed = true
        o.status = DADissenterGetStatus(dissenter)
        o.message = DADissenterGetStatusString(dissenter) as String?
        return o
    }

    public static func eject(_ url: URL, force: Bool = false) async throws {
        let mount = url.standardizedFileURL
        let name = (try? mount.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? mount.lastPathComponent
        guard VolumeInfoProbe.isVolume(mount) else { throw EjectError.notAVolume(mount) }

        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            throw EjectError.failed(volume: name, message: "Disk Arbitration is unavailable.")
        }
        DASessionSetDispatchQueue(session, DispatchQueue.global(qos: .userInitiated))
        defer { DASessionSetDispatchQueue(session, nil) }

        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, mount as CFURL) else {
            try await workspaceEject(mount, volume: name)
            return
        }

        var options = DADiskUnmountOptions(kDADiskUnmountOptionWhole)
        if force { options |= DADiskUnmountOptions(kDADiskUnmountOptionForce) }
        let unmounted = await wait { ctx in
            DADiskUnmount(disk, options, { _, dissenter, ctx in
                let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                box.continuation.resume(returning: VolumeOps.outcome(dissenter))
            }, ctx)
        }
        if unmounted.failed {
            let processes = blockingProcesses(for: mount)
            if unmounted.busy || !processes.isEmpty {
                throw EjectError.busy(volume: name, processes: processes, message: unmounted.message)
            }
            throw EjectError.failed(volume: name, message: unmounted.message ?? "status \(unmounted.status)")
        }

        let whole = DADiskCopyWholeDisk(disk) ?? disk
        let ejected = await wait { ctx in
            DADiskEject(whole, DADiskEjectOptions(kDADiskEjectOptionDefault), { _, dissenter, ctx in
                let box = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                box.continuation.resume(returning: VolumeOps.outcome(dissenter))
            }, ctx)
        }
        if ejected.failed && isEjectable(whole) {
            throw EjectError.failed(volume: name, message: ejected.message ?? "status \(ejected.status)")
        }
    }

    private static func isEjectable(_ disk: DADisk) -> Bool {
        guard let desc = DADiskCopyDescription(disk) as? [String: Any] else { return true }
        return (desc[kDADiskDescriptionMediaEjectableKey as String] as? Bool) ?? true
    }

    private static func unmountViaWorkspace(_ mount: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: mount)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func workspaceEject(_ mount: URL, volume: String) async throws {
        do {
            try await unmountViaWorkspace(mount)
        } catch {
            let processes = blockingProcesses(for: mount)
            if !processes.isEmpty { throw EjectError.busy(volume: volume, processes: processes, message: error.localizedDescription) }
            throw EjectError.failed(volume: volume, message: error.localizedDescription)
        }
    }

    public static func blockingProcesses(for mount: URL, lsofTimeout: TimeInterval = 5) -> [BlockingProcess] {
        let viaProc = processesViaLibproc(mount)
        if !viaProc.isEmpty { return viaProc }
        return processesViaLsof(mount, timeout: lsofTimeout)
    }

    static func processesViaLibproc(_ mount: URL) -> [BlockingProcess] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let bytes = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, mount.path, UInt32(PROC_LISTPIDSPATH_PATH_IS_VOLUME), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        let count = Int(bytes) / MemoryLayout<pid_t>.size
        var seen = Set<pid_t>()
        var result: [BlockingProcess] = []
        for pid in pids.prefix(count) where pid > 0 && seen.insert(pid).inserted {
            var buffer = [CChar](repeating: 0, count: 256)
            let len = proc_name(pid, &buffer, UInt32(buffer.count))
            let name = len > 0 ? String(cString: buffer) : "pid \(pid)"
            result.append(BlockingProcess(pid: pid, name: name))
        }
        return result
    }

    static func processesViaLsof(_ mount: URL, timeout: TimeInterval) -> [BlockingProcess] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["+f", "--", mount.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return parseLsof(String(decoding: data, as: UTF8.self))
    }

    static func parseLsof(_ output: String) -> [BlockingProcess] {
        var seen = Set<Int32>()
        var result: [BlockingProcess] = []
        for (index, line) in output.split(separator: "\n").enumerated() where index > 0 {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = Int32(fields[1]), seen.insert(pid).inserted else { continue }
            let name = String(fields[0]).replacingOccurrences(of: "\\x20", with: " ")
            result.append(BlockingProcess(pid: pid, name: name))
        }
        return result
    }
}

enum VolumeInfoProbe {
    static func isVolume(_ url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true { return true }
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        return volumes.contains { $0.standardizedFileURL.path == url.standardizedFileURL.path }
    }
}
