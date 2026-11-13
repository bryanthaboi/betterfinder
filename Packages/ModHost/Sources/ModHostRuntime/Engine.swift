import Darwin
import Foundation
import JavaScriptCore
import ModHostProtocol
import ModKit

public final class ModHostEngine: @unchecked Sendable {
    public typealias Sender = @Sendable (ModHostToApp) -> Void

    private let lock = NSLock()
    private var config: ModHostConfig
    private let send: Sender
    private var vms: [String: ModVM] = [:]
    private var callRoutes: [String: (modId: String, generation: Int)] = [:]
    private var callCounter: UInt64 = 0
    private let watchdog: ModWatchdog
    private var statsTimer: DispatchSourceTimer?
    private let catalogNames: [[String]]
    private let catalogArity: [String: ClosedRange<Int>]
    private var stopped = false
    public let exitOnHang: Bool

    public init(config: ModHostConfig = ModHostConfig(), exitOnHang: Bool, catalog: ModCatalog = .v1, send: @escaping Sender) {
        self.config = config
        self.send = send
        self.exitOnHang = exitOnHang
        self.catalogNames = catalog.functions.map(\.name).sorted().map { [ModTSNames.scriptPath($0), $0] }
        var arity = [String: ClosedRange<Int>]()
        for f in catalog.functions { arity[f.name] = f.params.filter { !$0.optional }.count...f.params.count }
        self.catalogArity = arity
        self.watchdog = ModWatchdog()
        watchdog.onHang = { [weak self] turn, elapsed in self?.reportHang(turn, elapsed: elapsed) }
        watchdog.onTerminate = { [weak self] _ in
            guard let self, self.exitOnHang else { return }
            _exit(75)
        }
    }

    public func start() {
        watchdog.configure(budgetMs: config.callbackBudgetMs, loadBudgetMs: config.loadBudgetMs, graceMs: config.hangGraceMs)
        watchdog.start()
        startStatsTimer()
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        send(.ready(ModHostInfo(pid: getpid(), sandboxed: sandboxed, engine: "JavaScriptCore")))
    }

    public func shutdown() {
        lock.lock()
        stopped = true
        let all = Array(vms.values)
        vms.removeAll()
        callRoutes.removeAll()
        statsTimer?.cancel()
        statsTimer = nil
        lock.unlock()
        watchdog.stop()
        for vm in all { vm.queue.async { vm.teardown(reason: ModCallError("unloaded", "host shut down"), notify: false) } }
    }

    public func handle(data: Data) {
        do {
            handle(try ModHostWire.decode(ModAppToHost.self, from: data))
        } catch {
            return
        }
    }

    public func handle(_ message: ModAppToHost) {
        lock.lock()
        let isStopped = stopped
        lock.unlock()
        if isStopped { return }
        switch message {
        case .configure(let c):
            lock.lock(); config = c; lock.unlock()
            watchdog.configure(budgetMs: c.callbackBudgetMs, loadBudgetMs: c.loadBudgetMs, graceMs: c.hangGraceMs)
            startStatsTimer()
        case .load(let request):
            load(request)
        case .unload(let modId, let generation):
            lock.lock()
            let vm = vms.removeValue(forKey: Self.key(modId, generation))
            lock.unlock()
            if let vm {
                vm.queue.async { vm.teardown(reason: ModCallError("unloaded", "mod unloaded"), notify: true) }
            }
        case .invoke(let request):
            lock.lock()
            let vm = vms[Self.key(request.modId, request.generation)]
            lock.unlock()
            guard let vm else {
                send(.result(invocationId: request.invocationId, outcome: .failure(ModCallError("notLoaded", "mod \(request.modId) generation \(request.generation) is not loaded"))))
                return
            }
            vm.queue.async { vm.enqueue(request) }
        case .cancel(let invocationId):
            lock.lock()
            let all = Array(vms.values)
            lock.unlock()
            for vm in all { vm.queue.async { vm.cancel(invocationId: invocationId, error: .cancelled()) } }
        case .callResult(let callId, let outcome):
            lock.lock()
            let route = callRoutes.removeValue(forKey: callId)
            let vm = route.flatMap { vms[Self.key($0.modId, $0.generation)] }
            lock.unlock()
            guard let vm else { return }
            vm.queue.async { vm.settle(callId: callId, outcome: outcome) }
        case .ping(let n):
            send(.pong(n, stats()))
        case .probe(let paths, let hosts, let spawn):
            DispatchQueue.global().async { [send] in send(.probeResult(ModHostProbe.run(paths: paths, hosts: hosts, spawn: spawn))) }
        case .benchmark(let iterations):
            DispatchQueue.global().async { [send] in
                let ctx = JSContext()!
                let fn = ctx.evaluateScript(ModPrelude.benchmark)!
                let start = DispatchTime.now().uptimeNanoseconds
                _ = fn.call(withArguments: [iterations])
                let elapsed = DispatchTime.now().uptimeNanoseconds - start
                send(.benchmark(iterations: iterations, nanoseconds: elapsed))
            }
        }
    }

