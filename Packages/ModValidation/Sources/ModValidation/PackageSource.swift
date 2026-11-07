import Foundation
import ModKit

public enum PackageInventory {
    static let forbiddenExtensions: Set<String> = [
        "dylib", "so", "bundle", "app", "framework", "kext", "exe", "dll", "sh", "bash", "zsh", "command", "pkg", "dmg",
        "jar", "class", "wasm", "zip", "bfmod", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "a", "o", "node", "scpt",
        "scptd", "workflow",
    ]

    static let excludedComponents: Set<String> = [".git", ".github", ".svn", ".hg", "node_modules", ".build", ".DS_Store", "__MACOSX"]
    static let excludedFiles: Set<String> = ["betterfinder.d.ts", "tsconfig.json", ".gitignore", ".gitattributes", "package-lock.json"]

    static func forbiddenDiagnostic(path: String) -> ModDiagnostic? {
        let last = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = last.lastIndex(of: "."), dot != last.startIndex else { return nil }
        let ext = last[last.index(after: dot)...].lowercased()
        guard forbiddenExtensions.contains(ext) else { return nil }
        return ModDiagnostic(
            .forbiddenFileType, file: path, message: "'\(path)' has the forbidden file type .\(ext) (executable payload or nested archive)",
            fix: "Remove it from the package"
        )
    }

    public static func isExcludedFromPackaging(_ relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/").map(String.init)
        if parts.contains(where: excludedComponents.contains) { return true }
        guard let last = parts.last else { return false }
        if parts.count == 1, excludedFiles.contains(last) { return true }
        return last.hasSuffix(".bfmod") || last.hasSuffix(".bfmod.receipt.json")
    }
}

public enum PackageLoader {
    public static func loadDirectory(_ directory: URL, limits: ModCatalogLimits = .v1) -> ModPackage {
        var files = [String: Data]()
        var diags = [ModDiagnostic]()
        let fm = FileManager.default
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue,
              let en = fm.enumerator(at: directory.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey], options: [])
        else {
            return ModPackage(files: [:], extraDiagnostics: [ModDiagnostic(.missingManifest, message: "cannot read directory \(directory.path)")])
        }
        var total = 0
        var count = 0
        var entries = [(rel: String, url: URL)]()
        for case let url as URL in en {
            let full = url.standardizedFileURL.path
            let rel = String(full.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            if PackageInventory.isExcludedFromPackaging(rel) {
                if values?.isDirectory == true { en.skipDescendants() }
                continue
            }
            if values?.isSymbolicLink == true {
                diags.append(ModDiagnostic(.forbiddenFileType, file: rel, message: "'\(rel)' is a symbolic link", fix: "Replace the link with a regular file"))
                en.skipDescendants()
                continue
            }
            if values?.isDirectory == true { continue }
            guard values?.isRegularFile == true else {
                diags.append(ModDiagnostic(.forbiddenFileType, file: rel, message: "'\(rel)' is not a regular file"))
                continue
            }
            entries.append((rel, url))
        }
        entries.sort { Array($0.rel.utf8).lexicographicallyPrecedes(Array($1.rel.utf8)) }
        for (rel, url) in entries {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += size
            count += 1
            if total > limits.maxPackageBytes || count > limits.maxPackageFiles { continue }
            if let attrs = try? fm.attributesOfItem(atPath: url.path), let perm = attrs[.posixPermissions] as? Int, perm & 0o111 != 0 {
                diags.append(ModDiagnostic(.forbiddenFileType, file: rel, message: "'\(rel)' has an executable permission bit", fix: "chmod a-x the file"))
                continue
            }
            if let forbidden = PackageInventory.forbiddenDiagnostic(path: rel) {
                diags.append(forbidden)
                continue
            }
            if let d = try? Data(contentsOf: url) { files[rel] = d }
        }
        if total > limits.maxPackageBytes {
            diags.append(ModDiagnostic(.packageTooLarge, message: "\(total) bytes; limit is \(limits.maxPackageBytes)"))
        }
        if count > limits.maxPackageFiles {
            diags.append(ModDiagnostic(.packageTooLarge, message: "\(count) files; limit is \(limits.maxPackageFiles)"))
        }
        return ModPackage(files: files, extraDiagnostics: diags, limits: limits)
    }

    public static func loadArchive(_ data: Data, name: String? = nil, limits: ModCatalogLimits = .v1) -> (package: ModPackage, fatal: Bool) {
        var extraction = ZipReader.extract(data, limits: ZipLimits(catalog: limits), archiveName: name)
        extraction.diagnostics = extraction.diagnostics.map { $0.migrated(.archive) }
        if extraction.fatal { return (ModPackage(files: [:], extraDiagnostics: extraction.diagnostics, limits: limits), true) }
        return (ModPackage(files: extraction.files, extraDiagnostics: extraction.diagnostics, limits: limits), false)
    }
}

public enum ModPackaging {
    public static func archive(package: ModPackage) -> Data {
        ZipWriter.build(package.files.map { ($0.key, $0.value) })
    }
}

public enum ModPackageSource: Sendable {
    case directory(URL)
    case archive(URL)
    case archiveData(Data, name: String?)
    case package(ModPackage)

    public static func detect(_ url: URL) -> ModPackageSource {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return .directory(url) }
        return .archive(url)
    }
}
