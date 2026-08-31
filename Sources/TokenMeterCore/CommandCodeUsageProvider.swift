import Foundation

public struct CommandCodeUsageProvider: UsageProvider {
    public let id: String
    public let displayName: String

    private let config: ProviderConfig
    private let urlSession: URLSession
    private let environment: [String: String]
    private let authFileURL: URL
    private let keychainToken: (String) -> String?
    private let loginShellValue: (String) -> String?

    public init(
        config: ProviderConfig,
        urlSession: URLSession = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        authFileURL: URL? = nil,
        keychainToken: @escaping (String) -> String? = { KeychainCredentialStore.token(for: $0) },
        loginShellValue: ((String) -> String?)? = nil
    ) {
        self.config = config
        self.id = config.id
        self.displayName = config.displayName
        self.urlSession = urlSession
        self.environment = environment
        self.authFileURL = authFileURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".commandcode/auth.json")
        self.keychainToken = keychainToken
        self.loginShellValue = loginShellValue ?? { LoginShellEnvironment.value(for: $0) }
    }

    public func fetchUsage() async -> UsageSnapshot {
        await fetchProviderUsage().legacySnapshot
    }

    public func fetchProviderUsage() async -> ProviderUsageSnapshot {
        guard let endpoint = config.endpoint,
              let baseURL = URL(string: endpoint),
              baseURL.scheme == "https" else {
            return providerErrorSnapshot(
                providerId: id,
                displayName: displayName,
                message: "Command Code endpoint 缺失或不是 HTTPS"
            )
        }

        guard let apiKey = CommandCodeCredentialResolver.resolve(
            providerId: id,
            credential: config.credential,
            environment: environment,
            authFileURL: authFileURL,
            keychainToken: keychainToken,
            loginShellValue: loginShellValue
        ) else {
            return providerErrorSnapshot(
                providerId: id,
                displayName: displayName,
                message: "缺少 Command Code API Key：请在设置页粘贴，或配置 COMMAND_CODE_API_KEY"
            )
        }

        do {
            let whoAmIData = try? await requestData(
                baseURL: baseURL,
                path: "alpha/whoami",
                apiKey: apiKey
            )
            let orgId = whoAmIData.flatMap(CommandCodeWhoAmIParser.orgId)

            async let creditsRequest = requestData(
                baseURL: baseURL,
                path: "alpha/billing/credits",
                orgId: orgId,
                apiKey: apiKey
            )
            async let subscriptionRequest = requestData(
                baseURL: baseURL,
                path: "alpha/billing/subscriptions",
                orgId: orgId,
                apiKey: apiKey
            )

            let creditsData = try await creditsRequest
            let subscriptionData = try? await subscriptionRequest
            return try CommandCodeUsageParser.parse(
                creditsData: creditsData,
                subscriptionData: subscriptionData,
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

    private func requestData(
        baseURL: URL,
        path: String,
        orgId: String? = nil,
        apiKey: String
    ) async throws -> Data {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        if let orgId, !orgId.isEmpty {
            components?.queryItems = [URLQueryItem(name: "orgId", value: orgId)]
        }
        guard let url = components?.url else {
            throw CommandCodeAPIError.invalidEndpoint
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TokenMeter", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CommandCodeAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw CommandCodeAPIError.unauthorized
            }
            throw CommandCodeAPIError.httpStatus(httpResponse.statusCode)
        }
        return data
    }
}

enum CommandCodeCredentialResolver {
    private struct AuthFile: Decodable {
        let apiKey: String?
    }

    static func resolve(
        providerId: String,
        credential: CredentialConfig?,
        environment: [String: String],
        authFileURL: URL,
        keychainToken: (String) -> String?,
        loginShellValue: (String) -> String?
    ) -> String? {
        if let token = normalizedCredentialToken(keychainToken(providerId)) {
            return token
        }
        if let token = environmentCredentialToken(
            credential,
            environment: environment,
            loginShellValue: loginShellValue
        ) {
            return token
        }
        guard let data = try? Data(contentsOf: authFileURL),
              let auth = try? JSONDecoder().decode(AuthFile.self, from: data) else {
            return nil
        }
        return normalizedCredentialToken(auth.apiKey)
    }
}

enum CommandCodeWhoAmIParser {
    private struct Response: Decodable {
        struct Organization: Decodable {
            let id: String?
        }

        let org: Organization?
    }

    static func orgId(from data: Data) -> String? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            return nil
        }
        return normalizedCredentialToken(response.org?.id)
    }
}

public enum CommandCodeUsageParser {
    public enum ParseError: LocalizedError {
        case missingQuota

        public var errorDescription: String? {
            "Command Code 响应中没有可显示的额度"
        }
    }

    private struct CreditsResponse: Decodable {
        struct Credits: Decodable {
            let monthlyCredits: Double?
            let purchasedCredits: Double?
            let freeCredits: Double?
        }

        struct WindowLimits: Decodable {
            struct Window: Decodable {
                let used: Double?
                let cap: Double?
                let exceeded: Bool?
                let resetAt: Double?
            }

            let fiveHour: Window?
            let weekly: Window?
        }

        let credits: Credits?
        let windowLimits: WindowLimits?
    }

    private struct SubscriptionResponse: Decodable {
        struct Subscription: Decodable {
            let planId: String?
            let status: String?
            let currentPeriodEnd: String?
        }

        let data: Subscription?
    }