    func currentConfig() -> ModHostConfig {
        lock.lock(); defer { lock.unlock() }
        return config
    }

    static func key(_ modId: String, _ generation: Int) -> String { "\(modId)#\(generation)" }

    private func load(_ request: ModLoadRequest) {
        let key = Self.key(request.modId, request.generation)
        lock.lock()
        let previous = vms[key]
        let vm = ModVM(request: request, engine: self, watchdog: watchdog, names: catalogNames)
        vms[key] = vm
        lock.unlock()
        if let previous {
            previous.queue.async { previous.teardown(reason: ModCallError("superseded", "reloaded"), notify: true) }
        }
        vm.queue.async { [send] in
            let error = vm.boot()
            if error != nil {
                self.lock.lock()
                if self.vms[key] === vm { self.vms.removeValue(forKey: key) }
                self.lock.unlock()
            }
            send(.loaded(modId: request.modId, generation: request.generation, error: error))
        }
    }

    func emit(_ message: ModHostToApp) { send(message) }

    func registerCall(modId: String, generation: Int, invocationId: String, name: String, argsText: String) -> String {
        guard let range = catalogArity[name] else { return "!notFound:unknown catalog function '\(name)'" }
        guard argsText.utf8.count <= ModHostWire.maxMessageBytes - 16 * 1024 else { return "!limitExceeded:arguments exceed the control message limit" }
        let args: [JSONValue]
        do {
            guard case .array(let a) = try JSONValue.parse(Data(argsText.utf8)) else { return "!invalidArgument:arguments must be a list" }
            args = a
        } catch {
            return "!invalidArgument:arguments must be plain data"
        }
        guard range.contains(args.count) else { return "!invalidArgument:\(name) takes \(range.lowerBound == range.upperBound ? "\(range.lowerBound)" : "\(range.lowerBound)...\(range.upperBound)") arguments, got \(args.count)" }
        lock.lock()
        callCounter += 1
        let callId = "c\(callCounter)"
        callRoutes[callId] = (modId, generation)
        lock.unlock()
        send(.call(ModCallRequest(callId: callId, invocationId: invocationId, modId: modId, generation: generation, name: name, args: args)))
        return callId
    }

    func dropCalls(_ ids: [String]) {
        lock.lock()
        for id in ids { callRoutes.removeValue(forKey: id) }
        lock.unlock()
    }

    func invocationFinished() {
        let s = stats()
        if s.footprintBytes > UInt64(currentConfig().memoryLimitMiB) * 1024 * 1024 { send(.stats(s)) }
    }

    private func reportHang(_ turn: ModWatchdog.Turn, elapsed: Int) {
        send(.hung(ModHangReport(modId: turn.modId, generation: turn.generation, invocationId: turn.invocationId, handler: turn.handler, elapsedMs: elapsed)))
    }

    private func startStatsTimer() {
        lock.lock()
        statsTimer?.cancel()
        let interval = max(250, config.statsIntervalMs)
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + .milliseconds(interval), repeating: .milliseconds(interval))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.send(.stats(self.stats()))
        }
        statsTimer = t
        lock.unlock()
        t.resume()
    }

    public func stats() -> ModHostStats {
        lock.lock()
        let loaded = vms.count
        let active = vms.values.reduce(0) { $0 + $1.activeCount }
        lock.unlock()
        let mem = ModProcessMemory.current()
        return ModHostStats(residentBytes: mem.resident, footprintBytes: mem.footprint, loadedMods: loaded, activeInvocations: active)
    }
}

