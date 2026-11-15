import Foundation
import UIKit
import Darwin
import zlib

// MARK: - Tar Header Structure (512 bytes POSIX UStar)
struct TarHeader {
    var name: String        // 100 bytes
    var mode: mode_t        // 8 bytes octal
    var uid: uid_t          // 8 bytes octal
    var gid: gid_t          // 8 bytes octal
    var size: Int64         // 12 bytes octal
    var mtime: time_t       // 12 bytes octal
    var typeflag: Character // 1 byte ('0' file, '2' symlink, '5' dir, 'L' long link)
    var linkname: String    // 100 bytes
    var uname: String       // 32 bytes
    var gname: String       // 32 bytes
    var prefix: String      // 155 bytes
    var needsLongName: Bool // True if path exceeds UStar limits (needs GNU long link)

    init(path: String, size: Int64, typeflag: Character = "0", mode: mode_t = 0o644, linkname: String = "") {
        self.size = (typeflag == "5" || typeflag == "2") ? 0 : size
        self.typeflag = typeflag
        self.mode = typeflag == "5" ? 0o755 : mode
        self.uid = 501
        self.gid = 501
        self.mtime = time(nil)
        self.linkname = linkname
        self.uname = "mobile"
        self.gname = "mobile"
        self.needsLongName = false

        // Standardize path without leading slash
        var cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if typeflag == "5" && !cleanPath.hasSuffix("/") {
            cleanPath += "/"
        }

        var resolvedName = ""
        var resolvedPrefix = ""
        var longNameRequired = false

        let pathBytesCount = cleanPath.utf8.count
        if pathBytesCount <= 100 {
            resolvedName = cleanPath
            resolvedPrefix = ""
        } else {
            // Attempt UStar split: prefix (<= 155 bytes) / name (<= 100 bytes)
            var splitFound = false
            let chars = Array(cleanPath)

            // Search from right to left to maximize prefix length while keeping name <= 100
            for i in stride(from: chars.count - 1, through: 1, by: -1) {
                if chars[i] == "/" {
                    let prefixCandidate = String(chars[0..<i])
                    let nameCandidate = String(chars[(i + 1)...])

                    if prefixCandidate.utf8.count <= 155 && nameCandidate.utf8.count <= 100 && !nameCandidate.isEmpty {
                        resolvedPrefix = prefixCandidate
                        resolvedName = nameCandidate
                        splitFound = true
                        break
                    }
                }
            }

            if !splitFound {
                // Path exceeds UStar 155/100 limits: GNU long name header required
                longNameRequired = true
                let parts = cleanPath.components(separatedBy: "/")
                let lastPart = parts.last ?? cleanPath
                resolvedName = String(decoding: lastPart.utf8.prefix(100), as: UTF8.self)
                let prefixPart = parts.dropLast().joined(separator: "/")
                resolvedPrefix = String(decoding: prefixPart.utf8.prefix(155), as: UTF8.self)
            }
        }

        self.name = resolvedName
        self.prefix = resolvedPrefix
        self.needsLongName = longNameRequired
    }

