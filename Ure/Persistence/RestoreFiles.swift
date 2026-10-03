import CryptoKit
import Darwin
import Foundation

nonisolated enum RestoreFiles {
    static let maximumManifestBytes: Int64 = 16 * 1024 * 1024

    static func availableCapacity(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values.volumeAvailableCapacityForImportantUsage else {
            throw RestoreError.invalidItem("staging", "Free disk space could not be checked.")
        }
        return capacity
    }

    static func checkSpace(
        _ bytes: Int64, at directory: URL, item: String,
        capacity: @Sendable (URL) throws -> Int64
    ) throws {
        guard try capacity(directory) >= bytes else {
            throw RestoreError.insufficientSpace(item)
        }
    }

    static func checking<Value>(_ item: String, _ operation: () throws -> Value) throws -> Value {
        do {
            return try operation()
        } catch let error as RestoreError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = error as NSError
            if (failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOSPC))
                || (failure.domain == NSCocoaErrorDomain
                    && failure.code == CocoaError.fileWriteOutOfSpace.rawValue)
            {
                throw RestoreError.insufficientSpace(item)
            }
            throw RestoreError.invalidItem(item, "The item is missing, damaged, or inaccessible.")
        }
    }

    static func withDirectory<Value>(
        _ url: URL, item: String, _ operation: (Int32) throws -> Value
    ) throws -> Value {
        try checking(item) {
            let descriptor = url.path.withCString {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            }
            guard descriptor >= 0 else {
                throw RestoreError.invalidItem(item, "A regular folder is required.")
            }
            defer { Darwin.close(descriptor) }
            return try operation(descriptor)
        }
    }

    static func withChildDirectory<Value>(
        _ name: String, in parent: Int32, _ operation: (Int32) throws -> Value
    ) throws -> Value {
        try checking(name) {
            let descriptor = name.withCString {
                openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            }
            guard descriptor >= 0 else {
                throw RestoreError.invalidItem(name, "A regular folder is required.")
            }
            defer { Darwin.close(descriptor) }
            return try operation(descriptor)
        }
    }

    private static func input(_ name: String, in directory: Int32) throws -> FileHandle {
        let descriptor = name.withCString {
            openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw RestoreError.invalidItem(name, "A regular file is required.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            try? handle.close()
            throw RestoreError.invalidItem(name, "A regular file is required.")
        }
        return handle
    }

    static func readManifest<Value: Decodable>(
        _ type: Value.Type, name: String, in directory: Int32
    ) throws -> Value {
        try checking(name) {
            let handle = try input(name, in: directory)
            defer { try? handle.close() }
            var status = stat()
            guard fstat(handle.fileDescriptor, &status) == 0,
                status.st_size > 0, status.st_size <= maximumManifestBytes
            else {
                throw RestoreError.invalidItem(name, "The manifest exceeds the supported size.")
            }
            var bytes = Data()
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                guard Int64(bytes.count + chunk.count) <= maximumManifestBytes else {
                    throw RestoreError.invalidItem(name, "The manifest exceeds the supported size.")
                }
                bytes.append(chunk)
            }
            return try JSONDecoder().decode(type, from: bytes)
        }
    }

    static func copy(
        _ file: SnapshotFile, name: String, from source: Int32, to destination: Int32,
        staging: URL, dependencies: LibraryDependencies
    ) throws {
        try checking(file.path) {
            let handle = try input(name, in: source)
            defer { try? handle.close() }
            var status = stat()
            guard fstat(handle.fileDescriptor, &status) == 0, status.st_size == file.byteCount
            else {
                throw RestoreError.invalidItem(file.path, "The declared size does not match.")
            }
            let descriptor = name.withCString {
                openat(destination, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            }
            guard descriptor >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? output.close() }
            var count: Int64 = 0
            var hash = SHA256()
            while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                try Task.checkCancellation()
                guard Int64(bytes.count) <= file.byteCount - count else {
                    throw RestoreError.invalidItem(file.path, "The file exceeds its declared size.")
                }
                try checkSpace(
                    Int64(bytes.count), at: staging, item: file.path,
                    capacity: dependencies.restoreAvailableCapacity)
                try output.write(contentsOf: bytes)
                hash.update(data: bytes)
                count += Int64(bytes.count)
                try dependencies.restoreCheckpoint(.copiedChunk)
            }
            guard count == file.byteCount,
                hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256
            else {
                throw RestoreError.invalidItem(
                    file.path, "The size or SHA-256 hash does not match.")
            }
            try output.synchronize()
        }
    }

    static func verify(_ file: SnapshotFile, name: String, in directory: Int32) throws {
        try checking(file.path) {
            let handle = try input(name, in: directory)
            defer { try? handle.close() }
            var hash = SHA256()
            var count: Int64 = 0
            while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                try Task.checkCancellation()
                guard Int64(bytes.count) <= file.byteCount - count else {
                    throw RestoreError.invalidItem(
                        file.path, "The staged file exceeds its declared size.")
                }
                hash.update(data: bytes)
                count += Int64(bytes.count)
            }
            guard count == file.byteCount,
                hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256
            else {
                throw RestoreError.invalidItem(
                    file.path, "The staged size or SHA-256 hash does not match.")
            }
        }
    }
}
