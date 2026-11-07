import Foundation
import JavaScriptCore
import CryptoKit

public enum ScriptLanguage: String, Codable { case ts, js }

public struct TSDiagnostic: Codable, Equatable {
    public enum Category: String, Codable { case error, warning, suggestion, message }
    public let code: Int
    public let file: String?
    public let line: Int?
    public let col: Int?
    public let message: String
    public let category: Category

    public init(code: Int, file: String? = nil, line: Int? = nil, col: Int? = nil, message: String, category: Category = .error) {
        self.code = code; self.file = file; self.line = line; self.col = col
        self.message = message; self.category = category
    }
}

public struct TSCatalogCall: Codable, Equatable {
    public let name: String
    public let catalogName: String
    public let file: String
    public let line: Int
    public let col: Int
    public let rootID: String?
    public let rootLine: Int?
    public let rootCol: Int?
    public let dynamicRoot: Bool

    public init(name: String, catalogName: String? = nil, file: String, line: Int, col: Int, rootID: String? = nil, rootLine: Int? = nil, rootCol: Int? = nil, dynamicRoot: Bool = false) {
        self.name = name; self.catalogName = catalogName ?? name; self.file = file; self.line = line; self.col = col
        self.rootID = rootID; self.rootLine = rootLine; self.rootCol = rootCol; self.dynamicRoot = dynamicRoot
    }

    public var site: String { "\(file):\(line):\(col)" }
}

public struct TSCatalogEscape: Codable, Equatable {
    public let file: String
    public let line: Int
    public let col: Int
    public let reason: String

    public init(file: String, line: Int, col: Int, reason: String) {
        self.file = file; self.line = line; self.col = col; self.reason = reason
    }

    public var site: String { "\(file):\(line):\(col)" }
}

public struct TSResult: Codable, Equatable {
    public let diagnostics: [TSDiagnostic]
    public let moduleSource: String?
    public let executionSource: String?
    public let handlerExports: [String: String]
    public let calls: [TSCatalogCall]
    public let escapes: [TSCatalogEscape]
    public var passed: Bool { !diagnostics.contains { $0.category == .error } }

    public init(diagnostics: [TSDiagnostic], moduleSource: String? = nil, executionSource: String? = nil,
                handlerExports: [String: String] = [:], calls: [TSCatalogCall] = [], escapes: [TSCatalogEscape] = []) {
        self.diagnostics = diagnostics; self.moduleSource = moduleSource; self.executionSource = executionSource
        self.handlerExports = handlerExports; self.calls = calls; self.escapes = escapes
    }

    enum CodingKeys: String, CodingKey { case diagnostics, moduleSource, executionSource, handlerExports, calls, escapes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        diagnostics = try c.decode([TSDiagnostic].self, forKey: .diagnostics)
        moduleSource = try c.decodeIfPresent(String.self, forKey: .moduleSource)
        executionSource = try c.decodeIfPresent(String.self, forKey: .executionSource)
        handlerExports = try c.decodeIfPresent([String: String].self, forKey: .handlerExports) ?? [:]
        calls = try c.decodeIfPresent([TSCatalogCall].self, forKey: .calls) ?? []
        escapes = try c.decodeIfPresent([TSCatalogEscape].self, forKey: .escapes) ?? []
    }

    public var catalogCallNames: [String] { Array(Set(calls.map(\.catalogName))).sorted() }
    public var literalRootIDs: [String] { Array(Set(calls.compactMap(\.rootID))).sorted() }
    public var hasDynamicRoot: Bool { calls.contains(where: \.dynamicRoot) }

    public var callSites: [String: String] {
        var out = [String: String]()
        for call in calls where out[call.catalogName] == nil { out[call.catalogName] = call.site }
        return out
    }

    public var rootSites: [String: String] {
        var out = [String: String]()
        for call in calls {
            guard let id = call.rootID, let line = call.rootLine, let col = call.rootCol, out[id] == nil else { continue }
            out[id] = "\(call.file):\(line):\(col)"
        }
        return out
    }
}

public enum TSToolchainError: Error { case resource(String), javascript(String), invalidResult }

public final class TSToolchain {
    private final class Holder {
        var context: JSContext?
        var library = ""
        var version = ""
        var loadTime: TimeInterval = 0
        var checkTime: TimeInterval = 0
    }

    private let queue = CompilerThread()
    private let holder = Holder()
    public let catalog: Catalog

    public init(catalog: Catalog) { self.catalog = catalog }

    deinit {
        let holder = holder
        try? queue.sync { holder.context = nil }
    }

    public var toolchainVersion: String {
        get throws {
            let holder = holder
            return try queue.sync {
                if !holder.version.isEmpty { return holder.version }
                try Self.load(holder)
                return holder.version
            }
        }
    }

    public var isLoaded: Bool { let holder = holder; return (try? queue.sync { holder.context != nil }) ?? false }

    public func unload() {
        _ = unloadIfIdle { true }
    }

    @discardableResult
    public func unloadIfIdle(_ isIdle: () -> Bool) -> Bool {
        let holder = holder
        return (try? queue.sync { () -> Bool in
            guard holder.context != nil, isIdle() else { return false }
            holder.context = nil
            holder.library = ""
            return true
        }) ?? false
    }

