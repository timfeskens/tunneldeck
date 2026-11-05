import Foundation
import CZlib

public struct ImportedTunnel: Sendable {
    public let name: String
    public let text: String
    public init(name: String, text: String) { self.name = name; self.text = text }
}

/// Bounded, in-memory ZIP reader for WireGuard exports. Never extracts files,
/// follows symlinks, invokes a shell, or writes imported secrets to disk.
public enum ArchiveImport {
    public static let maximumArchiveSize = 16 * 1024 * 1024
    private static let maximumConfigSize = 131_072
    private static let maximumTotalSize = 8 * 1024 * 1024

    public static func read(url: URL) throws -> [ImportedTunnel] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let limit = url.pathExtension.lowercased() == "zip" ? maximumArchiveSize : maximumConfigSize
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw DeckError.message("The selected file is too large to import.") }
        if url.pathExtension.lowercased() == "zip" { return try read(data: data) }
        return [try validated(name: url.deletingPathExtension().lastPathComponent, data: data)]
    }

    private static func validated(name: String, data: Data) throws -> ImportedTunnel {
        guard let text = String(data: data, encoding: .utf8) else { throw DeckError.message("A tunnel configuration is not UTF-8 text.") }
        // Names and file contents are untrusted: no raw parser/decoder errors or keys.
        _ = try WireGuardConfiguration(text: text)
        guard !name.isEmpty, name.count <= 80, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DeckError.message("A tunnel filename must contain a name of 1–80 characters.")
        }
        return ImportedTunnel(name: name, text: text)
    }

    public static func read(data: Data) throws -> [ImportedTunnel] {
        func invalid() -> DeckError { .message("This ZIP is damaged or uses an unsupported format. Choose a standard, unencrypted WireGuard ZIP export.") }
        guard data.count >= 22, data.count <= maximumArchiveSize else { throw invalid() }
        let bytes = [UInt8](data)
        func number(_ offset: Int, _ count: Int) throws -> Int {
            guard offset >= 0, count >= 0, offset <= bytes.count - count else { throw invalid() }
            return (0..<count).reduce(0) { $0 | Int(bytes[offset + $1]) << ($1 * 8) }
        }
        func slice(_ start: Int, _ size: Int, before end: Int) throws -> Data {
            guard start >= 0, size >= 0, start <= end, size <= end - start, end <= bytes.count else { throw invalid() }
            return Data(bytes[start..<(start + size)])
        }
        var endRecord: Int?
        for offset in stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1) {
            if try number(offset, 4) == 0x06054b50, offset + 22 + (try number(offset + 20, 2)) == bytes.count {
                endRecord = offset; break
            }
        }
        guard let endRecord,
              try number(endRecord + 4, 2) == 0, try number(endRecord + 6, 2) == 0,
              try number(endRecord + 8, 2) == number(endRecord + 10, 2) else { throw invalid() }
        let count = try number(endRecord + 10, 2)
        let directorySize = try number(endRecord + 12, 4)
        let directoryStart = try number(endRecord + 16, 4)
        guard count > 0, count <= 512, directoryStart + directorySize == endRecord else { throw invalid() }
        var cursor = directoryStart
        var names = Set<String>()
        var usedRanges: [Range<Int>] = []
        var imported: [ImportedTunnel] = []
        var totalSize = 0
        for _ in 0..<count {
            guard cursor + 46 <= endRecord, try number(cursor, 4) == 0x02014b50 else { throw invalid() }
            let flags = try number(cursor + 8, 2)
            let method = try number(cursor + 10, 2)
            let crc = try number(cursor + 16, 4)
            let compressedSize = try number(cursor + 20, 4)
            let size = try number(cursor + 24, 4)
            let nameSize = try number(cursor + 28, 2)
            let extraSize = try number(cursor + 30, 2)
            let commentSize = try number(cursor + 32, 2)
            let attributes = try number(cursor + 38, 4)
            let local = try number(cursor + 42, 4)
            guard try number(cursor + 34, 2) == 0,
                  let path = String(data: try slice(cursor + 46, nameSize, before: endRecord), encoding: .utf8) else { throw invalid() }
            cursor += 46 + nameSize + extraSize + commentSize
            guard cursor <= endRecord else { throw invalid() }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
                  !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !parts.contains(".."), !parts.contains("."),
                  names.insert(path.lowercased()).inserted, (attributes >> 16) & 0xf000 != 0xa000 else {
                throw DeckError.message("The ZIP contains unsafe paths, duplicate filenames, or symbolic links.")
            }
            // Finder metadata and unrelated files are not imported.
            guard !parts.contains("__MACOSX"), !parts.contains(where: { $0.hasPrefix(".") }),
                  path.lowercased().hasSuffix(".conf") else { continue }
            guard imported.count < 256, flags & 0x0041 == 0, [0, 8].contains(method), size > 0,
                  size <= maximumConfigSize, compressedSize <= maximumArchiveSize else { throw invalid() }
            totalSize += size
            guard totalSize <= maximumTotalSize, local + 30 <= directoryStart,
                  try number(local, 4) == 0x04034b50, try number(local + 6, 2) == flags,
                  try number(local + 8, 2) == method else { throw invalid() }
            let localNameSize = try number(local + 26, 2)
            let localExtraSize = try number(local + 28, 2)
            guard try slice(local + 30, localNameSize, before: directoryStart) == Data(path.utf8) else { throw invalid() }
            if flags & 8 == 0 {
                guard try number(local + 14, 4) == crc, try number(local + 18, 4) == compressedSize,
                      try number(local + 22, 4) == size else { throw invalid() }
            }
            let payloadStart = local + 30 + localNameSize + localExtraSize
            let payload = try slice(payloadStart, compressedSize, before: directoryStart)
            let range = local..<(payloadStart + compressedSize)
            guard !usedRanges.contains(where: { $0.overlaps(range) }) else { throw invalid() }
            usedRanges.append(range)
            let result: Data
            if method == 0 {
                guard compressedSize == size else { throw invalid() }
                result = payload
            } else {
                result = try inflate(payload, size: size)
            }
            let actualCRC = result.withUnsafeBytes { buffer in
                crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(result.count))
            }
            guard actualCRC == uLong(crc) else { throw invalid() }
            let filename = String(parts.last ?? "")
            imported.append(try validated(name: String(filename.dropLast(5)), data: result))
        }
        guard cursor == endRecord else { throw invalid() }
        guard !imported.isEmpty else { throw DeckError.message("No .conf tunnel configurations were found in this ZIP.") }
        return imported
    }

    private static func inflate(_ data: Data, size: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw DeckError.message("Cannot initialize ZIP decompression.")
        }
        defer { inflateEnd(&stream) }
        // One extra byte detects a stream larger than its declared size without
        // ever allocating unbounded decompression output.
        var output = Data(count: size + 1)
        let code = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(size + 1)
                return CZlib.inflate(&stream, Z_FINISH)
            }
        }
        guard code == Z_STREAM_END, stream.total_out == size, stream.total_in == data.count else {
            throw DeckError.message("The ZIP contains damaged or oversized compressed data.")
        }
        output.count = size
        return output
    }
}