    /// Command Code CLI 1.38.2 的套餐身份映射。只在已知套餐上计算月度百分比；
    /// 新套餐未登记时宁可只显示服务端直接给出的 5h/7d，也不猜月度上限。
    private static let monthlyCreditsByPlanId: [String: Double] = [
        "individual-go": 10,
        "individual-goat": 70,
        "individual-pro": 30,
        "individual-pro-v1": 80,
        "individual-provider": 15,
        "individual-max": 150,
        "individual-ultra": 300,
        "teams-pro": 40,
    ]

    public static func parse(
        creditsData: Data,
        subscriptionData: Data?,
        providerId: String,
        displayName: String,
        now: Date = Date()
    ) throws -> ProviderUsageSnapshot {
        let decoder = JSONDecoder()
        let response = try decoder.decode(CreditsResponse.self, from: creditsData)
        let subscription = subscriptionData
            .flatMap { try? decoder.decode(SubscriptionResponse.self, from: $0).data }

        var metrics: [UsageMetric] = []
        if let fiveHour = response.windowLimits?.fiveHour,
           let metric = windowMetric(
               fiveHour,
               id: "\(providerId)-5h",
               label: "5h",
               durationMinutes: 300,
               now: now
           ) {
            metrics.append(metric)
        }
        if let weekly = response.windowLimits?.weekly,
           let metric = windowMetric(
               weekly,
               id: "\(providerId)-weekly",
               label: "7d",
               durationMinutes: 10_080,
               now: now
           ) {
            metrics.append(metric)
        }
        if let monthly = monthlyMetric(
            credits: response.credits,
            subscription: subscription,
            providerId: providerId,
            now: now
        ) {
            metrics.append(monthly)
        }

        guard !metrics.isEmpty else {
            throw ParseError.missingQuota
        }

        let summary = metrics.compactMap { metric -> String? in
            guard let remaining = metric.remainingPercent else { return nil }
            return "\(metric.label) \(Int(remaining.rounded()))%"
        }.joined(separator: " · ")

        return ProviderUsageSnapshot(
            providerId: providerId,
            displayName: displayName,
            status: .ok,
            fetchedAt: now,
            summary: summary,
            message: summary,
            groups: [
                UsageGroup(id: providerId, title: displayName, subtitle: nil, items: metrics)
            ]
        )
    }

    private static func windowMetric(
        _ window: CreditsResponse.WindowLimits.Window,
        id: String,
        label: String,
        durationMinutes: Int,
        now: Date
    ) -> UsageMetric? {
        guard let used = window.used,
              let cap = window.cap,
              used.isFinite,
              cap.isFinite,
              cap > 0 else {
            return nil
        }

        let usedPercent = clamp(used / cap * 100)
        let resetAt = date(fromEpochMilliseconds: window.resetAt)
        return UsageMetric(
            id: id,
            label: label,
            kind: .quota,
            usedPercent: usedPercent,
            remainingPercent: 100 - usedPercent,
            resetText: resetAt.map { countdownText(until: $0, now: now) },
            status: window.exceeded == true ? .error : .ok,
            detail: "\(money(max(0, used))) / \(money(cap))",
            resetAt: resetAt,
            windowDurationMinutes: durationMinutes
        )
    }

    private static func monthlyMetric(
        credits: CreditsResponse.Credits?,
        subscription: SubscriptionResponse.Subscription?,
        providerId: String,
        now: Date
    ) -> UsageMetric? {
        guard subscription?.status == "active",
              let planId = subscription?.planId,
              let limit = monthlyCreditLimit(planId: planId),
              let remaining = credits?.monthlyCredits,
              remaining.isFinite,
              limit > 0 else {
            return nil
        }

        let normalizedRemaining = max(0, remaining)
        let usedPercent = clamp((limit - normalizedRemaining) / limit * 100)
        let resetAt = subscription?.currentPeriodEnd.flatMap(date(fromISO8601:))
        var details = ["套餐余额 \(money(normalizedRemaining)) / \(money(limit))"]
        if let purchased = credits?.purchasedCredits, purchased > 0 {
            details.append("充值 \(money(purchased))")
        }
        if let free = credits?.freeCredits, free > 0 {
            details.append("赠送 \(money(free))")
        }

        return UsageMetric(
            id: "\(providerId)-monthly",
            label: "30d",
            kind: .quota,
            usedPercent: usedPercent,
            remainingPercent: 100 - usedPercent,
            resetText: resetAt.map { countdownText(until: $0, now: now) },
            status: .ok,
            detail: details.joined(separator: " · "),
            resetAt: resetAt,
            windowDurationMinutes: 43_200
        )
    }

    private static func monthlyCreditLimit(planId: String) -> Double? {
        let normalized = planId.lowercased().replacingOccurrences(of: "_", with: "-")
        return monthlyCreditsByPlanId
            .sorted { $0.key.count > $1.key.count }
            .first { normalized.hasPrefix($0.key) }?
            .value
    }

    private static func clamp(_ value: Double) -> Double {
        max(0, min(100, value))
    }

    private static func date(fromEpochMilliseconds value: Double?) -> Date? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value / 1_000)
    }

    private static func date(fromISO8601 value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func countdownText(until date: Date, now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        if seconds >= 86_400 {
            return "\(seconds / 86_400)d\((seconds % 86_400) / 3_600)h"
        }
        if seconds >= 3_600 {
            return "\(seconds / 3_600)h\((seconds % 3_600) / 60)m"
        }
        return "\(seconds / 60)m"
    }

    private static func money(_ value: Double) -> String {
        String(format: "$%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

private enum CommandCodeAPIError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case unauthorized
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Command Code endpoint 无效"
        case .invalidResponse:
            return "Command Code 接口响应无效"
        case .unauthorized:
            return "Command Code API Key 无效或已过期"
        case let .httpStatus(status):
            return "Command Code 额度接口返回 \(status)"
        }
    }
}
