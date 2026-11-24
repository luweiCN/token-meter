import Foundation

public struct QoderUsageProvider: UsageProvider {
    public let id: String
    public let displayName: String

    private let executableResolver: () -> String?
    private let commandRunner: (String) throws -> Data

    public init(config: ProviderConfig) {
        self.id = config.id
        self.displayName = config.displayName
        self.executableResolver = {
            Self.resolveExecutable(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        }
        self.commandRunner = { executable in
            try Self.fetchUsageData(executable: executable)
        }
    }

    init(
        config: ProviderConfig,
        executableResolver: @escaping () -> String?,
        commandRunner: @escaping (String) throws -> Data
    ) {
        self.id = config.id
        self.displayName = config.displayName
        self.executableResolver = executableResolver
        self.commandRunner = commandRunner
    }

    public func fetchUsage() async -> UsageSnapshot {
        await fetchProviderUsage().legacySnapshot
    }

    public func fetchProviderUsage() async -> ProviderUsageSnapshot {
        guard let executable = executableResolver() else {
            return providerErrorSnapshot(
                providerId: id,
                displayName: displayName,
                message: "未检测到 Qoder CLI，无法读取 Credits 额度"
            )
        }

        do {
            let data = try await Task.detached {
                try commandRunner(executable)
            }.value
            return try QoderUsageParser.parse(
                data: data,
                providerId: id,
                displayName: displayName
            )
        } catch {
            return providerErrorSnapshot(
                providerId: id,
                displayName: displayName,
                message: ProviderErrorMessage.sanitized(
                    providerName: displayName,
                    errorMessage: error.localizedDescription
                )
            )
        }
    }

    static func resolveExecutable(
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> String? {
        let directory = homeDirectory
            .appendingPathComponent(".qoder-cn", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("qoderclicn", isDirectory: true)

        let versionURL = directory.appendingPathComponent("version.txt")
        if let rawVersion = try? String(contentsOf: versionURL, encoding: .utf8) {
            let version = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            if !version.isEmpty,
               version.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }) {
                let candidate = directory.appendingPathComponent("qoderclicn-\(version)").path
                if fileManager.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        let candidates = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return candidates
            .filter {
                $0.lastPathComponent.hasPrefix("qoderclicn-")
                    && fileManager.isExecutableFile(atPath: $0.path)
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            .first?
            .path
    }

    static func fetchUsageData(executable: String, timeout: TimeInterval = 10) throws -> Data {
        let requests = [
            #"{"type":"control_request","request_id":"tokenmeter-initialize","request":{"subtype":"initialize","hooks":{},"sdkMcpServers":[]}}"#,
            #"{"type":"control_request","request_id":"tokenmeter-usage","request":{"subtype":"get_usage_info"}}"#
        ].joined(separator: "\n") + "\n"

        return try runProcess(
            executable: executable,
            arguments: [
                "--print",
                "--input-format", "stream-json",
                "--output-format", "stream-json",
                "--no-session-persistence",
                "--tools", ""
            ],
            input: Data(requests.utf8),
            timeout: timeout
        )
    }

    /// Qoder 的模型代号是服务端目录，不能在 TokenMeter 里硬编码。initialize 控制响应
    /// 与官方 SDK `getAvailableModels()` 同源，提供 value / modelId / displayName。
    static func fetchModelCatalogData(executable: String, timeout: TimeInterval = 10) throws -> Data {
        let request = #"{"type":"control_request","request_id":"tokenmeter-initialize","request":{"subtype":"initialize","hooks":{},"sdkMcpServers":[]}}"# + "\n"
        return try runProcess(
            executable: executable,
            arguments: [
                "--print",
                "--input-format", "stream-json",
                "--output-format", "stream-json",
                "--no-session-persistence",
                "--tools", ""
            ],
            input: Data(request.utf8),
            timeout: timeout
        )
    }
}

struct QoderModelCatalogEntry: Equatable {
    let value: String
    let modelId: String?
    let displayName: String
    let source: String?
    let isEnabled: Bool?

    /// `value` 是 SDK 选模与会话日志的首选身份；若官方另给不同的 modelId，也把它
    /// 作为同一展示名的可验证别名，避免依赖两者永远相等的偶然事实。
    var sourceModelIds: [String] {
        var values = [value]
        if let modelId, modelId != value { values.append(modelId) }
        return values
    }
}

enum QoderModelCatalogParser {
    enum ParseError: LocalizedError {
        case failedResponse(String)
        case missingInitializeResponse
        case missingModels

        var errorDescription: String? {
            switch self {
            case let .failedResponse(message): return message
            case .missingInitializeResponse: return "Qoder CLI 未返回模型目录响应"
            case .missingModels: return "Qoder CLI 初始化响应中没有模型目录"
            }
        }
    }

    static func parse(data: Data) throws -> [QoderModelCatalogEntry] {
        let decoder = JSONDecoder()
        for rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let envelope = try? decoder.decode(ControlEnvelope.self, from: Data(rawLine)),
                  envelope.type == "control_response",
                  let control = envelope.response,
                  control.requestId == "tokenmeter-initialize" else {
                continue
            }
            guard control.subtype == "success" else {
                throw ParseError.failedResponse(control.error?.nonEmpty ?? "Qoder CLI 返回模型目录读取失败")
            }
            let entries = (control.payload?.models ?? []).compactMap { model -> QoderModelCatalogEntry? in
                guard let value = model.value?.nonEmpty,
                      let displayName = model.displayName?.nonEmpty else { return nil }
                return QoderModelCatalogEntry(
                    value: value,
                    modelId: model.modelId?.nonEmpty,
                    displayName: displayName,
                    source: model.source?.nonEmpty,
                    isEnabled: model.isEnabled
                )
            }
            guard !entries.isEmpty else { throw ParseError.missingModels }
            return entries
        }
        throw ParseError.missingInitializeResponse
    }

    private struct ControlEnvelope: Decodable {
        let type: String?
        let response: ControlResponse?
    }

    private struct ControlResponse: Decodable {
        let subtype: String?
        let requestId: String?
        let payload: Payload?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case subtype
            case requestId = "request_id"
            case payload = "response"
            case error
        }
    }

    private struct Payload: Decodable {
        let models: [Model]?
    }

    private struct Model: Decodable {
        let value: String?
        let displayName: String?
        let modelId: String?
        let source: String?
        let isEnabled: Bool?
    }
}

public enum QoderUsageParser {
    public enum ParseError: LocalizedError {
        case failedResponse(String)
        case missingUsageResponse
        case missingQuota

        public var errorDescription: String? {
            switch self {
            case let .failedResponse(message):
                return message
            case .missingUsageResponse:
                return "Qoder CLI 未返回 Credits 额度响应"
            case .missingQuota:
                return "Qoder CLI 响应中没有可用的 Credits 额度字段"
            }
        }
    }

    public static func parse(
        data: Data,
        providerId: String,
        displayName: String,
        fetchedAt: Date = Date()
    ) throws -> ProviderUsageSnapshot {
        let decoder = JSONDecoder()
        for rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let envelope = try? decoder.decode(ControlEnvelope.self, from: Data(rawLine)),
                  envelope.type == "control_response",
                  let control = envelope.response,
                  control.requestId == "tokenmeter-usage" else {
                continue
            }

            guard control.subtype == "success" else {
                throw ParseError.failedResponse(
                    control.error?.nonEmpty ?? "Qoder CLI 返回额度读取失败"
                )
            }
            guard let usage = control.payload?.usage else {
                throw ParseError.missingQuota
            }

            var metrics: [UsageMetric] = []
            var summaryParts: [String] = []
            if let quota = usage.userQuota {
                metrics.append(metric(
                    quota: quota,
                    id: "\(providerId)-plan",
                    label: "套餐",
                    usesRingDetail: true
                ))
                summaryParts.append(summaryPart(label: "套餐", quota: quota))
            }
            if let quota = usage.addOnQuota {
                metrics.append(metric(
                    quota: quota,
                    id: "\(providerId)-addon",
                    label: "加购",
                    usesRingDetail: true
                ))
                summaryParts.append(summaryPart(label: "加购", quota: quota))
            }
            if let organization = usage.orgResourcePackage {
                let quota = Quota(
                    total: organization.cap,
                    used: organization.used,
                    remaining: organization.remaining,
                    percentage: organization.percentage,
                    unit: organization.unit
                )
                metrics.append(metric(
                    quota: quota,
                    id: "\(providerId)-organization",
                    label: "组织包",
                    status: organization.available == false ? .warning : .ok,
                    detailSuffix: organization.available == false ? "当前不可用" : nil
                ))
                summaryParts.append(summaryPart(label: "组织包", quota: quota))
            }
            guard !metrics.isEmpty else {
                throw ParseError.missingQuota
            }

            let exceeded = usage.isQuotaExceeded == true
            return ProviderUsageSnapshot(
                providerId: providerId,
                displayName: displayName,
                status: exceeded ? .warning : .ok,
                fetchedAt: fetchedAt,
                summary: summaryParts.joined(separator: " · "),
                message: exceeded ? "Credits 额度已用尽" : nil,
                groups: [
                    UsageGroup(
                        id: providerId,
                        title: displayName,
                        subtitle: "Credits",
                        items: metrics
                    )
                ]
            )
        }

        throw ParseError.missingUsageResponse
    }

    private static func metric(
        quota: Quota,
        id: String,
        label: String,
        usesRingDetail: Bool = false,
        status: UsageStatus = .ok,
        detailSuffix: String? = nil
    ) -> UsageMetric {
        // CLI 的 wire response 已把 percentage 归一为 0...100；有原始数值时仍优先
        // 自行计算，避免上游 percentage 与 used / total 短暂不同步。
        let usedPercent = percentage(part: quota.used, total: quota.total) ?? quota.percentage
        let remainingPercent = percentage(part: quota.remaining, total: quota.total)
            ?? usedPercent.map { max(0, 100 - $0) }
        let quotaDetail = usesRingDetail ? ringDetail(quota) : detail(quota)
        let detailParts = [quotaDetail, detailSuffix].compactMap { $0 }
        return UsageMetric(
            id: id,
            label: label,
            kind: .quota,
            usedPercent: usedPercent.map(clampPercent),
            remainingPercent: remainingPercent.map(clampPercent),
            resetText: nil,
            status: status,
            detail: detailParts.isEmpty ? nil : detailParts.joined(separator: " · "),
            resetAt: nil,
            windowDurationMinutes: nil
        )
    }

    private static func summaryPart(label: String, quota: Quota) -> String {
        if let remaining = quota.remaining, let total = quota.total {
            return "\(label)剩余 \(number(remaining)) / \(number(total)) Credits"
        }
        if let remaining = quota.remaining {
            return "\(label)剩余 \(number(remaining)) Credits"
        }
        if let used = quota.used, let total = quota.total {
            return "\(label)已用 \(number(used)) / \(number(total)) Credits"
        }
        return "\(label)额度"
    }

    private static func detail(_ quota: Quota) -> String? {
        var parts: [String] = []
        if let used = quota.used {
            parts.append("已用 \(number(used))")
        }
        if let remaining = quota.remaining {
            parts.append("剩余 \(number(remaining))")
        }
        if let total = quota.total {
            parts.append("总额 \(number(total))")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ") + " Credits"
    }

    /// 圆环已经表达剩余百分比，文字只补充无法从环上读出的已用与总额。
    /// 优先使用服务端的 used；若只给 remaining + total，二者差值仍是同一额度契约内
    /// 可验证的已用值。单位由所在 UsageGroup 的 Credits 语境给出。
    private static func ringDetail(_ quota: Quota) -> String? {
        if let total = quota.total {
            if let used = quota.used {
                return "\(number(used)) / \(number(total)) Credits"
            }
            if let remaining = quota.remaining {
                return "\(number(max(0, total - remaining))) / \(number(total)) Credits"
            }
            return "总额 \(number(total)) Credits"
        }
        if let used = quota.used {
            return "已用 \(number(used)) Credits"
        }
        return nil
    }

    private static func percentage(part: Double?, total: Double?) -> Double? {
        guard let part, let total, total > 0 else { return nil }
        return part / total * 100
    }

    private static func clampPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    private static func number(_ value: Double) -> String {
        UsageFormatter.numberText(value)
    }

    private struct ControlEnvelope: Decodable {
        let type: String?
        let response: ControlResponse?
    }

    private struct ControlResponse: Decodable {
        let subtype: String?
        let requestId: String?
        let payload: Payload?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case subtype
            case requestId = "request_id"
            case payload = "response"
            case error
        }
    }

    private struct Payload: Decodable {
        let usage: Usage?
    }

    private struct Usage: Decodable {
        let isQuotaExceeded: Bool?
        let expiresAt: Double?
        let userQuota: Quota?
        let addOnQuota: Quota?
        let orgResourcePackage: OrgResourcePackage?
    }

    private struct Quota: Decodable {
        let total: Double?
        let used: Double?
        let remaining: Double?
        let percentage: Double?
        let unit: String?
    }

    private struct OrgResourcePackage: Decodable {
        let used: Double?
        let cap: Double?
        let remaining: Double?
        let percentage: Double?
        let available: Bool?
        let unit: String?
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
