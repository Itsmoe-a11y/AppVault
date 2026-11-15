import Foundation
import UIKit
import zlib

public final class StreamingArchiveEngine {
    public static let shared = StreamingArchiveEngine()

    private let fileManager = FileManager.default

    private init() {}

    // MARK: - Stream Item Definition
    struct StreamItem {
        let diskURL: URL
        let archiveRelativePath: String
        let isDirectory: Bool
        let size: Int64
    }

    // MARK: - Tar Header Structure (512 bytes POSIX UStar)
    private struct TarHeader {
        var name: String        // 100 bytes
        var mode: mode_t        // 8 bytes octal
        var uid: uid_t          // 8 bytes octal
        var gid: gid_t          // 8 bytes octal
        var size: Int64         // 12 bytes octal
        var mtime: time_t       // 12 bytes octal
        var typeflag: Character // 1 byte ('0' file, '5' dir)
        var linkname: String    // 100 bytes
        var uname: String       // 32 bytes
        var gname: String       // 32 bytes
        var prefix: String      // 155 bytes

        init(path: String, size: Int64, isDirectory: Bool, mode: mode_t = 0o644) {
            self.size = isDirectory ? 0 : size
            self.typeflag = isDirectory ? "5" : "0"
            self.mode = isDirectory ? 0o755 : mode
            self.uid = 501
            self.gid = 501
            self.mtime = time(nil)
            self.linkname = ""
            self.uname = "mobile"
            self.gname = "mobile"

            if path.utf8.count > 100 {
                let parts = path.components(separatedBy: "/")
                if parts.count > 1 {
                    let filename = parts.last!
                    let prefixPath = parts.dropLast().joined(separator: "/")
                    self.name = String(filename.prefix(100))
                    self.prefix = String(prefixPath.prefix(155))
                } else {
                    self.name = String(path.prefix(100))
                    self.prefix = ""
                }
            } else {
                self.name = path
                self.prefix = ""
            }
        }

        func toData() -> Data {
            var data = Data(count: 512)
            data.withUnsafeMutableBytes { (rawPtr: UnsafeMutableRawBufferPointer) in
                let ptr = rawPtr.bindMemory(to: UInt8.self).baseAddress!
                memset(ptr, 0, 512)

                func writeString(_ str: String, offset: Int, maxLen: Int) {
                    let cStr = str.utf8CString
                    let len = min(cStr.count - 1, maxLen)
                    if len > 0 {
                        cStr.withUnsafeBufferPointer { buf in
                            memcpy(ptr + offset, buf.baseAddress!, len)
                        }
                    }
                }

                func writeOctal(_ val: Int64, offset: Int, len: Int) {
                    let formatted = String(format: "%0*llo", len - 1, val)
                    writeString(formatted, offset: offset, maxLen: len - 1)
                }

                writeString(name, offset: 0, maxLen: 100)
                writeOctal(Int64(mode), offset: 100, len: 8)
                writeOctal(Int64(uid), offset: 108, len: 8)
                writeOctal(Int64(gid), offset: 116, len: 8)
                writeOctal(size, offset: 124, len: 12)
                writeOctal(Int64(mtime), offset: 136, len: 12)

                // Fill checksum with spaces before computing
                memset(ptr + 148, 0x20, 8)
                writeString(String(typeflag), offset: 156, maxLen: 1)
                writeString(linkname, offset: 157, maxLen: 100)
                writeString("ustar", offset: 257, maxLen: 6)
                writeString("00", offset: 263, maxLen: 2)
                writeString(uname, offset: 265, maxLen: 32)
                writeString(gname, offset: 297, maxLen: 32)
                writeString(prefix, offset: 345, maxLen: 155)

                var sum: UInt32 = 0
                for i in 0..<512 {
                    sum += UInt32(ptr[i])
                }
                let chkStr = String(format: "%06o", sum)
                writeString(chkStr, offset: 148, maxLen: 6)
                ptr[148 + 6] = 0
                ptr[148 + 7] = 0x20
            }
            return data
        }
    }

    // MARK: - Streaming Gzip Compressor
    private final class GzipStreamWriter {
        private var stream = z_stream()
        private var isOpen = false
        private let onChunk: (Data) async throws -> Void
        private var outBuffer = [UInt8](repeating: 0, count: 65536)

        init(onChunk: @escaping (Data) async throws -> Void) throws {
            self.onChunk = onChunk
            stream.zalloc = nil
            stream.zfree = nil
            stream.opaque = nil

            let ret = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard ret == Z_OK else {
                throw NSError(domain: "AppVault.Streaming", code: Int(ret), userInfo: [NSLocalizedDescriptionKey: "Failed to initialize zlib deflate stream: \(ret)"])
            }
            isOpen = true
        }