    var definedRequestGlobals: [String] {
        let holder = holder
        return (try? queue.sync { () -> [String] in
            guard let js = holder.context else { return [] }
            return ["__bfRequest", "__bfLib"].filter { js.globalObject.hasProperty($0) }
        }) ?? []
    }
    public var firstLoadTime: TimeInterval { let holder = holder; return try! queue.sync { holder.loadTime } }
    public var lastCheckTime: TimeInterval { let holder = holder; return try! queue.sync { holder.checkTime } }

    public func check(files: [String: String], entry: String, language: ScriptLanguage,
                      handlers: [String: String] = [:]) throws -> TSResult {
        try compile(files: files, entry: entry, language: language, handlers: handlers, emit: false)
    }

    public func transpile(files: [String: String], entry: String, language: ScriptLanguage,
                          handlers: [String: String] = [:]) throws -> TSResult {
        try compile(files: files, entry: entry, language: language, handlers: handlers, emit: true)
    }

    private static func resource(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources") else {
            throw TSToolchainError.resource(name)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func load(_ holder: Holder) throws {
        if holder.context != nil { return }
        let compiler = try resource("typescript.js")
        let helper = try resource("toolchain.js")
        holder.library = try resource("lib.es2020.betterfinder.d.ts")
        guard let js = JSContext() else { throw TSToolchainError.invalidResult }
        let start = ProcessInfo.processInfo.systemUptime
        js.evaluateScript(compiler)
        holder.loadTime = ProcessInfo.processInfo.systemUptime - start
        if let exception = js.exception { throw TSToolchainError.javascript(exception.toString()) }
        js.evaluateScript(helper)
        if let exception = js.exception { throw TSToolchainError.javascript(exception.toString()) }
        let sha = SHA256.hash(data: Data(compiler.utf8)).map { String(format: "%02x", $0) }.joined()
        holder.version = "typescript/\(js.evaluateScript("ts.version")!.toString()!)+sha256:\(sha)"
        holder.context = js
    }

    private func compile(files: [String: String], entry: String, language: ScriptLanguage,
                         handlers: [String: String], emit: Bool) throws -> TSResult {
        let holder = holder
        let catalog = catalog
        return try queue.sync {
            try Self.load(holder)
            struct Request: Encodable {
                let files: [String: String]
                let entry: String
                let language: ScriptLanguage
                let handlers: [String: String]
                let declarations: String
                let hooks: [Catalog.Hook]
                let callNames: [String: String]
            }
            let request = Request(files: files, entry: entry, language: language, handlers: handlers,
                                  declarations: DeclarationGenerator.generate(catalog), hooks: catalog.hooks,
                                  callNames: catalog.callNames)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let json = String(decoding: try encoder.encode(request), as: UTF8.self)
            guard let js = holder.context else { throw TSToolchainError.invalidResult }
            js.exception = nil
            defer {
                js.globalObject.deleteProperty("__bfRequest")
                js.globalObject.deleteProperty("__bfLib")
                js.exception = nil
            }
            js.setObject(holder.library, forKeyedSubscript: "__bfLib" as NSString)
            js.setObject(json, forKeyedSubscript: "__bfRequest" as NSString)
            let start = ProcessInfo.processInfo.systemUptime
            let value = js.evaluateScript("JSON.stringify(bfCompile(JSON.parse(__bfRequest), __bfLib, \(emit ? "true" : "false")))")
            holder.checkTime = ProcessInfo.processInfo.systemUptime - start
            if let exception = js.exception { throw TSToolchainError.javascript(exception.toString()) }
            guard let text = value?.toString(), let data = text.data(using: .utf8) else { throw TSToolchainError.invalidResult }
            return try JSONDecoder().decode(TSResult.self, from: data)
        }
    }
}

private final class CompilerThread {
    private final class State {
        let condition = NSCondition()
        var jobs: [() -> Void] = []
        var stopped = false
    }
    private let state = State()

    init() {
        let state = state
        let thread = Thread {
            while true {
                state.condition.lock()
                while state.jobs.isEmpty && !state.stopped { state.condition.wait() }
                if state.stopped { state.condition.unlock(); return }
                let job = state.jobs.removeFirst()
                state.condition.unlock()
                autoreleasepool { job() }
            }
        }
        thread.name = "betterfinder.typescript"
        thread.start()
    }

    deinit {
        state.condition.lock()
        state.stopped = true
        state.condition.signal()
        state.condition.unlock()
    }

    func sync<T>(_ body: () throws -> T) throws -> T {
        try withoutActuallyEscaping(body) { work in
            let done = DispatchSemaphore(value: 0)
            var result: Result<T, Error>?
            var pending: (() throws -> T)? = work
            state.condition.lock()
            state.jobs.append {
                if let run = pending { result = Result { try run() } }
                pending = nil
                done.signal()
            }
            state.condition.signal()
            state.condition.unlock()
            done.wait()
            return try result!.get()
        }
    }
}
