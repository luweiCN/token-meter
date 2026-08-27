import XCTest
@testable import TokenMeterCore

final class GrokCreditsGrpcParserTests: XCTestCase {
    func testFramedFractionBecomesPercentAndReset() throws {
        var config = Data()
        appendFixed32(field: 1, float: 0.51, to: &config)
        appendLength(field: 5, payload: timestamp(seconds: 1_756_809_934), to: &config)

        var message = Data()
        appendLength(field: 1, payload: config, to: &message)

        var frame = Data()
        frame.append(0)
        frame.append(contentsOf: withUnsafeBytes(of: UInt32(message.count).bigEndian, Array.init))
        frame.append(message)

        let json = try GrokCreditsGrpcParser.parse(data: frame)
        let snapshot = try GrokBillingParser.parse(data: json, providerId: "grok", displayName: "Grok Build")
        XCTAssertEqual(snapshot.groups[0].items[0].usedPercent, 51)
        XCTAssertEqual(
            snapshot.groups[0].items[0].resetAt,
            Date(timeIntervalSince1970: 1_756_809_934)
        )
    }

    func testPercentScaleValueIsNotMultipliedAgain() throws {
        var config = Data()
        appendFixed32(field: 1, float: 25, to: &config)
        var message = Data()
        appendLength(field: 1, payload: config, to: &message)

        let json = try GrokCreditsGrpcParser.parse(data: message)
        let metric = try GrokBillingParser.parse(data: json, providerId: "grok", displayName: "Grok Build").groups[0].items[0]
        XCTAssertEqual(metric.usedPercent, 25)
    }

    private func appendFixed32(field: UInt64, float: Float, to data: inout Data) {
        appendVarint(field << 3 | 5, to: &data)
        var bits = float.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }

    private func appendLength(field: UInt64, payload: Data, to data: inout Data) {
        appendVarint(field << 3 | 2, to: &data)
        appendVarint(UInt64(payload.count), to: &data)
        data.append(payload)
    }

    private func appendVarint(_ value: UInt64, to data: inout Data) {
        var remaining = value
        while remaining >= 0x80 {
            data.append(UInt8(remaining & 0x7f) | 0x80)
            remaining >>= 7
        }
        data.append(UInt8(remaining))
    }

    private func timestamp(seconds: UInt64) -> Data {
        var data = Data()
        appendVarint(1 << 3, to: &data)
        appendVarint(seconds, to: &data)
        return data
    }
}
