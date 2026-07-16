import XCTest
@testable import TokenMeterCore

final class ProviderSnapshotRenameTests: XCTestCase {
    private func snapshot(displayName: String, groupTitles: [String]) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            providerId: "codex",
            displayName: displayName,
            status: .ok,
            fetchedAt: Date(timeIntervalSince1970: 100),
            summary: "7d 78%",
            message: nil,
            groups: groupTitles.enumerated().map { index, title in
                UsageGroup(id: "g\(index)", title: title, subtitle: nil, items: [])
            }
        )
    }

    func testRenamesDisplayNameAndSameNamedPrimaryGroupTogether() {
        // 主组判定是 group.title == displayName（QuotaDisplayModel.isPrimary），
        // 别名必须两处同步换，否则改名后主组降级成次要组。
        let original = snapshot(displayName: "Codex", groupTitles: ["Codex", "GPT-5.3-Codex-Spark"])

        let renamed = original.renamed(to: "Codex CLI")

        XCTAssertEqual(renamed.displayName, "Codex CLI")
        XCTAssertEqual(renamed.groups.map(\.title), ["Codex CLI", "GPT-5.3-Codex-Spark"])
        XCTAssertEqual(renamed.providerId, original.providerId)
        XCTAssertEqual(renamed.summary, original.summary)
        XCTAssertEqual(renamed.fetchedAt, original.fetchedAt)
    }

    func testEmptyOrSameNameIsIdentity() {
        let original = snapshot(displayName: "Codex", groupTitles: ["Codex"])

        XCTAssertEqual(original.renamed(to: ""), original)
        XCTAssertEqual(original.renamed(to: "Codex"), original)
    }
}
