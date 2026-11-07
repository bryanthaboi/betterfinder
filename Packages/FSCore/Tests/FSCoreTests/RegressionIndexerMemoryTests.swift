import XCTest
import Darwin
@testable import FSCore

final class RegressionIndexerMemoryTests: XCTestCase {
    private func benchExecutable() throws -> URL {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let url = products.appendingPathComponent("SizeIndexBench")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw XCTSkip("SizeIndexBench not built at \(url.path)") }
        return url
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> Int64 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let output = String(decoding: data, as: UTF8.self)
        print("SIZE_INDEX_BENCH \(arguments[0]) \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        let field = output.split(separator: " ").first { $0.hasPrefix("PEAK_RSS_BYTES=") }
        return field.flatMap { Int64($0.dropFirst("PEAK_RSS_BYTES=".count).trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
    }

    func testWideDirectoryRescanMemoryInSeparateProcess() throws {
        guard ProcessInfo.processInfo.environment["BF_BENCH_INDEXER"] == "1" else { throw XCTSkip("set BF_BENCH_INDEXER=1 to run") }
        let executable = try benchExecutable()
        let counts = (ProcessInfo.processInfo.environment["BF_BENCH_FILES"] ?? "20000,100000").split(separator: ",").compactMap { Int($0) }
        let base = ProcessInfo.processInfo.environment["BF_BENCH_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        for count in counts {
            let temp = base.appendingPathComponent("bf-index-bench-\(UUID().uuidString)").resolvingSymlinksInPath()
            let tree = temp.appendingPathComponent("tree")
            try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            for i in 0..<count {
                let fd = open(tree.appendingPathComponent("file-\(i).txt").path, O_CREAT | O_WRONLY, 0o600)
                XCTAssertGreaterThanOrEqual(fd, 0)
                close(fd)
            }
            let database = temp.appendingPathComponent("index.sqlite").path
            let initial = try run(executable, [tree.path, database])
            let rescan = try run(executable, [tree.path, database])
            print("SIZE_INDEX_BENCH_SUMMARY files=\(count) initial=\(initial) rescan=\(rescan)")
            XCTAssertEqual(try SizeIndexReader(databaseURL: URL(fileURLWithPath: database)).size(for: tree)?.items, count)
        }
    }
}
