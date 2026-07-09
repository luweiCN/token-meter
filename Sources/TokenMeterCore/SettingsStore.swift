import Foundation

public final class SettingsStore {
    private let database: SQLiteDatabase
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func importConfigIfNeeded(_ config: TokenMeterConfig) throws {
        let count = try database.query("SELECT count(*) AS count FROM settings")[0].int("count") ?? 0
        guard count == 0 else { return }

        try database.execute("BEGIN IMMEDIATE")
        do {
            try set("menuBar.primaryProviderId", value: .text(config.menuBar.primaryProviderId ?? ""), version: 1, updatedBy: .importer)
            try set("scan.autoRefreshSeconds", value: .int(300), version: 1, updatedBy: .importer)
            try setJSON("filters.enabledAgentKinds", json: jsonString(["claudeCode", "codex", "opencode", "omp"]), version: 1, updatedBy: .importer)
            for (index, provider) in config.providers.enumerated() {
                try database.execute(
                    """
                    INSERT OR REPLACE INTO provider_config_overrides(
                        provider_id,
                        enabled,
                        display_name,
                        menu_rank,
                        show_in_menu_bar,
                        show_in_charts
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(provider.id),
                        .int(provider.enabled ? 1 : 0),
                        .text(provider.displayName),
                        .int(Int64(index)),
                        .int(provider.enabled ? 1 : 0),
                        .int(provider.enabled ? 1 : 0)
                    ]
                )
            }
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    public func snapshot() throws -> SettingsSnapshot {
        let version = Int(try database.query("SELECT coalesce(max(version), 0) AS version FROM settings")[0].int("version") ?? 0)
        let primaryProviderId = try settingString("menuBar.primaryProviderId")
        let autoRefreshSeconds = Int(try settingInt("scan.autoRefreshSeconds") ?? 300)
        let enabledAgentKinds = try settingStringArray("filters.enabledAgentKinds") ?? []
        let providerRows = try database.query(
            """
            SELECT provider_id, enabled, display_name, menu_rank, show_in_menu_bar, show_in_charts
            FROM provider_config_overrides
            ORDER BY menu_rank ASC, provider_id ASC
            """
        )
        let providerOverrides = providerRows.map { row in
            ProviderConfigOverride(
                providerId: row.string("provider_id") ?? "",
                enabled: row.int("enabled").map { $0 == 1 },
                displayName: row.string("display_name"),
                menuRank: row.int("menu_rank").map(Int.init),
                showInMenuBar: row.int("show_in_menu_bar").map { $0 == 1 },
                showInCharts: row.int("show_in_charts").map { $0 == 1 }
            )
        }

        return SettingsSnapshot(
            version: version,
            menuBarPrimaryProviderId: primaryProviderId?.isEmpty == true ? nil : primaryProviderId,
            autoRefreshSeconds: autoRefreshSeconds,
            enabledAgentKinds: enabledAgentKinds,
            providerOverrides: providerOverrides
        )
    }

    public func apply(
        _ patch: SettingsPatch,
        expectedVersion: Int,
        updatedBy: SettingsUpdatedBy
    ) throws -> SettingsApplyRequest {
        guard patch.hasChanges else {
            throw SettingsStoreError.invalidValue("settings patch must change at least one setting")
        }
        let nextVersion = expectedVersion + 1

        try database.execute("BEGIN IMMEDIATE")
        do {
            let currentVersion = try settingsVersion()
            guard currentVersion == expectedVersion else {
                throw SettingsStoreError.staleVersion(expected: expectedVersion, actual: currentVersion)
            }
            if let primaryProviderId = patch.menuBarPrimaryProviderId {
                try set("menuBar.primaryProviderId", value: .text(primaryProviderId), version: nextVersion, updatedBy: updatedBy)
            }
            if let autoRefreshSeconds = patch.autoRefreshSeconds {
                guard autoRefreshSeconds >= 30 else {
                    throw SettingsStoreError.invalidValue("scan.autoRefreshSeconds must be >= 30")
                }
                try set("scan.autoRefreshSeconds", value: .int(Int64(autoRefreshSeconds)), version: nextVersion, updatedBy: updatedBy)
            }
            if let enabledAgentKinds = patch.enabledAgentKinds {
                try validateEnabledAgentKinds(enabledAgentKinds)
                try setJSON("filters.enabledAgentKinds", json: jsonString(enabledAgentKinds), version: nextVersion, updatedBy: updatedBy)
            }
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }

        return SettingsApplyRequest(requestedVersion: nextVersion, status: "pending")
    }

    private func settingsVersion() throws -> Int {
        Int(try database.query("SELECT coalesce(max(version), 0) AS version FROM settings")[0].int("version") ?? 0)
    }

    private func set(_ key: String, value: SQLiteValue, version: Int, updatedBy: SettingsUpdatedBy) throws {
        let valueJSON: String
        let valueType: String
        switch value {
        case let .text(text):
            valueJSON = jsonString(text)
            valueType = "string"
        case let .int(int):
            valueJSON = String(int)
            valueType = "int"
        case let .double(double):
            valueJSON = String(double)
            valueType = "int"
        case .null:
            valueJSON = "null"
            valueType = "json"
        }
        try database.execute(
            """
            INSERT OR REPLACE INTO settings(key, value_json, value_type, version, updated_by)
            VALUES (?, ?, ?, ?, ?)
            """,
            [.text(key), .text(valueJSON), .text(valueType), .int(Int64(version)), .text(updatedBy.rawValue)]
        )
    }

    private func setJSON(_ key: String, json: String, version: Int, updatedBy: SettingsUpdatedBy) throws {
        try database.execute(
            """
            INSERT OR REPLACE INTO settings(key, value_json, value_type, version, updated_by)
            VALUES (?, ?, ?, ?, ?)
            """,
            [.text(key), .text(json), .text("json"), .int(Int64(version)), .text(updatedBy.rawValue)]
        )
    }

    private func settingString(_ key: String) throws -> String? {
        guard let row = try database.query(
            "SELECT value_json, value_type FROM settings WHERE key = ?",
            [.text(key)]
        ).first else { return nil }
        guard row.string("value_type") == "string", let value = row.string("value_json") else {
            throw SettingsStoreError.invalidStoredValue(key)
        }
        do {
            return try decoder.decode(String.self, from: Data(value.utf8))
        } catch {
            throw SettingsStoreError.invalidStoredValue(key)
        }
    }

    private func settingInt(_ key: String) throws -> Int64? {
        guard let row = try database.query(
            "SELECT value_json, value_type FROM settings WHERE key = ?",
            [.text(key)]
        ).first else { return nil }
        guard row.string("value_type") == "int",
              let rawValue = row.string("value_json"),
              let value = Int64(rawValue) else {
            throw SettingsStoreError.invalidStoredValue(key)
        }
        return value
    }

    private func settingStringArray(_ key: String) throws -> [String]? {
        guard let row = try database.query(
            "SELECT value_json, value_type FROM settings WHERE key = ?",
            [.text(key)]
        ).first else { return nil }
        guard row.string("value_type") == "json", let value = row.string("value_json") else {
            throw SettingsStoreError.invalidStoredValue(key)
        }
        do {
            let values = try decoder.decode([String].self, from: Data(value.utf8))
            if key == "filters.enabledAgentKinds" {
                try validateEnabledAgentKinds(values)
            }
            return values
        } catch let error as SettingsStoreError {
            throw error
        } catch {
            throw SettingsStoreError.invalidStoredValue(key)
        }
    }

    private func validateEnabledAgentKinds(_ values: [String]) throws {
        let supported = Set(LocalAgentKind.allCases.map(\.rawValue))
        guard values.allSatisfy({ supported.contains($0) }) else {
            throw SettingsStoreError.invalidValue("filters.enabledAgentKinds contains unsupported agent kind")
        }
    }

    private func jsonString<T: Encodable>(_ value: T) -> String {
        let data = (try? encoder.encode(value)) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeStringArray(_ json: String) -> [String] {
        (try? decoder.decode([String].self, from: Data(json.utf8))) ?? []
    }
}
