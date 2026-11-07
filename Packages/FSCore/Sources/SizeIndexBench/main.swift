import Darwin
import Foundation
import FSCore

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fputs("usage: SizeIndexBench <directory> <database>\n", stderr)
    exit(2)
}
do {
    let start = Date()
    let writer = try SizeIndexWriter(databaseURL: URL(fileURLWithPath: arguments[2]))
    try writer.scan(URL(fileURLWithPath: arguments[1]))
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    print("SECONDS=\(Date().timeIntervalSince(start)) DIRECTORIES=\(writer.directoryCount) PEAK_RSS_BYTES=\(usage.ru_maxrss)")
    exit(0)
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
