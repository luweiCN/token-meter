import XCTest
@testable import TokenMeterCore

final class OpenCodeGoParserTests: XCTestCase {
    func testParsesSolidHydrationDashboardUsage() throws {
        let html = """
        <script>
        rollingUsage:$R[1]={usagePercent:20,resetInSec:3600}
        weeklyUsage:$R[2]={resetInSec:7200,usagePercent:35}
        monthlyUsage:$R[3]={usagePercent:60,resetInSec:2592000}
        </script>
        """

        let snapshot = try OpenCodeGoParser.parse(
            html: html,
            providerId: "opencode-go",
            displayName: "OpenCode Go"
        )

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.remaining, 80)
        XCTAssertEqual(snapshot.message, "5h 80% · Weekly 65% · Monthly 40%")
    }

    func testParsesDataSlotDashboardUsage() throws {
        let html = """
        <div data-slot="usage">
          <div data-slot="usage-item">
            <span data-slot="usage-label">Rolling Usage</span>
            <span data-slot="usage-value"><!--$-->12<!--/-->%</span>
            <span data-slot="reset-time"><!--$-->Resets in<!--/--> <!--$-->1 hour<!--/--></span>
          </div>
          <div data-slot="usage-item">
            <span data-slot="usage-label">Weekly Usage</span>
            <span data-slot="usage-value"><!--$-->68<!--/-->%</span>
            <span data-slot="reset-time"><!--$-->Resets in<!--/--> <!--$-->2 days<!--/--></span>
          </div>
          <div data-slot="usage-item">
            <span data-slot="usage-label">Monthly Usage</span>
            <span data-slot="usage-value"><!--$-->3<!--/-->%</span>
            <span data-slot="reset-now"><!--$-->reset-now<!--/--></span>
          </div>
        </div>
        """

        let snapshot = try OpenCodeGoParser.parse(
            html: html,
            providerId: "opencode-go",
            displayName: "OpenCode Go"
        )

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.remaining, 88)
        XCTAssertEqual(snapshot.message, "5h 88% · Weekly 32% · Monthly 97%")
    }

    func testParsesOpenCodeGoConfigFile() throws {
        let json = """
        {
          "workspaceId": "workspace-123",
          "authCookie": "cookie-abc"
        }
        """

        let config = try OpenCodeGoConfigParser.parse(Data(json.utf8))

        XCTAssertEqual(config.workspaceId, "workspace-123")
        XCTAssertEqual(config.authCookie, "cookie-abc")
    }
}
