import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO

nonisolated struct ManagedOriginals {
    let generation: URL

    var originals: URL { LibraryFiles.originals(in: generation) }
    var staging: URL { generation.appending(path: "imports", directoryHint: .isDirectory) }

    static func storageKey(_ id: UUID) -> String { "\(id.uuidString).original" }

    static func assetID(for key: String) -> UUID? {
        guard key.hasSuffix(".original"),
            let id = UUID(uuidString: String(key.dropLast(".original".count))),
            storageKey(id) == key
        else { return nil }
        return id
    }

    func prepare() throws {
        try LibraryFiles.requireDirectory(generation.deletingLastPathComponent())
        try LibraryFiles.requireDirectory(generation)
        try LibraryFiles.requireDirectory(originals)
        if !FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        }
        try LibraryFiles.requireDirectory(staging)
    }

    func originalURL(for key: String) throws -> URL {
        guard Self.assetID(for: key) != nil else {
            throw LibraryError.invalidLibrary("An original has an invalid storage key.")
        }
        try LibraryFiles.requireDirectory(originals)
        return originals.appending(path: key)
    }

    func stagedURL(for id: UUID) -> URL { staging.appending(path: "\(id.uuidString).partial") }

    func copy(
        from source: URL, to target: URL, maximumByteCount: Int64,
        checkpoint: @Sendable (FileImportCheckpoint) throws -> Void
    ) throws -> (byteCount: Int64, sha256: String) {
        guard source.isFileURL else { throw FileImportError.invalidSource }
        let descriptor = source.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw FileImportError.invalidSource }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            throw FileImportError.invalidSource
        }
        guard maximumByteCount > 0, status.st_size <= maximumByteCount else {
            throw FileImportError.oversized(maximumByteCount)
        }
        let outputDescriptor = target.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard outputDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let output = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: true)
        defer { try? output.close() }
        var byteCount: Int64 = 0
        var hash = SHA256()
        while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            byteCount += Int64(bytes.count)
            guard byteCount <= maximumByteCount else {
                throw FileImportError.oversized(maximumByteCount)
            }
            try output.write(contentsOf: bytes)
            hash.update(data: bytes)
            try checkpoint(.copiedChunk)
        }
        guard byteCount > 0 else { throw FileImportError.corruptContent }
        try output.synchronize()
        return (byteCount, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    func validate(
        _ url: URL, id: UUID, originalFilename: String, byteCount: Int64, sha256: String,
        importedAt: Date
    ) throws -> FileAsset {
        try Task.checkCancellation()
        if let image = CGImageSourceCreateWithURL(url as CFURL, nil),
            let identifier = CGImageSourceGetType(image),
            identifier as String != FileAssetType.pdf.rawValue
        {
            guard let type = FileAssetType(rawValue: identifier as String), type != .pdf else {
                throw FileImportError.unsupportedType
            }
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            guard CGImageSourceGetCount(image) > 0,
                let decoded = CGImageSourceCreateImageAtIndex(image, 0, options),
                CGImageSourceGetStatus(image) == .statusComplete,
                CGImageSourceGetStatusAtIndex(image, 0) == .statusComplete,
                let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil)
            else { throw FileImportError.corruptContent }
            let orientation =
                ((properties as NSDictionary)[kCGImagePropertyOrientation] as? NSNumber)?.intValue
                ?? 1
            guard (1...8).contains(orientation) else { throw FileImportError.corruptContent }
            return FileAsset(
                id: id, storageKey: Self.storageKey(id), originalFilename: originalFilename,
                detectedType: type, byteCount: byteCount, sha256: sha256, importedAt: importedAt,
                pixelWidth: decoded.width, pixelHeight: decoded.height, orientation: orientation)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 1024) ?? Data()
        if header.range(of: Data("%PDF-".utf8)) != nil {
            guard let document = CGPDFDocument(url as CFURL) else {
                throw FileImportError.corruptContent
            }
            if !document.isUnlocked {
                _ = "".withCString { document.unlockWithPassword($0) }
            }
            guard document.isUnlocked else { throw FileImportError.encryptedPDF }
            guard document.numberOfPages > 0 else { throw FileImportError.corruptContent }
            for page in 1...document.numberOfPages {
                try Task.checkCancellation()
                guard document.page(at: page) != nil else { throw FileImportError.corruptContent }
            }
            return FileAsset(
                id: id, storageKey: Self.storageKey(id), originalFilename: originalFilename,
                detectedType: .pdf, byteCount: byteCount, sha256: sha256, importedAt: importedAt,
                pixelWidth: nil, pixelHeight: nil, orientation: nil)
        }
        if header.starts(with: [0xFF, 0xD8]) || header.starts(with: [0x89, 0x50, 0x4E, 0x47])
            || (header.count >= 12 && header.subdata(in: 4..<8) == Data("ftyp".utf8))
        {
            throw FileImportError.corruptContent
        }
        throw FileImportError.unsupportedType
    }

    func publish(_ staged: URL, as original: URL) throws {
        try LibraryFiles.requireDirectory(staging)
        try LibraryFiles.requireDirectory(originals)
        try LibraryFiles.requireRegularFile(staged)
        try FileManager.default.moveItem(at: staged, to: original)
        let descriptor = originals.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    func recover(referencedKeys: Set<String>) throws {
        try prepare()
        for file in try FileManager.default.contentsOfDirectory(
            at: originals, includingPropertiesForKeys: nil)
        {
            guard Self.assetID(for: file.lastPathComponent) != nil,
                !referencedKeys.contains(file.lastPathComponent)
            else { continue }
            try LibraryFiles.requireRegularFile(file)
            try FileManager.default.removeItem(at: file)
        }
        for file in try FileManager.default.contentsOfDirectory(
            at: staging, includingPropertiesForKeys: nil)
        {
            let name = file.lastPathComponent
            guard name.hasSuffix(".partial"),
                let id = UUID(uuidString: String(name.dropLast(".partial".count))),
                name == "\(id.uuidString).partial",
                !referencedKeys.contains(Self.storageKey(id))
            else { continue }
            try LibraryFiles.requireRegularFile(file)
            try FileManager.default.removeItem(at: file)
        }
    }
}
