import Foundation

public struct Dependencies: Sendable {
    public let prefix: String
    public var bash: String { prefix + "/bin/bash" }
    public var wg: String { prefix + "/bin/wg" }
    public var quick: String { prefix + "/bin/wg-quick" }
    public var go: String { prefix + "/bin/wireguard-go" }
    public var missing: [String] {
        [("bash", bash), ("wireguard-tools (wg)", wg), ("wireguard-tools (wg-quick)", quick), ("wireguard-go", go)]
            .filter { !FileManager.default.isExecutableFile(atPath: $0.1) }.map(\.0)
    }
    public static func detect() -> Dependencies {
        // Release apps carry their own runtime. The daemon is given a root-owned,
        // content-addressed copy by the approved installer; never run an app's
        // user-writable runtime later from the background service.
        if let installed = ProcessInfo.processInfo.environment["TUNNELDECK_RUNTIME"],
           installed.hasPrefix(ServiceIdentity.base + "/Runtimes/") {
            return Dependencies(prefix: installed)
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let runtime = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Runtime").path
        if FileManager.default.fileExists(atPath: runtime) { return Dependencies(prefix: runtime) }
        let candidates = [Dependencies(prefix: "/opt/homebrew"), Dependencies(prefix: "/usr/local")]
        return candidates.first(where: { $0.missing.isEmpty }) ?? candidates[0]
    }
}