        func write(data: Data) async throws {
            guard isOpen, !data.isEmpty else { return }
            var offset = 0
            let inputCount = data.count

            while offset < inputCount {
                var producedChunk: Data? = nil

                data.withUnsafeBytes { rawBuffer in
                    let basePtr = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
                    stream.next_in = UnsafeMutablePointer(mutating: basePtr.advanced(by: offset))
                    stream.avail_in = uInt(min(inputCount - offset, 65536))

                    outBuffer.withUnsafeMutableBytes { outRaw in
                        let outPtr = outRaw.bindMemory(to: UInt8.self).baseAddress!
                        stream.avail_out = uInt(outBuffer.count)
                        stream.next_out = outPtr

                        deflate(&stream, Z_NO_FLUSH)

                        let have = outBuffer.count - Int(stream.avail_out)
                        if have > 0 {
                            producedChunk = Data(bytes: outPtr, count: have)
                        }
                    }

                    let consumed = Int(inputCount - offset) - Int(stream.avail_in)
                    offset += max(consumed, 1)
                }

                if let chunk = producedChunk {
                    try await onChunk(chunk)
                }
            }
        }

        func finish() async throws {
            guard isOpen else { return }
            defer {
                deflateEnd(&stream)
                isOpen = false
            }

            stream.avail_in = 0
            stream.next_in = nil

            var status = Z_OK
            while status != Z_STREAM_END {
                var producedChunk: Data? = nil

                outBuffer.withUnsafeMutableBytes { outRaw in
                    let outPtr = outRaw.bindMemory(to: UInt8.self).baseAddress!
                    stream.avail_out = uInt(outBuffer.count)
                    stream.next_out = outPtr

                    status = deflate(&stream, Z_FINISH)

                    let have = outBuffer.count - Int(stream.avail_out)
                    if have > 0 {
                        producedChunk = Data(bytes: outPtr, count: have)
                    }
                }

                if let chunk = producedChunk {
                    try await onChunk(chunk)
                }
            }
        }
    }

