import AppKit
import FileOps
import FSCore

@MainActor
final class Clipboard {
    static let shared = Clipboard()

    private var cutURLs: Set<URL> = []
    private var cutChangeCount: Int = -1
    private var cutResources = false

    nonisolated static let resourceType = NSPasteboard.PasteboardType("com.bryanthaboi.betterfinder.resource-ids")

    var hasResources: Bool { NSPasteboard.general.availableType(from: [Self.resourceType]) != nil }

    nonisolated static func resources(from pb: NSPasteboard) -> [ResourceID] {
        var out: [ResourceID] = []
        for item in pb.pasteboardItems ?? [] {
            if let data = item.data(forType: resourceType), let ids = try? JSONDecoder().decode([ResourceID].self, from: data) { out += ids }
        }
        return out
    }

    func copy(resources ids: [ResourceID]) {
        guard !ids.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let local = ids.compactMap(\.fileURL)
        if local.count == ids.count {
            pb.writeObjects(local as [NSURL])
        } else {
            let item = NSPasteboardItem()
            if let data = try? JSONEncoder().encode(ids) { item.setData(data, forType: Self.resourceType) }
            item.setString(ids.map(\.name).joined(separator: "\n"), forType: .string)
            pb.writeObjects([item])
        }
        cutURLs = []
        cutResources = false
    }

    func cut(resources ids: [ResourceID]) {
        copy(resources: ids)
        cutResources = true
        cutChangeCount = NSPasteboard.general.changeCount
    }

    private var pasteIsCut: Bool {
        NSPasteboard.general.changeCount == cutChangeCount && (!cutURLs.isEmpty || cutResources)
    }

    func paste(intoResource destination: ResourceID, forceMove: Bool) {
        let pb = NSPasteboard.general
        var sources = Self.resources(from: pb)
        if sources.isEmpty, let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            sources = urls.map(ResourceID.local)
        }
        guard !sources.isEmpty else { return }
        let move = pasteIsCut || forceMove
        RemoteTransfers.enqueue(sources, into: destination, move: move)
        if move { cutURLs = []; cutResources = false; cutChangeCount = -1 }
    }

    var hasFiles: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    func isCut(_ url: URL) -> Bool {
        NSPasteboard.general.changeCount == cutChangeCount && cutURLs.contains(url)
    }

    func copy(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        cutURLs = []
        cutResources = false
    }

    func cut(_ urls: [URL]) {
        copy(urls)
        cutURLs = Set(urls)
        cutChangeCount = NSPasteboard.general.changeCount
    }

    func paste(into destination: URL, forceMove: Bool) {
        let pb = NSPasteboard.general
        if !Self.resources(from: pb).isEmpty {
            paste(intoResource: .local(destination), forceMove: forceMove)
            return
        }
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return }
        let isCut = pb.changeCount == cutChangeCount && !cutURLs.isEmpty
        if isCut || forceMove {
            FileOperationQueue.shared.enqueue(.move(sources: urls, destination: destination))
            cutURLs = []
            cutChangeCount = -1
        } else {
            FileOperationQueue.shared.enqueue(.copy(sources: urls, destination: destination))
        }
    }
}
