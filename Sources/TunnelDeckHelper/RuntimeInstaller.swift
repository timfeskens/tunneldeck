import Foundation
import CryptoKit
import Darwin
import TunnelDeckCore

enum RuntimeInstaller {
    static let names = ["bash", "wg", "wg-quick", "wireguard-go"]

    static func install(helper: Helper) throws -> String? {
        let source = helper.dependencies.prefix
        let manifestPath = source + "/manifest.json"
        guard FileManager.default.fileExists(atPath: manifestPath) else {
            // Source-only development builds deliberately use Homebrew.
            guard ["/opt/homebrew", "/usr/local"].contains(source) else {
                throw DeckError.message("The bundled runtime manifest is missing. Download a fresh release.")
            }
            return nil
        }
        var manifestInfo = stat()
        guard lstat(manifestPath, &manifestInfo) == 0, manifestInfo.st_mode & S_IFMT == S_IFREG,
              manifestInfo.st_size > 0, manifestInfo.st_size <= 16_384 else {
            throw DeckError.message("Unsafe bundled runtime manifest.")
        }
        let manifestData = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        let manifest = try JSONDecoder().decode([String: String].self, from: manifestData)
        guard Set(manifest.keys) == Set(names), manifest.values.allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) else {
            throw DeckError.message("Invalid bundled runtime manifest.")
        }
        let identity = digest(manifestData)
        let root = ServiceIdentity.base + "/Runtimes"
        let target = root + "/" + identity
        try helper.ensureDirectory(root, mode: 0o755)
        try helper.ensureDirectory(target, mode: 0o755)
        try helper.ensureDirectory(target + "/bin", mode: 0o755)
        for name in names {
            let path = source + "/bin/" + name
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size < 100_000_000 else {
                throw DeckError.message("Unsafe or missing bundled runtime file.")
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard digest(data) == manifest[name] else {
                throw DeckError.message("Bundled runtime verification failed. Download a fresh release.")
            }
            let destination = target + "/bin/" + name
            // Never replace tools in use by existing wg-quick route monitors.
            if FileManager.default.fileExists(atPath: destination) {
                guard lstat(destination, &info) == 0, info.st_uid == 0,
                      info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o022 == 0,
                      info.st_mode & 0o111 != 0,
                      digest(try Data(contentsOf: URL(fileURLWithPath: destination))) == manifest[name] else {
                    throw DeckError.message("Installed runtime verification failed. No runtime files were replaced.")
                }
            } else {
                try helper.write(data, to: destination, mode: 0o755)
            }
        }
        return target
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
