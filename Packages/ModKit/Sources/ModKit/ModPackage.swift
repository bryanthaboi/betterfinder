import Foundation

public struct ModPackage: Sendable {
    public private(set) var files: [String: Data]
    public private(set) var inventoryDiagnostics: [ModDiagnostic]

    public init(files: [String: Data], extraDiagnostics: [ModDiagnostic] = [], limits: ModCatalogLimits = .v1) {
        self.files = files
        var diags = extraDiagnostics
        var total = 0
        var seenFolded = [String: String]()
        for path in files.keys.sorted() {
            let data = files[path]!
            total += data.count
            if !ModPatterns.matches(path, ModPatterns.relativePath) {
                diags.append(ModDiagnostic(.pathNotContained, file: path, message: "path '\(path)' is not a contained relative path"))
            }
            let folded = path.precomposedStringWithCanonicalMapping.lowercased()
            if let other = seenFolded[folded] {
                diags.append(ModDiagnostic(.duplicatePath, file: path, message: "'\(path)' collides with '\(other)' on case-insensitive file systems"))
            } else { seenFolded[folded] = path }
            if ModPackage.looksExecutable(data) {
                diags.append(ModDiagnostic(.forbiddenFileType, file: path, message: "'\(path)' looks like an executable payload (Mach-O or shebang)"))
            }
        }
        if files.count > limits.maxPackageFiles {
            diags.append(ModDiagnostic(.packageTooLarge, message: "\(files.count) files; limit is \(limits.maxPackageFiles)"))
        }
        if total > limits.maxPackageBytes {
            diags.append(ModDiagnostic(.packageTooLarge, message: "\(total) bytes; limit is \(limits.maxPackageBytes)"))
        }
        inventoryDiagnostics = diags
    }

    static func looksExecutable(_ d: Data) -> Bool {
        guard d.count >= 4 else { return false }
        let b = [UInt8](d.prefix(4))
        if b[0] == 0x23, b[1] == 0x21 { return true }
        let magic = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        return [0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE, 0xCAFEBABE, 0xBEBAFECA].contains(magic)
    }

    public static func load(directory: URL, limits: ModCatalogLimits = .v1) -> ModPackage {
        var files = [String: Data]()
        var diags = [ModDiagnostic]()
        let fm = FileManager.default
        let root = directory.standardizedFileURL.path
        guard let en = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: []) else {
            return ModPackage(files: [:], extraDiagnostics: [ModDiagnostic(.missingManifest, message: "cannot read \(root)")])
        }
        var total = 0
        for case let url as URL in en {
            let full = url.standardizedFileURL.path
            let rel = String(full.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if rel.split(separator: "/").last == ".DS_Store" { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isDirectoryKey])
            if values?.isSymbolicLink == true {
                diags.append(ModDiagnostic(.forbiddenFileType, file: rel, message: "'\(rel)' is a symbolic link"))
                en.skipDescendants()
                continue
            }
            if values?.isDirectory == true { continue }
            guard values?.isRegularFile == true else {
                diags.append(ModDiagnostic(.forbiddenFileType, file: rel, message: "'\(rel)' is not a regular file"))
                continue
            }
            total += values?.fileSize ?? 0
            if total > limits.maxPackageBytes || files.count >= limits.maxPackageFiles { continue }
            if let attrs = try? fm.attributesOfItem(atPath: full), let perm = attrs[.posixPermissions] as? Int, perm & 0o111 != 0 {
                diags.append(ModDiagnostic(.forbiddenFileType, file: rel, message: "'\(rel)' has an executable permission bit"))
            }
            if let d = try? Data(contentsOf: url) { files[rel] = d }
        }
        if total > limits.maxPackageBytes {
            diags.append(ModDiagnostic(.packageTooLarge, message: "\(total) bytes; limit is \(limits.maxPackageBytes)"))
        }
        return ModPackage(files: files, extraDiagnostics: diags, limits: limits)
    }

    public func data(_ path: String) -> Data? { files[path] }
    public func exists(_ path: String) -> Bool { files[path] != nil }
    public func isDirectory(_ path: String) -> Bool {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return files.keys.contains { $0.hasPrefix(prefix) }
    }

    public var treeHash: String {
        var lines = [String]()
        for path in files.keys.sorted() { lines.append("\(path)\u{0}\(SHA256.hex(files[path]!))\n") }
        return SHA256.hex(lines.joined())
    }
}
