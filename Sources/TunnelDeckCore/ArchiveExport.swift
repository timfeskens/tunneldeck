import Foundation
import CZlib
import Darwin

/// Standard, unencrypted ZIP containing only selected .conf files. Secrets stay
/// in memory until the user explicitly saves; no shell or staging directory.
public enum ArchiveExport {
    public static func make(tunnels: [ImportedTunnel]) throws -> Data {
        guard !tunnels.isEmpty, tunnels.count <= 256 else {
            throw DeckError.message("Select between 1 and 256 tunnels to export.")
        }
        var archive = Data()
        var directory = Data()
        var used = Set<String>()
        var total = 0
        for tunnel in tunnels {
            let payload = Data(tunnel.text.utf8)
            total += payload.count
            guard !payload.isEmpty, payload.count <= 131_072, total <= 8 * 1024 * 1024 else {
                throw DeckError.message("The selected configurations are too large to export.")
            }
            _ = try WireGuardConfiguration(text: tunnel.text)
            let cleaned = tunnel.name.unicodeScalars.map { scalar -> String in
                CharacterSet.controlCharacters.contains(scalar) || "/\\:".unicodeScalars.contains(scalar) ? "_" : String(scalar)
            }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            let base = String(cleaned.drop(while: { $0 == "." }).prefix(80))
            let stem = base.isEmpty ? "Tunnel" : base
            var name = stem
            var suffix = 2
            while !used.insert(name.lowercased()).inserted {
                let ending = " (\(suffix))"
                name = String(stem.prefix(80 - ending.count)) + ending
                suffix += 1
            }
            let filename = Data((name + ".conf").utf8)
            let crc = payload.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(payload.count)) }
            let offset = archive.count
            // UTF-8 filenames, stored entries, fixed valid DOS date (1980-01-01).
            archive.zipNumber(0x04034b50, bytes: 4)
            for value in [20, 0x0800, 0, 0, 33] { archive.zipNumber(value, bytes: 2) }
            for value in [Int(crc), payload.count, payload.count] { archive.zipNumber(value, bytes: 4) }
            archive.zipNumber(filename.count, bytes: 2)
            archive.zipNumber(0, bytes: 2)
            archive.append(filename)
            archive.append(payload)

            directory.zipNumber(0x02014b50, bytes: 4)
            for value in [0x0314, 20, 0x0800, 0, 0, 33] { directory.zipNumber(value, bytes: 2) }
            for value in [Int(crc), payload.count, payload.count] { directory.zipNumber(value, bytes: 4) }
            for value in [filename.count, 0, 0, 0, 0] { directory.zipNumber(value, bytes: 2) }
            directory.zipNumber(0o100600 << 16, bytes: 4)
            directory.zipNumber(offset, bytes: 4)
            directory.append(filename)
        }
        let start = archive.count
        archive.append(directory)
        archive.zipNumber(0x06054b50, bytes: 4)
        for value in [0, 0, tunnels.count, tunnels.count] { archive.zipNumber(value, bytes: 2) }
        archive.zipNumber(directory.count, bytes: 4)
        archive.zipNumber(start, bytes: 4)
        archive.zipNumber(0, bytes: 2)
        return archive
    }

    /// Stage beside the destination with owner-only permissions, then rename
    /// atomically. Failure preserves any existing destination and removes staging.
    public static func write(_ archive: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".tunneldeck-export-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DeckError.message("Cannot create the export file in the selected folder.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        do {
            try handle.write(contentsOf: archive)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, destination.path) == 0 else {
                throw DeckError.message("Cannot save the export in the selected location.")
            }
        } catch {
            throw DeckError.message("Cannot save the export. Any existing destination file has been preserved.")
        }
    }
}

private extension Data {
    mutating func zipNumber(_ value: Int, bytes: Int) {
        for index in 0..<bytes { append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
    }
}