public enum ModProcessMemory {
    public static func current() -> (resident: UInt64, footprint: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        return (UInt64(info.resident_size), UInt64(info.phys_footprint))
    }
}

final class ModVM: @unchecked Sendable {
    struct Invocation {
        var request: ModInvokeRequest
        var calls: [String] = []
        var cancelled = false
        var timer: DispatchSourceTimer?
    }

    let modId: String
    let generation: Int
    let request: ModLoadRequest
    let queue: DispatchQueue
    private weak var engine: ModHostEngine?
    private let watchdog: ModWatchdog
    private let names: [[String]]
    private var vm: JSVirtualMachine?
    private var context: JSContext?
    private var api: JSValue?
    private var exports: JSValue?
    private var stack: [Invocation] = []
    private var waiting: [ModInvokeRequest] = []
    private var needsReset = false
    private var broken: ModCallError?
    private var lastException: String?
    private var torn = false
    private let countLock = NSLock()
    private var activeCountValue = 0

    var activeCount: Int { countLock.lock(); defer { countLock.unlock() }; return activeCountValue }

    init(request: ModLoadRequest, engine: ModHostEngine, watchdog: ModWatchdog, names: [[String]]) {
        self.modId = request.modId
        self.generation = request.generation
        self.request = request
        self.engine = engine
        self.watchdog = watchdog
        self.names = names
        self.queue = DispatchQueue(label: "betterfinder.modhost.\(request.modId)")
    }

    private func updateCount() {
        countLock.lock(); activeCountValue = stack.count + waiting.count; countLock.unlock()
    }

    private func turn<T>(_ invocation: Invocation?, load: Bool = false, _ body: () -> T) -> T {
        let key = watchdog.begin(ModWatchdog.Turn(modId: modId, generation: generation, invocationId: invocation?.request.invocationId, handler: invocation?.request.handler, isLoad: load))
        defer { watchdog.end(key) }
        return body()
    }

    func boot() -> ModCallError? {
        lastException = nil
        guard let vm = JSVirtualMachine(), let ctx = JSContext(virtualMachine: vm) else { return ModCallError("loadFailed", "cannot create a JavaScript context") }
        ctx.name = "mod:\(modId)#\(generation)"
        ctx.exceptionHandler = { [weak self] _, value in
            self?.lastException = value?.toString() ?? "exception"
        }
        let nativeCall: @convention(block) (String, String) -> String = { [weak self] name, args in
            guard let self else { return "!cancelled:mod unloaded" }
            return self.nativeCall(name: name, argsText: args)
        }
        let nativeCancelled: @convention(block) () -> Bool = { [weak self] in
            guard let self, let top = self.stack.last else { return true }
            return top.cancelled
        }
        let native = JSValue(newObjectIn: ctx)!
        native.setObject(nativeCall, forKeyedSubscript: "call" as NSString)
        native.setObject(nativeCancelled, forKeyedSubscript: "cancelled" as NSString)
        let result: ModCallError? = turn(nil, load: true) {
            guard let factory = ctx.evaluateScript(ModPrelude.bridge, withSourceURL: URL(string: "betterfinder://host/bridge.js")), lastException == nil,
                  let api = factory.call(withArguments: [native, names]), lastException == nil, api.isObject else {
                return ModCallError("loadFailed", "bridge failed: \(lastException ?? "unknown")")
            }
            ctx.evaluateScript(ModPrelude.harden, withSourceURL: URL(string: "betterfinder://host/harden.js"))
            if let e = lastException { return ModCallError("loadFailed", "hardening failed: \(e)") }
            let wrapper: String
            switch request.kind {
            case .bfscript: wrapper = Self.wrapBFScript(request.source)
            case .module: wrapper = "(function (__bf) {\n\"use strict\";\nreturn (\n\(request.source)\n);\n})"
            }
            guard let loader = ctx.evaluateScript(wrapper, withSourceURL: URL(string: "betterfinder://mod/\(modId)/entry.js")), lastException == nil,
                  let bf = api.objectForKeyedSubscript("bf"),
                  let exports = loader.call(withArguments: [bf]), lastException == nil else {
                return ModCallError("loadFailed", "entry failed to evaluate: \(lastException ?? "unknown")")
            }
            let hasHandler = api.objectForKeyedSubscript("hasHandler")!
            for h in request.handlers {
                guard hasHandler.call(withArguments: [exports, h])?.toBool() == true else {
                    return ModCallError("loadFailed", "entry does not export a function '\(h)'")
                }
            }
            self.api = api
            self.exports = exports
            return nil
        }
        if result != nil { return result }
        self.vm = vm
        self.context = ctx
        needsReset = false
        broken = nil
        return nil
    }

