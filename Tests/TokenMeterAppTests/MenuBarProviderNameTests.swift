import AppKit
import XCTest
@testable import TokenMeterApp

final class MenuBarProviderNameTests: XCTestCase {
    func testAntigravityAgentUsesFullProductName() {
        XCTAssertEqual(MenuBarProviderName.label("antigravity-cli"), "Antigravity CLI")
    }

    func testGrokLabel() {
        XCTAssertEqual(MenuBarProviderName.label("grok"), "Grok Build")
    }

    func testBrandIconsComeFromT3AndUnknownAgentsHaveNone() {
        let branded = ["claude-code", "codex", "opencode", "grok", "antigravity-cli", "openclaw"]
        for id in branded {
            XCTAssertNotNil(AgentBrandIcon.icon(for: id), id)
        }
        let unmarked = ["omp", "reasonix", "hermes", "dsh", "qwen-code",
                        "qoder-cli", "qoder-desktop", "workbuddy", "gemini-cli", "not-an-agent"]
        for id in unmarked {
            XCTAssertNil(AgentBrandIcon.icon(for: id), id)
        }
    }

    func testSVGPathReadsTheCommandsTheseLogosUse() {
        let square = SVGPathParser.path(from: "M0 0H10V10H0Z")
        XCTAssertEqual(square.boundingRect, CGRect(x: 0, y: 0, width: 10, height: 10))

        let implicit = SVGPathParser.path(from: "M0 0 10 0 10 10 0 10Z")
        XCTAssertEqual(implicit.boundingRect, CGRect(x: 0, y: 0, width: 10, height: 10))

        let relative = SVGPathParser.path(from: "m2 3 h4 v5 h-4 z")
        XCTAssertEqual(relative.boundingRect, CGRect(x: 2, y: 3, width: 4, height: 5))

        let curve = SVGPathParser.path(from: "M0 0c10 0 10 10 0 10")
        XCTAssertEqual(curve.boundingRect.origin.x, 0, accuracy: 0.01)
        XCTAssertEqual(curve.boundingRect.origin.y, 0, accuracy: 0.01)
        XCTAssertGreaterThan(curve.boundingRect.width, 7)
        XCTAssertLessThanOrEqual(curve.boundingRect.width, 10.01)
        XCTAssertEqual(curve.boundingRect.height, 10, accuracy: 0.01)
    }

    func testCopiedBrandPathsStayInsideTheirViewBox() {
        let ids = ["claude-code", "codex", "opencode", "grok"]
        for id in ids {
            guard case .vector(let mark) = AgentBrandIcon.icon(for: id) else {
                return XCTFail(id)
            }
            for item in mark.paths {
                let bounds = SVGPathParser.path(from: item.d).boundingRect
                XCTAssertFalse(bounds.isNull || bounds.isEmpty, id)
                XCTAssertTrue(mark.viewBox.intersects(bounds), "\(id) \(bounds) misses \(mark.viewBox)")
                XCTAssertLessThan(bounds.width, mark.viewBox.width * 2 + 32, id)
                XCTAssertLessThan(bounds.height, mark.viewBox.height * 2 + 32, id)
            }
        }

        guard case .vector(let claude) = AgentBrandIcon.icon(for: "claude-code") else {
            return XCTFail("claude")
        }
        XCTAssertEqual(claude.paths[0].fillLight, 0xD97757)
        XCTAssertEqual(claude.paths[0].fillDark, 0xD97757)
        XCTAssertFalse(claude.paths[0].evenOdd)

        guard case .vector(let codex) = AgentBrandIcon.icon(for: "codex") else {
            return XCTFail("codex")
        }
        XCTAssertTrue(codex.paths[0].evenOdd)
        XCTAssertEqual(codex.paths[0].fillDark, 0xFFFFFF)

        guard case .vector(let openCode) = AgentBrandIcon.icon(for: "opencode") else {
            return XCTFail("opencode")
        }
        XCTAssertEqual(openCode.paths.map(\.fillLight), [0xCFCECD, 0x211E1E])
        XCTAssertEqual(openCode.paths.map(\.fillDark), [0x4B4646, 0xF1ECEC])
        let frame = SVGPathParser.path(from: openCode.paths[1].d).boundingRect
        XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 32, height: 40))
    }

    func testAntigravityMarkIsTheT3ArchImage() {
        let data = AgentBrandIcon.antigravityPNG
        let image = NSImage(data: data)
        let rep = image?.representations.first
        XCTAssertEqual(rep?.pixelsWide, 128)
        XCTAssertEqual(rep?.pixelsHigh, 128)
        guard case .antigravity = AgentBrandIcon.icon(for: "antigravity-cli") else {
            return XCTFail("antigravity-cli")
        }
    }

    func testOpenClawMarkFillsTheSameSlot() {
        let rep = NSBitmapImageRep(data: AgentBrandIcon.openClawPNG)
        let width = rep?.pixelsWide ?? 0
        let height = rep?.pixelsHigh ?? 0
        XCTAssertGreaterThan(width, 0)
        XCTAssertEqual(width, height)
        var minX = width, minY = height, maxX = 0, maxY = 0
        for y in 0..<height {
            for x in 0..<width {
                guard (rep?.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        XCTAssertLessThan(minX, width / 8)
        XCTAssertLessThan(minY, height / 8)
        XCTAssertGreaterThan(maxX, width * 7 / 8)
        XCTAssertGreaterThan(maxY, height * 7 / 8)
        let mid = width / 2
        XCTAssertGreaterThan(rep?.colorAt(x: mid, y: mid)?.redComponent ?? 0, 0.5)
        guard case .openClaw = AgentBrandIcon.icon(for: "openclaw") else {
            return XCTFail("openclaw")
        }
    }
}
