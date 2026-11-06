import Foundation
import TunnelDeckCore

enum ServiceOperationError: LocalizedError {
    case uncertain
    var errorDescription: String? {
        "The service connection was interrupted. The update may still be finishing. Saved settings were retained; refresh and check this tunnel before retrying."
    }
}

enum PrivilegedClient {
    static func perform(action: String, request: HelperRequest) async throws -> HelperResponse {
        do { _ = try await call(action: "ping", request: HelperRequest(id: request.id)) }
        catch {
            try await install()
        }
        return try await call(action: action, request: request)
    }

    static func call(action: String, request: HelperRequest) async throws -> HelperResponse {
        // Pin the server too: a spoofed user Mach service must not receive keys.
        let binary = URL(fileURLWithPath: ServiceIdentity.binary)
        var info = stat()
        guard lstat(binary.path, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o022 == 0 else { throw DeckError.message("The root service needs to be installed or updated.") }
        let requirement = try ServiceIdentity.requirement(for: binary)
        let data = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: ServiceIdentity.name, options: .privileged)
            connection.setCodeSigningRequirement(requirement)
            connection.remoteObjectInterface = NSXPCInterface(with: TunnelServiceProtocol.self)
            let result = ServiceResult(connection: connection, continuation: continuation)
            let uncertainReplacement = action == "replace-configuration"
            connection.invalidationHandler = { result.finish(.failure(uncertainReplacement ? ServiceOperationError.uncertain : DeckError.message("The root service is unavailable or needs an approved update."))) }
            connection.interruptionHandler = { result.finish(.failure(uncertainReplacement ? ServiceOperationError.uncertain : DeckError.message("The root service restarted. Refresh the tunnel status before trying again."))) }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                result.finish(.failure(uncertainReplacement ? ServiceOperationError.uncertain : DeckError.message("The root service is unavailable or does not recognize this app build. Install or update it once.")))
            } as? TunnelServiceProtocol
            proxy?.perform(action, request: data) { response in
                guard let response = try? JSONDecoder().decode(HelperResponse.self, from: response) else {
                    result.finish(.failure(uncertainReplacement ? ServiceOperationError.uncertain : DeckError.message("Invalid service response."))); return
                }
                if response.success { result.finish(.success(response)) }
                else { result.finish(.failure(DeckError.message(response.message))) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + (action == "status" || action == "ping" ? 12 : 120)) {
                result.finish(.failure(uncertainReplacement ? ServiceOperationError.uncertain : DeckError.message("The service did not respond in time. The operation may still be finishing; refresh before trying again.")))
            }
        }
    }

    static func install() async throws {
        try await Task.detached(priority: .userInitiated) {
            guard let executable = Bundle.main.executableURL else { throw DeckError.message("Cannot locate the app bundle.") }
            let helper = executable.deletingLastPathComponent().appendingPathComponent("TunnelDeckHelper")
            guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                throw DeckError.message("Helper is missing. Build and launch dist/TunnelDeck.app using scripts/build.sh.")
            }
            // mkdtemp creates a private, nonpredictable 0700 request directory.
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("tunneldeck-XXXXXX").path
            var template = Array(temporary.utf8CString)
            guard mkdtemp(&template) != nil else { throw DeckError.message("Cannot create a private request directory.") }
            let directory = URL(fileURLWithPath: String(cString: template))
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("request.json")
            let data = try JSONEncoder().encode(HelperRequest(id: UUID()))
            guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw DeckError.message("Cannot create a private authorization request.")
            }
            let command = [helper.path, "install-service", String(getuid()), file.path].map(ShellQuoting.quote).joined(separator: " ")
            // Only a fixed helper path, operation, numeric UID and generated file path
            // enter AppleScript. Private configuration never enters process arguments.
            let script = "do shell script \(ShellQuoting.appleScriptString(command)) with administrator privileges with prompt \(ShellQuoting.appleScriptString("Install or update TunnelDeck’s root service once to control tunnels without repeated password prompts."))"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let result = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let diagnostic = String(decoding: errorData, as: UTF8.self)
                if diagnostic.contains("-128") { throw DeckError.message("Administrator authorization was cancelled.") }
                throw DeckError.message("macOS could not complete the authorized operation. Refresh the tunnel status before trying again.")
            }
            guard let response = try? JSONDecoder().decode(HelperResponse.self, from: result) else {
                throw DeckError.message("The helper returned an unexpected response. Refresh to check the tunnel before trying again.")
            }
            guard response.success else { throw DeckError.message(response.message) }
        }.value
    }
}

private final class ServiceResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HelperResponse, Error>?
    private let connection: NSXPCConnection
    init(connection: NSXPCConnection, continuation: CheckedContinuation<HelperResponse, Error>) {
        self.connection = connection; self.continuation = continuation
    }
    func finish(_ result: Result<HelperResponse, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        connection.invalidationHandler = nil
        connection.interruptionHandler = nil
        connection.invalidate()
        pending.resume(with: result)
    }
}