    static func wrapBFScript(_ js: String) -> String {
        var names = [String]()
        var body = [String]()
        for line in js.components(separatedBy: "\n") {
            if line == "\"use strict\";" { continue }
            if line.hasPrefix("export async function ") {
                let rest = line.dropFirst("export async function ".count)
                if let paren = rest.firstIndex(of: "(") { names.append(String(rest[..<paren])) }
                body.append(String(line.dropFirst("export ".count)))
            } else {
                body.append(line)
            }
        }
        let exports = names.map { "\"\($0)\": \($0)" }.joined(separator: ", ")
        return "(function (__bf) {\n\"use strict\";\n\(body.joined(separator: "\n"))\nreturn Object.freeze({ \(exports) });\n})"
    }

    private func nativeCall(name: String, argsText: String) -> String {
        guard let index = stack.indices.last else { return "!cancelled:no active invocation" }
        if stack[index].cancelled { return "!cancelled:invocation was cancelled" }
        guard let engine else { return "!cancelled:host stopped" }
        let id = engine.registerCall(modId: modId, generation: generation, invocationId: stack[index].request.invocationId, name: name, argsText: argsText)
        if !id.hasPrefix("!") { stack[index].calls.append(id) }
        return id
    }

    func enqueue(_ request: ModInvokeRequest) {
        if torn {
            engine?.emit(.result(invocationId: request.invocationId, outcome: .failure(ModCallError("notLoaded", "mod unloaded"))))
            return
        }
        if let parent = request.parentInvocationId, stack.contains(where: { $0.request.invocationId == parent }) {
            start(request)
        } else if stack.isEmpty {
            start(request)
        } else {
            waiting.append(request)
            updateCount()
        }
    }