    static func makeLongNameHeader(path: String) -> TarHeader {
        var header = TarHeader(path: "././@LongLink", size: Int64(path.utf8.count + 1), typeflag: "L", mode: 0o644)
        header.needsLongName = false
        return header
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
                let formatted = String(format: "%0*llo", len - 1, max(0, val))
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
            writeOctal(0, offset: 329, len: 8) // devmajor
            writeOctal(0, offset: 337, len: 8) // devminor
            writeString(prefix, offset: 345, maxLen: 155)

            // Compute POSIX Tar checksum (unsigned sum of 512 bytes)
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

// MARK: - Streaming Gzip Compressor (zlib deflate)
final class GzipStreamWriter {
    private let streamPtr: UnsafeMutablePointer<z_stream>
    private let outBufferPtr: UnsafeMutablePointer<UInt8>
    private let outBufferSize: Int = 65536
    private var isOpen = false
    private let onChunk: (Data) async throws -> Void

    init(onChunk: @escaping (Data) async throws -> Void) throws {
        self.onChunk = onChunk
        streamPtr = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        streamPtr.initialize(to: z_stream())
        streamPtr.pointee.zalloc = nil
        streamPtr.pointee.zfree = nil
        streamPtr.pointee.opaque = nil

        outBufferPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: outBufferSize)

        let ret = deflateInit2_(streamPtr, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard ret == Z_OK else {
            streamPtr.deinitialize(count: 1)
            streamPtr.deallocate()
            outBufferPtr.deallocate()
            throw NSError(domain: "AppVault.Streaming", code: Int(ret), userInfo: [NSLocalizedDescriptionKey: "Failed to initialize zlib deflate stream: \(ret)"])
        }
        isOpen = true
    }

    deinit {
        if isOpen {
            deflateEnd(streamPtr)
            isOpen = false
        }
        streamPtr.deinitialize(count: 1)
        streamPtr.deallocate()
        outBufferPtr.deallocate()
    }

    func write(data: Data) async throws {
        guard isOpen, !data.isEmpty else { return }

        var chunksToEmit: [Data] = []
        try data.withUnsafeBytes { rawBuffer in
            guard let basePtr = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            streamPtr.pointee.next_in = UnsafeMutablePointer(mutating: basePtr)
            streamPtr.pointee.avail_in = uInt(data.count)

            while streamPtr.pointee.avail_in > 0 {
                streamPtr.pointee.next_out = outBufferPtr
                streamPtr.pointee.avail_out = uInt(outBufferSize)

                let ret = deflate(streamPtr, Z_NO_FLUSH)
                if ret == Z_STREAM_ERROR {
                    throw NSError(domain: "AppVault.Streaming", code: Int(ret), userInfo: [NSLocalizedDescriptionKey: "zlib deflate error: Z_STREAM_ERROR"])
                }

                let have = outBufferSize - Int(streamPtr.pointee.avail_out)
                if have > 0 {
                    chunksToEmit.append(Data(bytes: outBufferPtr, count: have))
                }
            }
        }

        for chunk in chunksToEmit {
            try await onChunk(chunk)
        }
    }

    func finish() async throws {
        guard isOpen else { return }
        defer {
            deflateEnd(streamPtr)
            isOpen = false
        }

        streamPtr.pointee.avail_in = 0
        streamPtr.pointee.next_in = nil

        var ret: Int32 = Z_OK
        while ret != Z_STREAM_END {
            var producedChunk: Data? = nil

            streamPtr.pointee.next_out = outBufferPtr
            streamPtr.pointee.avail_out = uInt(outBufferSize)

            ret = deflate(streamPtr, Z_FINISH)
            if ret != Z_OK && ret != Z_STREAM_END && ret != Z_BUF_ERROR {
                throw NSError(domain: "AppVault.Streaming", code: Int(ret), userInfo: [NSLocalizedDescriptionKey: "zlib deflate finish error: \(ret)"])
            }

            let have = outBufferSize - Int(streamPtr.pointee.avail_out)
            if have > 0 {
                producedChunk = Data(bytes: outBufferPtr, count: have)
            }

            if let chunk = producedChunk {
                try await onChunk(chunk)
            }

            if ret == Z_BUF_ERROR && streamPtr.pointee.avail_out > 0 {
                break
            }
        }
    }
}

// MARK: - Streaming Gzip Decompressor (zlib inflate)
final class GzipDecompressor {
    private let streamPtr: UnsafeMutablePointer<z_stream>
    private let outBufferPtr: UnsafeMutablePointer<UInt8>
    private let outBufferSize: Int = 65536
    private var isOpen = false

    init() throws {
        streamPtr = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        streamPtr.initialize(to: z_stream())
        streamPtr.pointee.zalloc = nil
        streamPtr.pointee.zfree = nil
        streamPtr.pointee.opaque = nil

        outBufferPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: outBufferSize)

        // 15 + 32 enables automatic gzip or zlib header decoding
        let ret = inflateInit2_(streamPtr, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard ret == Z_OK else {
            streamPtr.deinitialize(count: 1)
            streamPtr.deallocate()
            outBufferPtr.deallocate()
            throw NSError(
                domain: "AppVault.Streaming",
                code: Int(ret),
                userInfo: [NSLocalizedDescriptionKey: "Failed to initialize zlib inflate stream: \(ret)"]
            )
        }
        isOpen = true
    }

    deinit {
        close()
        streamPtr.deinitialize(count: 1)
        streamPtr.deallocate()
        outBufferPtr.deallocate()
    }

    /// Decompresses an input chunk and passes uncompressed bytes to onChunk.
    /// Returns true if Z_STREAM_END was reached.
    func decompress(data: Data, onChunk: (Data) throws -> Void) throws -> Bool {
        guard isOpen, !data.isEmpty else { return false }
        var isStreamEnd = false

        try data.withUnsafeBytes { rawBuffer in
            guard let basePtr = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            streamPtr.pointee.next_in = UnsafeMutablePointer(mutating: basePtr)
            streamPtr.pointee.avail_in = uInt(data.count)

            while streamPtr.pointee.avail_in > 0 && !isStreamEnd {
                streamPtr.pointee.next_out = outBufferPtr
                streamPtr.pointee.avail_out = uInt(outBufferSize)

                let ret = inflate(streamPtr, Z_NO_FLUSH)

                switch ret {
                case Z_OK:
                    break
                case Z_STREAM_END:
                    isStreamEnd = true
                case Z_BUF_ERROR:
                    break
                case Z_DATA_ERROR:
                    throw NSError(
                        domain: "AppVault.Streaming",
                        code: Int(ret),
                        userInfo: [NSLocalizedDescriptionKey: "Corrupted gzip stream: Z_DATA_ERROR"]
                    )
                case Z_STREAM_ERROR:
                    throw NSError(
                        domain: "AppVault.Streaming",
                        code: Int(ret),
                        userInfo: [NSLocalizedDescriptionKey: "Inconsistent zlib stream: Z_STREAM_ERROR"]
                    )
                case Z_MEM_ERROR:
                    throw NSError(
                        domain: "AppVault.Streaming",
                        code: Int(ret),
                        userInfo: [NSLocalizedDescriptionKey: "Out of memory in zlib inflate: Z_MEM_ERROR"]
                    )
                case Z_NEED_DICT:
                    throw NSError(
                        domain: "AppVault.Streaming",
                        code: Int(ret),
                        userInfo: [NSLocalizedDescriptionKey: "Zlib preset dictionary required: Z_NEED_DICT"]
                    )
                default:
                    throw NSError(
                        domain: "AppVault.Streaming",
                        code: Int(ret),
                        userInfo: [NSLocalizedDescriptionKey: "Unexpected zlib inflate code: \(ret)"]
                    )
                }

                let have = outBufferSize - Int(streamPtr.pointee.avail_out)
                if have > 0 {
                    let chunk = Data(bytes: outBufferPtr, count: have)
                    try onChunk(chunk)
                }

                if streamPtr.pointee.avail_out == uInt(outBufferSize) && !isStreamEnd {
                    break
                }
            }
        }

        return isStreamEnd
    }

    func close() {
        if isOpen {
            inflateEnd(streamPtr)
            isOpen = false
        }
    }
}

// MARK: - Streaming POSIX Tar Extractor
final class TarExtractor {
    private let destinationDir: URL
    private let fileManager = FileManager.default
    private var buffer = Data()
    private var pendingLongName: String? = nil

    private enum State {
        case readingHeader
        case readingFileData(bytesRemaining: Int64, paddingRemaining: Int, fileHandle: FileHandle, destPath: String, mode: mode_t)
        case readingLongName(bytesRemaining: Int64, paddingRemaining: Int, accumulated: Data)
        case completed
    }

    private var isCompleted: Bool {
        if case .completed = state { return true }
        return false
    }

    private var state: State = .readingHeader
    private var consecutiveZeroBlocks = 0

    init(destinationDir: URL) {
        self.destinationDir = destinationDir
    }

    func feed(data: Data) throws {
        guard !isCompleted else { return }
        buffer.append(data)
        try processBuffer()
    }

    func finish() throws {
        if case .readingFileData(_, _, let handle, _, _) = state {
            try? handle.close()
        }
        state = .completed
    }

    private func processBuffer() throws {
        while !buffer.isEmpty && !isCompleted {
            switch state {
            case .readingHeader:
                guard buffer.count >= 512 else { return }
                let headerBlock = buffer.prefix(512)
                buffer.removeFirst(512)
                try parseHeaderBlock(Data(headerBlock))

            case .readingFileData(var bytesRemaining, var paddingRemaining, let handle, let destPath, let mode):
                if bytesRemaining > 0 {
                    let toWrite = min(Int64(buffer.count), bytesRemaining)
                    let writeData = buffer.prefix(Int(toWrite))
                    try handle.write(contentsOf: writeData)
                    buffer.removeFirst(Int(toWrite))
                    bytesRemaining -= toWrite
                }

                if bytesRemaining == 0 {
                    if paddingRemaining > 0 {
                        let toSkip = min(buffer.count, paddingRemaining)
                        buffer.removeFirst(toSkip)
                        paddingRemaining -= toSkip
                    }

                    if paddingRemaining == 0 {
                        try? handle.close()
                        chmod(destPath, mode != 0 ? mode : 0o644)
                        state = .readingHeader
                    } else {
                        state = .readingFileData(bytesRemaining: 0, paddingRemaining: paddingRemaining, fileHandle: handle, destPath: destPath, mode: mode)
                    }
                } else {
                    state = .readingFileData(bytesRemaining: bytesRemaining, paddingRemaining: paddingRemaining, fileHandle: handle, destPath: destPath, mode: mode)
                }

            case .readingLongName(var bytesRemaining, var paddingRemaining, var accumulated):
                if bytesRemaining > 0 {
                    let toRead = min(Int64(buffer.count), bytesRemaining)
                    accumulated.append(buffer.prefix(Int(toRead)))
                    buffer.removeFirst(Int(toRead))
                    bytesRemaining -= toRead
                }

                if bytesRemaining == 0 {
                    if paddingRemaining > 0 {
                        let toSkip = min(buffer.count, paddingRemaining)
                        buffer.removeFirst(toSkip)
                        paddingRemaining -= toSkip
                    }

                    if paddingRemaining == 0 {
                        if let nullIndex = accumulated.firstIndex(of: 0) {
                            accumulated = accumulated.prefix(upTo: nullIndex)
                        }
                        self.pendingLongName = String(data: accumulated, encoding: .utf8)
                        state = .readingHeader
                    } else {
                        state = .readingLongName(bytesRemaining: 0, paddingRemaining: paddingRemaining, accumulated: accumulated)
                    }
                } else {
                    state = .readingLongName(bytesRemaining: bytesRemaining, paddingRemaining: paddingRemaining, accumulated: accumulated)
                }

            case .completed:
                return
            }
        }
    }

    private func parseHeaderBlock(_ block: Data) throws {
        // 1. Check if block is all zeros (End-Of-Archive indicator)
        var isAllZero = true
        for b in block {
            if b != 0 {
                isAllZero = false
                break
            }
        }

        if isAllZero {
            consecutiveZeroBlocks += 1
            if consecutiveZeroBlocks >= 2 {
                state = .completed
            }
            return
        }
        consecutiveZeroBlocks = 0

        // 2. Checksum verification (treating checksum field bytes 148..<156 as 0x20 spaces)
        var unsignedSum: UInt32 = 0
        var signedSum: Int32 = 0
        for i in 0..<512 {
            if i >= 148 && i < 156 {
                unsignedSum += 0x20
                signedSum += 0x20
            } else {
                unsignedSum += UInt32(block[i])
                signedSum += Int32(Int8(bitPattern: block[i]))
            }
        }

        let chkData = block.subdata(in: 148..<156)
        let chkStr = String(decoding: chkData, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        guard let parsedChk = UInt32(chkStr, radix: 8) else {
            throw NSError(domain: "AppVault.Tar", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid tar checksum format in header block."])
        }

        guard parsedChk == unsignedSum || Int32(parsedChk) == signedSum else {
            throw NSError(domain: "AppVault.Tar", code: 401, userInfo: [NSLocalizedDescriptionKey: "Tar header checksum mismatch. Expected \(unsignedSum), parsed \(parsedChk)."])
        }

        // 3. Parse Header Fields
        func readString(offset: Int, length: Int) -> String {
            let slice = block.subdata(in: offset..<(offset + length))
            if let nullIdx = slice.firstIndex(of: 0) {
                return String(decoding: slice.prefix(upTo: nullIdx), as: UTF8.self)
            }
            return String(decoding: slice, as: UTF8.self)
        }

        func readOctal(offset: Int, length: Int) -> Int64 {
            let s = readString(offset: offset, length: length)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
            return Int64(s, radix: 8) ?? 0
        }

        let name = readString(offset: 0, length: 100)
        let mode = mode_t(readOctal(offset: 100, length: 8))
        let size = readOctal(offset: 124, length: 12)
        let typeflag = Character(UnicodeScalar(block[156]))
        let linkname = readString(offset: 157, length: 100)
        let prefix = readString(offset: 345, length: 155)

        // 4. Resolve full path (handling GNU Long Link, UStar prefix + name, and standard name)
        let rawResolvedPath: String
        if let longName = self.pendingLongName {
            rawResolvedPath = longName
            self.pendingLongName = nil
        } else if !prefix.isEmpty {
            rawResolvedPath = "\(prefix)/\(name)"
        } else {
            rawResolvedPath = name
        }

        var cleanPath = rawResolvedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // Security check: Guard against Tar Slip path traversal attacks
        let components = cleanPath.components(separatedBy: "/")
        if components.contains("..") {
            throw NSError(domain: "AppVault.Tar", code: 403, userInfo: [NSLocalizedDescriptionKey: "Security violation: Path contains invalid '..' components: \(cleanPath)"])
        }

        guard !cleanPath.isEmpty else { return }

        let destURL = destinationDir.appendingPathComponent(cleanPath)
        let destPath = destURL.path
        guard destPath.hasPrefix(destinationDir.path) else {
            throw NSError(domain: "AppVault.Tar", code: 403, userInfo: [NSLocalizedDescriptionKey: "Security violation: Target escapes destination directory: \(cleanPath)"])
        }

        // 5. Dispatch based on typeflag
        if typeflag == "L" {
            // GNU Long Name header
            let pad = (512 - (Int(size) % 512)) % 512
            state = .readingLongName(bytesRemaining: size, paddingRemaining: pad, accumulated: Data())
            return
        }

        if typeflag == "5" || cleanPath.hasSuffix("/") {
            // Directory
            try fileManager.createDirectory(at: destURL, withIntermediateDirectories: true)
            chmod(destPath, 0o755)
            state = .readingHeader
            return
        }

        if typeflag == "2" {
            // Symbolic link
            let parentURL = destURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
            unlink(destPath)
            symlink(linkname, destPath)
            state = .readingHeader
            return
        }

        // Regular file ('0' or '\0')
        let parentURL = destURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        unlink(destPath)
        fileManager.createFile(atPath: destPath, contents: nil, attributes: nil)

        guard let handle = try? FileHandle(forWritingTo: destURL) else {
            throw NSError(domain: "AppVault.Tar", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to open destination file for extraction: \(destPath)"])
        }

        let pad = (512 - (Int(size) % 512)) % 512
        if size == 0 {
            try? handle.close()
            chmod(destPath, mode != 0 ? mode : 0o644)
            if pad > 0 {
                state = .readingFileData(bytesRemaining: 0, paddingRemaining: pad, fileHandle: handle, destPath: destPath, mode: mode)
            } else {
                state = .readingHeader
            }
        } else {
            state = .readingFileData(bytesRemaining: size, paddingRemaining: pad, fileHandle: handle, destPath: destPath, mode: mode)
        }
    }
}

// MARK: - Streaming Archive Engine
public final class StreamingArchiveEngine {
    public static let shared = StreamingArchiveEngine()

    private let fileManager = FileManager.default

    private init() {}

    // MARK: - Stream Item Definition
    struct StreamItem {
        let diskURL: URL
        let archiveRelativePath: String
        let isDirectory: Bool
        let isSymlink: Bool
        let symlinkTarget: String
        let size: Int64
        let mode: mode_t
    }

    // MARK: - Write Tar Item with GNU Long Link Support
    private func writeTarItem(
        path: String,
        size: Int64,
        typeflag: Character,
        mode: mode_t,
        linkname: String = "",
        to gzip: GzipStreamWriter
    ) async throws {
        let header = TarHeader(path: path, size: size, typeflag: typeflag, mode: mode, linkname: linkname)
        if header.needsLongName {
            let longLinkHeader = TarHeader.makeLongNameHeader(path: path)
            try await gzip.write(data: longLinkHeader.toData())
            var pathBytes = Array(path.utf8)
            pathBytes.append(0) // Null terminator
            let pathData = Data(pathBytes)
            try await gzip.write(data: pathData)
            let pad = (512 - (pathData.count % 512)) % 512
            if pad > 0 {
                try await gzip.write(data: Data(count: pad))
            }
        }
        try await gzip.write(data: header.toData())
    }

    // MARK: - Stream Backup Creation (Zero Staging Footprint)
    public func streamBackup(
        for app: InstalledApp,
        mode: BackupMode,
        includeCaches: Bool = false,
        includeKeychain: Bool = true,
        includeAppGroups: Bool = true,
        note: String = "",
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

        // C. App Groups (if enabled)
        var savedGroups: [String] = []
        if includeAppGroups {
            for (groupID, groupURL) in app.groupContainerURLs {
                guard fileManager.fileExists(atPath: groupURL.path) else { continue }
                savedGroups.append(groupID)
                for sub in ["Documents", "Library"] {
                    let subURL = groupURL.appendingPathComponent(sub)
                    guard fileManager.fileExists(atPath: subURL.path) else { continue }
                    collectItems(rootURL: subURL, baseArchivePath: "AppGroups/\(groupID)/\(sub)", includeCaches: includeCaches, into: &items, totalBytes: &totalBytesToProcess)
                }
            }
        }

        // 2. Prepare Metadata Plist
        let record = BackupRecord(
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
        try await writeTarItem(path: "BackupMetadata.plist", size: Int64(metaData.count), typeflag: "0", mode: 0o644, to: gzip)
        try await gzip.write(data: metaData)
        let metaPad = (512 - (metaData.count % 512)) % 512
        if metaPad > 0 {
            try await gzip.write(data: Data(count: metaPad))
        }

        // Write Keychain items into tar stream (if enabled)
        if includeKeychain {
            let keychainItems = KeychainService.shared.dumpKeychainItems(for: app.bundleIdentifier)
            if !keychainItems.isEmpty, let kcData = try? encoder.encode(keychainItems) {
                try await writeTarItem(path: "KeychainItems.plist", size: Int64(kcData.count), typeflag: "0", mode: 0o644, to: gzip)
                try await gzip.write(data: kcData)
                let kcPad = (512 - (kcData.count % 512)) % 512
                if kcPad > 0 {
                    try await gzip.write(data: Data(count: kcPad))
                }
            }
        }

        // 4. Stream Source Files with Zero Memory/Staging Overhead
        var bytesProcessed: Int64 = 0
        let bufferSize = 65536 // 64 KB read buffer

        for item in items {
            if item.isDirectory {
                try await writeTarItem(path: item.archiveRelativePath, size: 0, typeflag: "5", mode: 0o755, to: gzip)
                continue
            }

            if item.isSymlink {
                try await writeTarItem(path: item.archiveRelativePath, size: 0, typeflag: "2", mode: item.mode, linkname: item.symlinkTarget, to: gzip)
                continue
            }

            guard let handle = try? FileHandle(forReadingFrom: item.diskURL) else { continue }

            do {
                defer { try? handle.close() }

                try await writeTarItem(path: item.archiveRelativePath, size: item.size, typeflag: "0", mode: item.mode, to: gzip)

                var fileBytesRead: Int64 = 0
                while fileBytesRead < item.size {
                    let toRead = Int(min(Int64(bufferSize), item.size - fileBytesRead))
                    guard let chunkData = try? handle.read(upToCount: toRead), !chunkData.isEmpty else {
                        break
                    }

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

                // Zero-pad if file was shorter than declared or couldn't be fully read
                var unreadRemaining = item.size - fileBytesRead
                let zeroChunkSize = 65536
                while unreadRemaining > 0 {
                    let toPad = min(Int64(zeroChunkSize), unreadRemaining)
                    try await gzip.write(data: Data(count: Int(toPad)))
                    unreadRemaining -= toPad
                }

                let pad = (512 - (Int(item.size) % 512)) % 512
                if pad > 0 {
                    try await gzip.write(data: Data(count: pad))
                }
            }
        }

        // 5. Write End-of-Archive (1024 null bytes / two zero blocks)
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
        var rootSt = stat()
        guard lstat(rootURL.path, &rootSt) == 0 else { return }

        let rootType = rootSt.st_mode & S_IFMT
        if rootType != S_IFDIR {
            if rootType == S_IFREG {
                let size = Int64(rootSt.st_size)
                items.append(StreamItem(
                    diskURL: rootURL,
                    archiveRelativePath: baseArchivePath,
                    isDirectory: false,
                    isSymlink: false,
                    symlinkTarget: "",
                    size: size,
                    mode: rootSt.st_mode
                ))
                totalBytes += size
            } else if rootType == S_IFLNK {
                var linkBuf = [CChar](repeating: 0, count: 1024)
                let linkLen = readlink(rootURL.path, &linkBuf, linkBuf.count - 1)
                let target = linkLen > 0 ? String(cString: linkBuf) : ""
                items.append(StreamItem(
                    diskURL: rootURL,
                    archiveRelativePath: baseArchivePath,
                    isDirectory: false,
                    isSymlink: true,
                    symlinkTarget: target,
                    size: 0,
                    mode: rootSt.st_mode
                ))
            }
            return
        }

        items.append(StreamItem(
            diskURL: rootURL,
            archiveRelativePath: baseArchivePath,
            isDirectory: true,
            isSymlink: false,
            symlinkTarget: "",
            size: 0,
            mode: rootSt.st_mode
        ))

        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: resourceKeys, options: [.skipsPackageDescendants]) else {
            return
        }

        let rootPath = rootURL.path

        for case let url as URL in enumerator {
            var subPath = url.path
            if subPath.hasPrefix(rootPath) {
                subPath.removeFirst(rootPath.count)
            }
            let cleanSubPath = subPath.hasPrefix("/") ? String(subPath.dropFirst()) : subPath

            if !includeCaches {
                if cleanSubPath.contains("Caches/") || cleanSubPath.contains("tmp/") || cleanSubPath.hasSuffix("/Caches") {
                    enumerator.skipDescendants()
                    continue
                }
            }

            var st = stat()
            guard lstat(url.path, &st) == 0 else { continue }
            let fileType = st.st_mode & S_IFMT

            // CRITICAL: Skip unix domain sockets, FIFOs, and character/block devices that crash or hang on read
            guard fileType == S_IFDIR || fileType == S_IFREG || fileType == S_IFLNK else { continue }

            let fullArchivePath = "\(baseArchivePath)/\(cleanSubPath)"

            if fileType == S_IFDIR {
                items.append(StreamItem(
                    diskURL: url,
                    archiveRelativePath: fullArchivePath,
                    isDirectory: true,
                    isSymlink: false,
                    symlinkTarget: "",
                    size: 0,
                    mode: st.st_mode
                ))
            } else if fileType == S_IFLNK {
                var linkBuf = [CChar](repeating: 0, count: 1024)
                let linkLen = readlink(url.path, &linkBuf, linkBuf.count - 1)
                let target = linkLen > 0 ? String(cString: linkBuf) : ""
                items.append(StreamItem(
                    diskURL: url,
                    archiveRelativePath: fullArchivePath,
                    isDirectory: false,
                    isSymlink: true,
                    symlinkTarget: target,
                    size: 0,
                    mode: st.st_mode
                ))
            } else {
                let fileSize = Int64(st.st_size)
                items.append(StreamItem(
                    diskURL: url,
                    archiveRelativePath: fullArchivePath,
                    isDirectory: false,
                    isSymlink: false,
                    symlinkTarget: "",
                    size: fileSize,
                    mode: st.st_mode
                ))
                totalBytes += fileSize
            }
        }
    }
}
