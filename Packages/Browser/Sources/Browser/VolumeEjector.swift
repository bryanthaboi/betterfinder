import AppKit
import Darwin
import DiskArbitration

struct BusyProcess: Hashable, Sendable {
    let pid: pid_t
    let name: String
}

enum BusyProcessFinder {
    static func processes(using volumePath: String) -> [BusyProcess] {
        let root = volumePath.hasSuffix("/") ? volumePath : volumePath + "/"
        let me = getpid()
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let got = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }
        var found: [pid_t] = []
        for pid in pids.prefix(Int(got)) where pid > 0 && pid != me {
            if uses(pid: pid, root: root) { found.append(pid) }
        }
        return found.map { BusyProcess(pid: $0, name: name(of: $0)) }
    }

    private static func pathString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
    }

    private static func uses(pid: pid_t, root: String) -> Bool {
        var vpi = proc_vnodepathinfo()
        let vsize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, vsize) == vsize {
            let cwd = pathString(vpi.pvi_cdir.vip_path)
            if (cwd + "/").hasPrefix(root) { return true }
        }
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 8)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return false }
        let wsize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            if proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, wsize) == wsize {
                if pathString(info.pvip.vip_path).hasPrefix(root) { return true }
            }
        }
        return false
    }

    static func name(of pid: pid_t) -> String {
        if let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName { return n }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_name(pid, &buf, UInt32(buf.count)) > 0 { return String(cString: buf) }
        return "process \(pid)"
    }
}

@MainActor
enum VolumeEjector {
    static func eject(_ url: URL, window: NSWindow?) {
        NotificationCenter.default.post(name: .browserVolumeWillEject, object: url)
        let name = (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? url.lastPathComponent
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            } catch {
                let dissent = DiskArb.unmount(url, force: false)
                if dissent == nil {
                    _ = DiskArb.eject(url)
                    return
                }
                let busy = BusyProcessFinder.processes(using: url.path)
                onMain { presentFailure(url: url, name: name, error: dissent ?? error.localizedDescription, busy: busy, window: window) }
            }
        }
    }

    private static func presentFailure(url: URL, name: String, error: String, busy: [BusyProcess], window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let apps = busy.compactMap { NSRunningApplication(processIdentifier: $0.pid) }.filter { $0.activationPolicy == .regular }
        if busy.isEmpty {
            alert.messageText = "“\(name)” couldn't be ejected."
            alert.informativeText = error
        } else {
            let names = busy.map(\.name)
            let list = names.count <= 3 ? names.map { "“\($0)”" }.joined(separator: ", ") : names.prefix(3).map { "“\($0)”" }.joined(separator: ", ") + " and \(names.count - 3) more"
            alert.messageText = "“\(name)” couldn't be ejected because \(list) \(names.count == 1 ? "is" : "are") using it."
            alert.informativeText = "PIDs: \(busy.map { String($0.pid) }.joined(separator: ", ")). Quit \(names.count == 1 ? "it" : "them") and try again, or force eject (unsaved data may be lost)."
        }
        if !apps.isEmpty { alert.addButton(withTitle: apps.count == 1 ? "Quit \(apps[0].localizedName ?? "App") and Eject" : "Quit Apps and Eject") }
        alert.addButton(withTitle: "Force Eject")
        alert.addButton(withTitle: "Cancel")
        let handle: (NSApplication.ModalResponse) -> Void = { resp in
            let idx = resp.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            let quitIndex = apps.isEmpty ? -1 : 0
            let forceIndex = apps.isEmpty ? 0 : 1
            if idx == quitIndex {
                for a in apps { a.terminate() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { eject(url, window: window) }
            } else if idx == forceIndex {
                DispatchQueue.global(qos: .userInitiated).async {
                    if let e = DiskArb.unmount(url, force: true) {
                        onMain {
                            let a = NSAlert()
                            a.messageText = "“\(name)” couldn't be force ejected."
                            a.informativeText = e
                            a.runModal()
                        }
                    } else {
                        _ = DiskArb.eject(url)
                    }
                }
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }
}

enum DiskArb {
    private final class Box: @unchecked Sendable {
        var message: String?
        let sema = DispatchSemaphore(value: 0)
    }

    private static func disk(for url: URL, session: DASession) -> DADisk? {
        DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL)
    }

    static func unmount(_ url: URL, force: Bool) -> String? {
        guard let session = DASessionCreate(kCFAllocatorDefault), let disk = disk(for: url, session: session) else { return "The disk couldn't be found." }
        let queue = DispatchQueue(label: "betterfinder.diskarb")
        DASessionSetDispatchQueue(session, queue)
        defer { DASessionSetDispatchQueue(session, nil) }
        let box = Box()
        let ctx = Unmanaged.passRetained(box).toOpaque()
        let options = DADiskUnmountOptions(force ? kDADiskUnmountOptionForce : kDADiskUnmountOptionDefault) | DADiskUnmountOptions(kDADiskUnmountOptionWhole)
        let target = DADiskCopyWholeDisk(disk) ?? disk
        DADiskUnmount(target, options, { _, dissenter, context in
            guard let context else { return }
            let box = Unmanaged<Box>.fromOpaque(context).takeRetainedValue()
            if let dissenter {
                let status = DADissenterGetStatus(dissenter)
                let s = DADissenterGetStatusString(dissenter) as String?
                box.message = s ?? DiskArb.describe(status)
            }
            box.sema.signal()
        }, ctx)
        if box.sema.wait(timeout: .now() + 30) == .timedOut { return "Timed out waiting for the disk to unmount." }
        return box.message
    }

    static func eject(_ url: URL) -> String? {
        guard let session = DASessionCreate(kCFAllocatorDefault), let disk = disk(for: url, session: session) else { return nil }
        let whole = DADiskCopyWholeDisk(disk) ?? disk
        let queue = DispatchQueue(label: "betterfinder.diskarb.eject")
        DASessionSetDispatchQueue(session, queue)
        defer { DASessionSetDispatchQueue(session, nil) }
        let box = Box()
        let ctx = Unmanaged.passRetained(box).toOpaque()
        DADiskEject(whole, DADiskEjectOptions(kDADiskEjectOptionDefault), { _, dissenter, context in
            guard let context else { return }
            let box = Unmanaged<Box>.fromOpaque(context).takeRetainedValue()
            if let dissenter { box.message = DADissenterGetStatusString(dissenter) as String? ?? DiskArb.describe(DADissenterGetStatus(dissenter)) }
            box.sema.signal()
        }, ctx)
        _ = box.sema.wait(timeout: .now() + 30)
        return box.message
    }

    static func describe(_ status: DAReturn) -> String {
        switch Int(status) {
        case Int(kDAReturnBusy): return "The disk is in use."
        case Int(kDAReturnNotPermitted), Int(kDAReturnNotPrivileged): return "You don't have permission to eject this disk."
        case Int(kDAReturnNotFound): return "The disk couldn't be found."
        case Int(kDAReturnUnsupported): return "This disk can't be ejected."
        default: return String(format: "The disk couldn't be ejected (error 0x%08x).", status)
        }
    }
}