    private func start(_ request: ModInvokeRequest) {
        if let broken {
            engine?.emit(.result(invocationId: request.invocationId, outcome: .failure(broken)))
            drain()
            return
        }
        guard let api, let exports, let context else {
            engine?.emit(.result(invocationId: request.invocationId, outcome: .failure(ModCallError("notLoaded", "mod is not loaded"))))
            drain()
            return
        }
        var inv = Invocation(request: request)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(max(1, request.deadlineMs)))
        let invocationId = request.invocationId
        timer.setEventHandler { [weak self] in self?.cancel(invocationId: invocationId, error: .timeout("handler exceeded its \(request.deadlineMs) ms deadline")) }
        inv.timer = timer
        stack.append(inv)
        updateCount()
        timer.resume()
        let ok: @convention(block) (String) -> Void = { [weak self] text in self?.finish(invocationId, outcome: Self.parseOutcome(text)) }
        let bad: @convention(block) (String, String) -> Void = { [weak self] code, message in
            self?.finish(invocationId, outcome: .failure(ModCallError(code, String(message.prefix(2048)))))
        }
        let limit = engine?.currentConfig().maxLoopIterations ?? ModCatalogLimits.v1.maxLoopIterations
        lastException = nil
        turn(inv) {
            if stack.count == 1 { _ = api.objectForKeyedSubscript("resetBudget").call(withArguments: [limit]) }
            let fn = exports.objectForKeyedSubscript(request.handler)
            _ = api.objectForKeyedSubscript("run").call(withArguments: [
                fn as Any, request.context.canonicalString(), request.input.canonicalString(),
                JSValue(object: ok, in: context) as Any, JSValue(object: bad, in: context) as Any,
            ])
        }
        if let e = lastException {
            finish(invocationId, outcome: .failure(ModCallError("scriptError", e)))
        }
    }

    static func parseOutcome(_ text: String) -> ModCallOutcome {
        guard text.utf8.count <= ModHostWire.maxMessageBytes - 16 * 1024 else { return .failure(.limit("result exceeds the control message limit")) }
        do { return .value(try JSONValue.parse(Data(text.utf8))) } catch { return .failure(ModCallError("invalidResult", "result is not valid data")) }
    }

    private func finish(_ invocationId: String, outcome: ModCallOutcome) {
        guard let i = stack.firstIndex(where: { $0.request.invocationId == invocationId }) else { return }
        let inv = stack.remove(at: i)
        inv.timer?.cancel()
        engine?.dropCalls(inv.calls)
        updateCount()
        engine?.emit(.result(invocationId: invocationId, outcome: outcome))
        engine?.invocationFinished()
        drain()
    }

    func cancel(invocationId: String, error: ModCallError) {
        if let i = waiting.firstIndex(where: { $0.invocationId == invocationId }) {
            let r = waiting.remove(at: i)
            updateCount()
            engine?.emit(.result(invocationId: r.invocationId, outcome: .failure(error)))
            return
        }
        guard let i = stack.firstIndex(where: { $0.request.invocationId == invocationId }) else { return }
        stack[i].cancelled = true
        let calls = stack[i].calls
        if let api {
            turn(stack[i]) {
                for c in calls { _ = api.objectForKeyedSubscript("settle").call(withArguments: [c, false, error.message, error.code]) }
            }
        }
        if stack.contains(where: { $0.request.invocationId == invocationId }) {
            needsReset = true
            finish(invocationId, outcome: .failure(error))
        }
    }

    func settle(callId: String, outcome: ModCallOutcome) {
        guard let api, let i = stack.firstIndex(where: { $0.calls.contains(callId) }) else { return }
        stack[i].calls.removeAll { $0 == callId }
        let inv = stack[i]
        if inv.cancelled { return }
        lastException = nil
        turn(inv) {
            switch outcome {
            case .value(let v):
                _ = api.objectForKeyedSubscript("settle").call(withArguments: [callId, true, v.canonicalString(), ""])
            case .failure(let e):
                _ = api.objectForKeyedSubscript("settle").call(withArguments: [callId, false, e.message, e.code])
            }
        }
    }

    private func drain() {
        if stack.isEmpty, needsReset {
            context = nil; api = nil; exports = nil; vm = nil
            if let error = boot() { broken = error }
        }
        while stack.isEmpty, !waiting.isEmpty {
            let next = waiting.removeFirst()
            updateCount()
            start(next)
        }
    }

    func teardown(reason: ModCallError, notify: Bool) {
        torn = true
        let pending = waiting
        waiting.removeAll()
        let active = stack
        stack.removeAll()
        updateCount()
        for inv in active {
            inv.timer?.cancel()
            engine?.dropCalls(inv.calls)
            if notify { engine?.emit(.result(invocationId: inv.request.invocationId, outcome: .failure(reason))) }
        }
        if notify { for r in pending { engine?.emit(.result(invocationId: r.invocationId, outcome: .failure(reason))) } }
        context = nil; api = nil; exports = nil; vm = nil
    }
}

final class ModWatchdog: @unchecked Sendable {
    struct Turn: Sendable {
        var modId: String
        var generation: Int
        var invocationId: String?
        var handler: String?
        var isLoad: Bool
    }

    private struct Active {
        var turn: Turn
        var start: UInt64
        var reported = false
    }

    private let lock = NSLock()
    private var active: [UInt64: Active] = [:]
    private var nextKey: UInt64 = 0
    private var budgetNs: UInt64 = 250_000_000
    private var loadBudgetNs: UInt64 = 3_000_000_000
    private var graceNs: UInt64 = 750_000_000
    private var thread: Thread?
    private var running = false
    var onHang: (@Sendable (Turn, Int) -> Void)?
    var onTerminate: (@Sendable (Turn) -> Void)?

