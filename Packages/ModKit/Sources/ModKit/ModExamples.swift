import Foundation

public struct ModExample: Sendable {
    public var id: String
    public var directory: URL
    public var package: ModPackage
}

public enum ModExamples {
    public static var directory: URL? {
        Bundle.module.url(forResource: "Examples", withExtension: nil, subdirectory: "Resources")
    }

    public static var ids: [String] {
        guard let dir = directory,
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.map(\.lastPathComponent).sorted()
    }

    public static func example(_ id: String) -> ModExample? {
        guard let dir = directory?.appendingPathComponent(id, isDirectory: true), FileManager.default.fileExists(atPath: dir.path) else { return nil }
        return ModExample(id: id, directory: dir, package: ModPackage.load(directory: dir))
    }

    public static var all: [ModExample] { ids.compactMap(example) }

    public static var indexListingExample: Data? {
        directory.flatMap { try? Data(contentsOf: $0.appendingPathComponent("index-listing.example.json")) }
    }
}