    // MARK: - Stream Backup Creation (Zero Staging Footprint)
    public func streamBackup(
        for app: InstalledApp,
        mode: BackupMode,
        includeCaches: Bool,
        note: String,
        onProgress: @escaping (OperationProgress) -> Void,
        onCompressedChunk: @escaping (Data) async throws -> Void
    ) async throws -> BackupRecord {
        let backupID = UUID()
        let safeName = app.name.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        let timestamp = Int(Date().timeIntervalSince1970)
        let archiveName = "\(safeName)_\(app.bundleIdentifier)_\(timestamp).adbk"

        onProgress(OperationProgress(
            stage: "Analyzing App Footprint",
            fractionCompleted: 0.05,
            statusDetail: "Cataloging source files without staging..."
        ))

        var items: [StreamItem] = []
        var totalBytesToProcess: Int64 = 0

        // A. App Bundle (if Full mode)
        var hasBundle = false
        if mode == .full, let bundleURL = app.bundleURL, fileManager.fileExists(atPath: bundleURL.path) {
            hasBundle = true
            let bundleName = bundleURL.lastPathComponent
            let baseArchive = "Payload/\(bundleName)"
            collectItems(rootURL: bundleURL, baseArchivePath: baseArchive, into: &items, totalBytes: &totalBytesToProcess)
        }

        // B. Data Container
        var hasData = false
        if let dataURL = app.dataContainerURL, fileManager.fileExists(atPath: dataURL.path) {
            hasData = true
            let subdirs = ["Documents", "Library", "SystemData"]
            for sub in subdirs {
                let subURL = dataURL.appendingPathComponent(sub)
                guard fileManager.fileExists(atPath: subURL.path) else { continue }
                collectItems(rootURL: subURL, baseArchivePath: "Data/\(sub)", includeCaches: includeCaches, into: &items, totalBytes: &totalBytesToProcess)
            }
        }

        // C. App Groups
        var savedGroups: [String] = []
        for (groupID, groupURL) in app.groupContainerURLs {
            guard fileManager.fileExists(atPath: groupURL.path) else { continue }
            savedGroups.append(groupID)
            for sub in ["Documents", "Library"] {
                let subURL = groupURL.appendingPathComponent(sub)
                guard fileManager.fileExists(atPath: subURL.path) else { continue }
                collectItems(rootURL: subURL, baseArchivePath: "AppGroups/\(groupID)/\(sub)", includeCaches: includeCaches, into: &items, totalBytes: &totalBytesToProcess)
            }
        }

        // 2. Prepare Metadata Plist
        var record = BackupRecord(
            id: backupID,
            bundleIdentifier: app.bundleIdentifier,
            appName: app.name,
            appVersion: app.version,
            appBuild: app.build,
            createdAt: Date(),
            mode: mode,
            includesCaches: includeCaches,
            note: note,
            archiveFileName: archiveName,
            fileSizeBytes: 0,
            hasAppBundle: hasBundle,
            hasDataContainer: hasData,
            appGroupIDs: savedGroups
        )

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let metaData = try encoder.encode(record)

        // 3. Initialize Gzip Stream Writer
        let gzip = try GzipStreamWriter(onChunk: onCompressedChunk)

        // Write Metadata file into root of tar stream
        let metaHeader = TarHeader(path: "BackupMetadata.plist", size: Int64(metaData.count), isDirectory: false)
        try await gzip.write(data: metaHeader.toData())
        try await gzip.write(data: metaData)
        let metaPad = (512 - (metaData.count % 512)) % 512
        if metaPad > 0 {
            try await gzip.write(data: Data(count: metaPad))
        }

        // 4. Stream Source Files with Zero Memory/Staging Overhead
        var bytesProcessed: Int64 = 0
        let bufferSize = 65536 // 64 KB read buffer

        for item in items {
            if item.isDirectory {
                let dirHeader = TarHeader(path: item.archiveRelativePath + "/", size: 0, isDirectory: true)
                try await gzip.write(data: dirHeader.toData())
                continue
            }

            guard let handle = try? FileHandle(forReadingFrom: item.diskURL) else { continue }
            defer { try? handle.close() }

            let header = TarHeader(path: item.archiveRelativePath, size: item.size, isDirectory: false)
            try await gzip.write(data: header.toData())

            var fileBytesRead: Int64 = 0
            while fileBytesRead < item.size {
                let toRead = Int(min(Int64(bufferSize), item.size - fileBytesRead))
                let chunkData = handle.readData(ofLength: toRead)
                if chunkData.isEmpty { break }

                try await gzip.write(data: chunkData)
                fileBytesRead += Int64(chunkData.count)
                bytesProcessed += Int64(chunkData.count)

                if bytesProcessed % (512 * 1024) < Int64(bufferSize) || bytesProcessed == totalBytesToProcess {
                    let progressFraction = totalBytesToProcess > 0 ? min(0.95, Double(bytesProcessed) / Double(totalBytesToProcess)) : 0.5
                    onProgress(OperationProgress(
                        stage: "Streaming Compression",
                        fractionCompleted: progressFraction,
                        statusDetail: "Streaming \(item.archiveRelativePath) (\(ByteCountFormatter.string(fromByteCount: bytesProcessed, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: totalBytesToProcess, countStyle: .file)))"
                    ))
                }
            }

            let pad = (512 - (Int(item.size) % 512)) % 512
            if pad > 0 {
                try await gzip.write(data: Data(count: pad))
            }
        }

        // 5. Write End-of-Archive (1024 null bytes)
        try await gzip.write(data: Data(count: 1024))
        try await gzip.finish()

        onProgress(OperationProgress(
            stage: "Completed",
            fractionCompleted: 1.0,
            statusDetail: "Archive streamed successfully!",
            isCompleted: true
        ))

        return record
    }

    // MARK: - Recursively Collect Items Without Copying
    private func collectItems(
        rootURL: URL,
        baseArchivePath: String,
        includeCaches: Bool = true,
        into items: inout [StreamItem],
        totalBytes: inout Int64
    ) {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDir) else { return }

        if !isDir.boolValue {
            let size = (try? fileManager.attributesOfItem(atPath: rootURL.path)[.size] as? Int64) ?? 0
            items.append(StreamItem(diskURL: rootURL, archiveRelativePath: baseArchivePath, isDirectory: false, size: size))
            totalBytes += size
            return
        }

        items.append(StreamItem(diskURL: rootURL, archiveRelativePath: baseArchivePath, isDirectory: true, size: 0))

        guard let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsPackageDescendants]) else {
            return
        }

        for case let url as URL in enumerator {
            let subPath = url.path.replacingOccurrences(of: rootURL.path, with: "")
            let cleanSubPath = subPath.hasPrefix("/") ? String(subPath.dropFirst()) : subPath

            if !includeCaches {
                if cleanSubPath.contains("Caches/") || cleanSubPath.contains("tmp/") || cleanSubPath.hasSuffix("/Caches") {
                    enumerator.skipDescendants()
                    continue
                }
            }

            let fullArchivePath = "\(baseArchivePath)/\(cleanSubPath)"
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDirectory = values?.isDirectory ?? false
            let fileSize = Int64(values?.fileSize ?? 0)

            items.append(StreamItem(diskURL: url, archiveRelativePath: fullArchivePath, isDirectory: isDirectory, size: fileSize))
            if !isDirectory {
                totalBytes += fileSize
            }
        }
    }
}