    func configure(budgetMs: Int, loadBudgetMs: Int, graceMs: Int) {
        lock.lock()
        budgetNs = UInt64(max(1, budgetMs)) * 1_000_000
        loadBudgetNs = UInt64(max(1, loadBudgetMs)) * 1_000_000
        graceNs = UInt64(max(0, graceMs)) * 1_000_000
        lock.unlock()
    }

    func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        let t = Thread { [weak self] in
            while true {
                guard let self else { return }
                if !self.tick() { return }
                usleep(10_000)
            }
        }
        t.name = "betterfinder.modhost.watchdog"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
    }

    func begin(_ turn: Turn) -> UInt64 {
        lock.lock()
        nextKey += 1
        let key = nextKey
        active[key] = Active(turn: turn, start: DispatchTime.now().uptimeNanoseconds)
        lock.unlock()
        return key
    }

    func start(of key: UInt64) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return active[key]?.start
    }

    func end(_ key: UInt64) {
        lock.lock(); active.removeValue(forKey: key); lock.unlock()
    }

    @discardableResult
    func tick(at clock: UInt64? = nil) -> Bool {
        var hangs: [(Turn, Int)] = []
        var kill: Turn?
        lock.lock()
        guard running else { lock.unlock(); return false }
        let now = clock ?? DispatchTime.now().uptimeNanoseconds
        for (key, a) in active {
            let budget = a.turn.isLoad ? loadBudgetNs : budgetNs
            let elapsed = now > a.start ? now - a.start : 0
            if elapsed > budget, !a.reported {
                active[key]?.reported = true
                hangs.append((a.turn, Int(elapsed / 1_000_000)))
            }
            if elapsed > budget + graceNs { kill = a.turn }
        }
        lock.unlock()
        for (t, ms) in hangs { onHang?(t, ms) }
        if let kill { onTerminate?(kill) }
        return true
    }
}

public enum ModTSNames {
    public static let reserved: Set<String> = [
        "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "enum", "export", "extends",
        "false", "finally", "for", "function", "if", "import", "in", "instanceof", "new", "null", "return", "super", "switch", "this",
        "throw", "true", "try", "typeof", "var", "void", "while", "with", "yield", "let", "static", "implements", "interface", "package",
        "private", "protected", "public", "await",
    ]

    public static func scriptName(_ member: String) -> String {
        if member == "delete" { return "remove" }
        return reserved.contains(member) ? member + "_" : member
    }

    public static func scriptPath(_ catalogName: String) -> String {
        var parts = catalogName.split(separator: ".").map(String.init)
        if let last = parts.popLast() { parts.append(scriptName(last)) }
        return parts.joined(separator: ".")
    }
}

enum ModHostProbe {
    static func run(paths: [String], hosts: [String], spawn: String?) -> [String: String] {
        var out = [String: String]()
        for p in paths {
            let fd = open(p, O_RDONLY)
            if fd >= 0 { close(fd); out["read:\(p)"] = "allowed" } else { out["read:\(p)"] = "denied(\(String(cString: strerror(errno))))" }
            let w = open(p + ".bf-probe", O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if w >= 0 { close(w); unlink(p + ".bf-probe"); out["write:\(p)"] = "allowed" } else { out["write:\(p)"] = "denied(\(String(cString: strerror(errno))))" }
        }
        for h in hosts {
            let parts = h.split(separator: ":")
            guard parts.count == 2, let port = UInt16(parts[1]) else { continue }
            let s = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            inet_pton(AF_INET, String(parts[0]), &addr.sin_addr)
            var tv = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            out["connect:\(h)"] = r == 0 ? "allowed" : "denied(\(String(cString: strerror(errno))))"
            close(s)
        }
        if let spawn {
            var pid: pid_t = 0
            let argv: [UnsafeMutablePointer<CChar>?] = [strdup(spawn), nil]
            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
            let r = posix_spawn(&pid, spawn, &actions, nil, argv, nil)
            posix_spawn_file_actions_destroy(&actions)
            argv.forEach { free($0) }
            if r == 0 { var st: Int32 = 0; waitpid(pid, &st, 0); out["spawn:\(spawn)"] = "allowed" } else { out["spawn:\(spawn)"] = "denied(\(String(cString: strerror(r))))" }
        }
        out["sandboxed"] = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil ? "yes" : "no"
        return out
    }
}
