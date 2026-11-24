import Darwin
import Foundation
import TokenMeterCore

struct AntigravityStatusLine {
    static let marker = " # tokenmeter-antigravity"
    let executable: URL
    var home = FileManager.default.homeDirectoryForCurrentUser

    func setEnabled(_ enabled: Bool) throws {
        let cache = AntigravityQuota.cacheURL(home: home)
        let connection = AntigravityQuota.connectionURL(for: cache)
        let files = FileManager.default
        guard enabled || files.fileExists(atPath: connection.path) else { return }
        let settings = home.appendingPathComponent(".gemini/antigravity-cli/settings.json").resolvingSymlinksInPath()
        try AntigravityQuota.withCacheLock(at: cache) {
            let before = try files.fileExists(atPath: settings.path) ? Data(contentsOf: settings) : nil
            var document = try before.map(Self.dictionary) ?? [:]
            let current = document["statusLine"] as? [String: Any] ?? [:]
            let command = current["command"] as? String ?? ""
            let owned = command.hasSuffix(Self.marker)
            let backup = try files.fileExists(atPath: connection.path) ? Self.dictionary(Data(contentsOf: connection)) : nil
            if enabled {
                if owned, backup == nil {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let original: Any = owned ? (backup?["original"] ?? NSNull()) : (document["statusLine"] ?? NSNull())
                var line = (owned ? current : original as? [String: Any]) ?? [:]
                let prior = original as? [String: Any] ?? [:]
                let custom = prior["command"] as? String ?? ""
                let helper = "'" + executable.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "' " + AntigravityQuota.captureArgument
                if !custom.isEmpty && prior["enabled"] as? Bool != false {
                    line["command"] = helper + " --passthrough | (\n" + custom + "\n)" + Self.marker
                } else {
                    line["command"] = helper + Self.marker
                    line["stack_with_default"] = true
                }
                line["enabled"] = true
                line["type"] = "command"
                if owned && NSDictionary(dictionary: current).isEqual(to: line) { return }
                try AntigravityQuota.writePrivate(JSONSerialization.data(withJSONObject: ["original": original]), to: connection)
                document["statusLine"] = line
            } else {
                if owned {
                    guard let original = backup?["original"] else { throw CocoaError(.fileReadCorruptFile) }
                    var restored = current
                    let prior = original as? [String: Any] ?? [:]
                    for key in ["command", "enabled", "type"] { restored[key] = prior[key] }
                    if (prior["command"] as? String ?? "").isEmpty || prior["enabled"] as? Bool == false {
                        restored["stack_with_default"] = prior["stack_with_default"]
                    }
                    document["statusLine"] = restored.isEmpty && !(original is [String: Any])
                        ? (original is NSNull ? nil : original) : restored
                }
            }
            if enabled || owned {
                try files.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
                let latest = try files.fileExists(atPath: settings.path) ? Data(contentsOf: settings) : nil
                guard latest == before else { throw CocoaError(.fileWriteFileExists) }
                let bytes = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                try AntigravityQuota.writePrivate(bytes, to: settings)
            }
            if !enabled {
                for url in [connection, cache] where files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
            }
        }
    }

    private static func dictionary(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }

    /// Forward the original bytes to a pre-existing custom status line, including oversized payloads.
    static func captureInput(passthrough: Bool) {
        let input = FileHandle.standardInput
        var bytes = Data()
        var oversized = false
        var forwarding = passthrough
        // A custom command may display its own text and exit without reading stdin.
        if forwarding { signal(SIGPIPE, SIG_IGN) }
        do {
            while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                if forwarding {
                    do { try FileHandle.standardOutput.write(contentsOf: chunk) }
                    catch { forwarding = false }
                }
                if bytes.count + chunk.count > 512 * 1024 { oversized = true }
                if !oversized { bytes.append(chunk) }
            }
            guard !oversized, try AntigravityQuota.capture(bytes, at: AntigravityQuota.cacheURL()) else { return }
            DistributedNotificationCenter.default().postNotificationName(AntigravityQuota.changed,
                object: nil, userInfo: nil, deliverImmediately: true)
        } catch {
            // Capture is optional; a failure must not disable the user's terminal status line.
        }
    }
}
