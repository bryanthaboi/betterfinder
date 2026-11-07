import Foundation
import UniformTypeIdentifiers

public struct FileItem: Hashable, Identifiable, Sendable {
    public var id: URL { url }
    public let url: URL
    public var name: String
    public var isDirectory: Bool
    public var isPackage: Bool
    public var isSymlink: Bool
    public var isHidden: Bool
    public var logicalSize: Int64?
    public var allocatedSize: Int64?
    public var dateModified: Date?
    public var dateCreated: Date?
    public var dateAdded: Date?
    public var contentTypeIdentifier: String?
    private var storedTagNames: [String]
    var deferredTags = false
    public var tagNames: [String] {
        get { deferredTags ? DirectoryLister.tagNames(url) : storedTagNames }
        set { storedTagNames = newValue; deferredTags = false }
    }
    public var fileID: UInt64?
    public var deviceID: Int32?
    public var linkCount: Int?
    private var storedIsUbiquitous: Bool
    private var storedUbiquitousStatus: String?
    var deferredCloudMetadata = false
    public var isUbiquitous: Bool {
        get { deferredCloudMetadata ? ((try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem ?? false) : storedIsUbiquitous }
        set { storedIsUbiquitous = newValue; deferredCloudMetadata = false }
    }
    public var ubiquitousStatus: String? {
        get { deferredCloudMetadata ? (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus?.rawValue : storedUbiquitousStatus }
        set { storedUbiquitousStatus = newValue; deferredCloudMetadata = false }
    }

    public init(
        url: URL,
        name: String,
        isDirectory: Bool,
        isPackage: Bool = false,
        isSymlink: Bool = false,
        isHidden: Bool = false,
        logicalSize: Int64? = nil,
        allocatedSize: Int64? = nil,
        dateModified: Date? = nil,
        dateCreated: Date? = nil,
        dateAdded: Date? = nil,
        contentTypeIdentifier: String? = nil,
        tagNames: [String] = [],
        fileID: UInt64? = nil,
        deviceID: Int32? = nil,
        linkCount: Int? = nil,
        isUbiquitous: Bool = false,
        ubiquitousStatus: String? = nil
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymlink = isSymlink
        self.isHidden = isHidden
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.dateModified = dateModified
        self.dateCreated = dateCreated
        self.dateAdded = dateAdded
        self.contentTypeIdentifier = contentTypeIdentifier
        self.storedTagNames = tagNames
        self.fileID = fileID
        self.deviceID = deviceID
        self.linkCount = linkCount
        self.storedIsUbiquitous = isUbiquitous
        self.storedUbiquitousStatus = ubiquitousStatus
    }

    public var isBrowsableFolder: Bool { isDirectory && !isPackage }

    public var contentType: UTType? {
        contentTypeIdentifier.flatMap(UTType.init)
    }

    public var kindDescription: String {
        if isDirectory && !isPackage { return "Folder" }
        return contentType?.localizedDescription ?? "Document"
    }
}
