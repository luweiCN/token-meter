import Foundation
import XCTest
@testable import TokenMeterCore

final class QoderUsageProviderTests: XCTestCase {
    func testParsesOfficialModelCatalogFromInitializeResponse() throws {
        let data = Data((
            #"{"type":"control_response","response":{"subtype":"success","request_id":"tokenmeter-initialize","response":{"models":[{"value":"qmodel_38max","displayName":"Qwen3.8-Max","modelId":"qmodel_38max","source":"system","isEnabled":true},{"value":"qfmodel","displayName":"Qwen3.8-Flash","modelId":"qfmodel","source":"system","isEnabled":true}]}}}"#
            + "\nSession hooks: ignored non-JSON output\n"
        ).utf8)

        let entries = try QoderModelCatalogParser.parse(data: data)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].value, "qmodel_38max")
        XCTAssertEqual(entries[0].displayName, "Qwen3.8-Max")
        XCTAssertEqual(entries[0].sourceModelIds, ["qmodel_38max"])
        XCTAssertEqual(entries[0].source, "system")
        XCTAssertEqual(entries[0].isEnabled, true)
    }

    func testParsesPlanAndAddonCreditsQuota() throws {
        let data = Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"tokenmeter-usage","response":{"usage":{"userQuota":{"total":300,"used":12.5,"remaining":287.5,"percentage":4.1666667,"unit":"credits"},"addOnQuota":{"total":100,"used":25,"remaining":75,"percentage":25,"unit":"credits"},"orgResourcePackage":{"used":40,"cap":200,"remaining":160,"percentage":20,"available":false,"unit":"credits"},"totalUsagePercentage":9.375,"isQuotaExceeded":false,"expiresAt":1790812800000}}}}"#.utf8)

        let snapshot = try QoderUsageParser.parse(
            data: data,
            providerId: "qoder",
            displayName: "Qoder",
            fetchedAt: Date(timeIntervalSince1970: 123)
        )

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.fetchedAt, Date(timeIntervalSince1970: 123))
        XCTAssertEqual(snapshot.groups.first?.subtitle, "Credits")
        let metrics = try XCTUnwrap(snapshot.groups.first?.items)
        XCTAssertEqual(metrics.map(\.label), ["套餐", "加购", "组织包"])
        XCTAssertEqual(try XCTUnwrap(metrics[0].remainingPercent), 95.8333333, accuracy: 0.000_001)
        XCTAssertEqual(metrics[1].remainingPercent, 75)
        XCTAssertNil(metrics[0].resetAt, "套餐到期时间不是 Credits 刷新时间，不得塞进重置倒计时位置")
        XCTAssertNil(metrics[0].resetText)
        XCTAssertEqual(metrics[0].detail, "12.5 / 300 Credits")
        XCTAssertEqual(metrics[1].detail, "25 / 100 Credits")
        XCTAssertEqual(metrics[2].remainingPercent, 80)
        XCTAssertEqual(metrics[2].status, .warning)
        XCTAssertEqual(metrics[2].detail, "已用 40 · 剩余 160 · 总额 200 Credits · 当前不可用")
        XCTAssertEqual(snapshot.summary, "套餐剩余 287.5 / 300 Credits · 加购剩余 75 / 100 Credits · 组织包剩余 160 / 200 Credits")
    }

    func testUsesNumericQuotaFieldsBeforeInconsistentPercentage() throws {
        let data = Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"tokenmeter-usage","response":{"usage":{"userQuota":{"total":300,"used":24,"remaining":276,"percentage":0.09}}}}}"#.utf8)

        let metric = try XCTUnwrap(
            QoderUsageParser.parse(data: data, providerId: "qoder", displayName: "Qoder")
                .groups.first?.items.first
        )

        XCTAssertEqual(metric.usedPercent, 8)
        XCTAssertEqual(metric.remainingPercent, 92)
    }

    func testExhaustedQuotaBecomesWarning() throws {
        let data = Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"tokenmeter-usage","response":{"usage":{"userQuota":{"total":300,"used":300,"remaining":0,"percentage":100},"isQuotaExceeded":true}}}}"#.utf8)
        let snapshot = try QoderUsageParser.parse(data: data, providerId: "qoder", displayName: "Qoder")
        XCTAssertEqual(snapshot.status, .warning)
        XCTAssertEqual(snapshot.message, "Credits 额度已用尽")
    }

    func testIgnoresOtherControlResponsesAndRejectsMissingUsage() {
        let data = Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"tokenmeter-initialize","response":{}}}"#.utf8)
        XCTAssertThrowsError(try QoderUsageParser.parse(data: data, providerId: "qoder", displayName: "Qoder")) {
            guard case QoderUsageParser.ParseError.missingUsageResponse = $0 else {
                return XCTFail("错误类型不符：\($0)")
            }
        }
    }

    func testResolvesVersionFileThenNewestExecutable() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmeter-qoder-provider-\(UUID().uuidString)", isDirectory: true)
        let directory = home.appendingPathComponent(".qoder-cn/bin/qoderclicn", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let older = directory.appendingPathComponent("qoderclicn-1.1.9")
        let newer = directory.appendingPathComponent("qoderclicn-1.1.58")
        try Data().write(to: older)
        try Data().write(to: newer)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newer.path)
        try Data("1.1.9\n".utf8).write(to: directory.appendingPathComponent("version.txt"))

        XCTAssertEqual(
            QoderUsageProvider.resolveExecutable(homeDirectory: home).map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            older.standardizedFileURL.path
        )
        try FileManager.default.removeItem(at: directory.appendingPathComponent("version.txt"))
        XCTAssertEqual(
            QoderUsageProvider.resolveExecutable(homeDirectory: home).map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            newer.standardizedFileURL.path
        )
    }
}
