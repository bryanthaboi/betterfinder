import Darwin
import Foundation
import FSCore

let arguments = CommandLine.arguments

if arguments.count == 5, arguments[1] == "--search" {
    let start = Date()
    let lock = NSLock()
    nonisolated(unsafe) var found = 0
    nonisolated(unsafe) var first: Double?
    let searcher = SizeIndexSearcher(databaseURL: URL(fileURLWithPath: arguments[2]))
    let pass = searcher.pass(query: arguments[4], under: URL(fileURLWithPath: arguments[3]), includeHidden: ProcessInfo.processInfo.environment["BF_HIDDEN"] == "1",
                             limit: Int(ProcessInfo.processInfo.environment["BF_LIMIT"] ?? "") ?? 5000, isCancelled: { false }) { paths in
        lock.lock()
        if first == nil { first = Date().timeIntervalSince(start) }
        found += paths.count
        lock.unlock()
    }
    print("SEARCH_SECONDS=\(Date().timeIntervalSince(start)) FIRST_RESULT_SECONDS=\(first ?? -1) RESULTS=\(found) INDEXED=\(pass.found) COUNTING=\(pass.counting) HIT_LIMIT=\(pass.hitLimit)")
    exit(0)
}

guard arguments.count == 3 else {
    fputs("usage: SizeIndexBench <directory> <database>\n       SizeIndexBench --search <database> <scope> <query>\n", stderr)
    exit(2)
}
do {
    let start = Date()
    let cache = ProcessInfo.processInfo.environment["BF_CACHE_KIB"].flatMap { Int($0) } ?? 16384
    let writer = try SizeIndexWriter(databaseURL: URL(fileURLWithPath: arguments[2]), cacheKiB: cache)
    if let width = ProcessInfo.processInfo.environment["BF_SCAN_WIDTH"].flatMap({ Int($0) }) { writer.scanWidth = width }
    try writer.scan(URL(fileURLWithPath: arguments[1]))
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    print("SECONDS=\(Date().timeIntervalSince(start)) DIRECTORIES=\(writer.directoryCount) PEAK_RSS_BYTES=\(usage.ru_maxrss)")
    exit(0)
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
