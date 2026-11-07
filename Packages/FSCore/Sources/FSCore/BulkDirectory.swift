import Darwin
import Foundation

struct BulkEntry {
    var name: String
    var inode: UInt64?
    var device: Int32?
    var realDevice: UInt32?
    var type: UInt32?
    var flags: UInt32?
    var mount: UInt32?
    var links: UInt32?
    var allocated: Int64?
    var logical: Int64?
    var created: timespec?
    var modified: timespec?
    var added: timespec?
}

final class BulkDirectory {
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: 65536, alignment: 8)
    deinit { buffer.deallocate() }

    func read(fd: Int32, consume: (BulkEntry) throws -> Void) throws {
        var attrs = attrlist()
        attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = [UInt32(ATTR_CMN_NAME), UInt32(ATTR_CMN_RETURNED_ATTRS), UInt32(ATTR_CMN_ERROR), UInt32(ATTR_CMN_OBJTYPE), UInt32(ATTR_CMN_FILEID), UInt32(ATTR_CMN_DEVID), UInt32(ATTR_CMN_FLAGS), UInt32(ATTR_CMN_CRTIME), UInt32(ATTR_CMN_MODTIME), UInt32(ATTR_CMN_ADDEDTIME)].reduce(UInt32(0)) { $0 | UInt32($1) }
        attrs.dirattr = UInt32(ATTR_DIR_MOUNTSTATUS)
        attrs.fileattr = UInt32(ATTR_FILE_ALLOCSIZE | ATTR_FILE_TOTALSIZE | ATTR_FILE_LINKCOUNT)
        attrs.forkattr = UInt32(ATTR_CMNEXT_REALDEVID)
        while true {
            try Task.checkCancellation()
            let count = getattrlistbulk(fd, &attrs, buffer, 65536, UInt64(FSOPT_ATTR_CMN_EXTENDED))
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if count == 0 { return }
            var start = 0
            for _ in 0..<count {
                guard start <= 65532 else { throw POSIXError(.EIO) }
                let length = Int(buffer.loadUnaligned(fromByteOffset: start, as: UInt32.self))
                guard length >= 24, length % 4 == 0, length <= 65536 - start else { throw POSIXError(.EIO) }
                let end = start + length
                var cursor = start + 4
                func take<T>(_ type: T.Type) throws -> T {
                    guard cursor <= end - MemoryLayout<T>.size else { throw POSIXError(.EIO) }
                    defer { cursor += MemoryLayout<T>.size }
                    return buffer.loadUnaligned(fromByteOffset: cursor, as: T.self)
                }
                let returned = try take(attribute_set_t.self)
                guard returned.commonattr & UInt32(ATTR_CMN_NAME) != 0 else { throw POSIXError(.EIO) }
                let referenceOffset = cursor
                let ref = try take(attrreference_t.self)
                let nameOffset = referenceOffset + Int(ref.attr_dataoffset)
                let nameLength = Int(ref.attr_length)
                guard nameLength > 1, nameOffset >= cursor, nameOffset <= end - nameLength,
                      buffer.load(fromByteOffset: nameOffset + nameLength - 1, as: UInt8.self) == 0 else { throw POSIXError(.EIO) }
                let bytes = UnsafeRawBufferPointer(start: buffer.advanced(by: nameOffset), count: nameLength - 1)
                guard let name = String(bytes: bytes, encoding: .utf8), !name.contains("/"), name != ".", name != ".." else { throw POSIXError(.EILSEQ) }
                var entry = BulkEntry(name: name)
                if returned.commonattr & UInt32(ATTR_CMN_DEVID) != 0 { entry.device = try take(Int32.self) }
                if returned.commonattr & UInt32(ATTR_CMN_OBJTYPE) != 0 { entry.type = try take(UInt32.self) }
                if returned.commonattr & UInt32(ATTR_CMN_CRTIME) != 0 { entry.created = try take(timespec.self) }
                if returned.commonattr & UInt32(ATTR_CMN_MODTIME) != 0 { entry.modified = try take(timespec.self) }
                if returned.commonattr & UInt32(ATTR_CMN_FLAGS) != 0 { entry.flags = try take(UInt32.self) }
                if returned.commonattr & UInt32(ATTR_CMN_FILEID) != 0 { entry.inode = try take(UInt64.self) }
                if returned.commonattr & UInt32(ATTR_CMN_ADDEDTIME) != 0 { entry.added = try take(timespec.self) }
                if returned.commonattr & UInt32(ATTR_CMN_ERROR) != 0 {
                    let error = try take(Int32.self)
                    if error != 0 { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
                }
                if returned.dirattr & UInt32(ATTR_DIR_MOUNTSTATUS) != 0 { entry.mount = try take(UInt32.self) }
                if returned.fileattr & UInt32(ATTR_FILE_LINKCOUNT) != 0 { entry.links = try take(UInt32.self) }
                if returned.fileattr & UInt32(ATTR_FILE_TOTALSIZE) != 0 { entry.logical = try take(Int64.self) }
                if returned.fileattr & UInt32(ATTR_FILE_ALLOCSIZE) != 0 { entry.allocated = try take(Int64.self) }
                if returned.forkattr & UInt32(ATTR_CMNEXT_REALDEVID) != 0 { entry.realDevice = try take(UInt32.self) }
                guard cursor <= nameOffset else { throw POSIXError(.EIO) }
                try autoreleasepool { try consume(entry) }
                start = end
            }
        }
    }
}
