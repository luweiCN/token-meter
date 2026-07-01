# TokenMeter 通知与重置卡 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 TokenMeter 增加 Codex 重置卡数量和有效期展示，并在新增重置卡、额度刷新、额度归零时发送去重后的 macOS 通知。

**Architecture:** 在 `TokenMeterCore` 扩展快照模型、Codex 解析器和通知事件检测器；在 `TokenMeterApp` 负责读取本机 Codex access token、请求重置卡接口、发送系统通知、渲染可展开的重置卡详情。通知触发只依赖“上一次快照”和“本次成功快照”的状态跨越，避免重复通知。

**Tech Stack:** Swift、SwiftUI、AppKit、UserNotifications、Foundation URLSession、SwiftPM、XCTest。

## Global Constraints

- 只做 macOS 第一版，不引入跨平台通知抽象。
- Codex 重置卡接口固定为 `https://chatgpt.com/backend-api/wham/rate-limit-reset-credits`。
- 认证读取 `~/.codex/auth.json` 的 `tokens.access_token`，请求使用 Bearer token。
- 不打印、不缓存、不展示 access token、refresh token、cookie 或完整唯一 ID。
- 重置卡 UI 默认只显示数量，用户点击后才显示每张卡发放时间和过期时间。
- 首次启动、首次加载缓存、刷新失败、只读缓存数据时不触发通知。
- 通知只在状态跨越边界时触发：新增重置卡、额度从低值恢复到接近 100%、额度从大于 0 变成 0。
- 所有文档使用中文。

---

## File Structure

- Modify: `Sources/TokenMeterCore/UsageModels.swift`
  - 增加 `ResetCreditSummary`、`ResetCredit`，并给 `ProviderUsageSnapshot` 增加可选 `resetCredits`。
- Modify: `Sources/TokenMeterCore/Providers.swift`
  - `CodexUsageProvider` 在读取 rate limit 后继续请求重置卡接口，并把结果传给 parser。
  - 新增 `CodexResetCreditsClient` 和 `CodexResetCreditsParser`。
- Modify: `Sources/TokenMeterCore/ProviderSnapshotCache.swift`
  - 错误合并时保留旧的 `resetCredits`。
- Create: `Sources/TokenMeterCore/UsageNotificationEvents.swift`
  - 纯函数检测通知事件，便于单测。
- Create: `Sources/TokenMeterApp/UsageNotificationCenter.swift`
  - 请求通知权限，并把 core 事件转换成 macOS 通知。
- Modify: `Sources/TokenMeterApp/AppDelegate.swift`
  - 启动时请求通知权限。
- Modify: `Sources/TokenMeterApp/ProviderStore.swift`
  - 刷新成功后比较旧快照和新快照，发送通知。
- Modify: `Sources/TokenMeterApp/PopoverView.swift`
  - 在 Codex 卡片中加入可展开的重置卡摘要与详情。
- Modify: `Tests/TokenMeterCoreTests/CodexUsageParserTests.swift`
  - 覆盖重置卡解析。
- Create: `Tests/TokenMeterCoreTests/UsageNotificationEventDetectorTests.swift`
  - 覆盖通知去重边界。

---

### Task 1: 扩展重置卡数据模型和缓存合并

**Files:**
- Modify: `Sources/TokenMeterCore/UsageModels.swift`
- Modify: `Sources/TokenMeterCore/ProviderSnapshotCache.swift`
- Test: `Tests/TokenMeterCoreTests/ProviderSnapshotCacheTests.swift`

**Interfaces:**
- Produces: `ResetCreditSummary(availableCount: Int, credits: [ResetCredit])`
- Produces: `ResetCredit(issuedAt: Date?, expiresAt: Date?)`
- Produces: `ProviderUsageSnapshot.resetCredits: ResetCreditSummary?`

- [ ] **Step 1: Write the failing test**

在 `ProviderSnapshotCacheTests` 增加一个测试：错误刷新时保留旧的 `resetCredits`。

```swift
func testMergePreservesResetCreditsWhenRefreshFails() {
    let previous = ProviderUsageSnapshot(
        providerId: "codex",
        displayName: "Codex",
        status: .ok,
        fetchedAt: Date(timeIntervalSince1970: 100),
        summary: "ok",
        message: nil,
        groups: [],
        resetCredits: ResetCreditSummary(
            availableCount: 1,
            credits: [ResetCredit(issuedAt: Date(timeIntervalSince1970: 10), expiresAt: Date(timeIntervalSince1970: 20))]
        )
    )
    let failed = ProviderUsageSnapshot(
        providerId: "codex",
        displayName: "Codex",
        status: .error,
        fetchedAt: Date(timeIntervalSince1970: 200),
        summary: nil,
        message: "失败",
        groups: []
    )

    let merged = ProviderSnapshotCache.merge(previous: [previous], refreshed: [failed])

    XCTAssertEqual(merged.first?.status, .warning)
    XCTAssertEqual(merged.first?.resetCredits?.availableCount, 1)
    XCTAssertEqual(merged.first?.resetCredits?.credits.count, 1)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ProviderSnapshotCacheTests/testMergePreservesResetCreditsWhenRefreshFails`

Expected: FAIL because `ResetCreditSummary` and `resetCredits` do not exist.

- [ ] **Step 3: Write minimal implementation**

在 `UsageModels.swift` 增加模型，并把 `resetCredits` 加到 `ProviderUsageSnapshot` initializer 的末尾，默认值为 `nil`，保证现有调用少改动。

```swift
public struct ResetCreditSummary: Codable, Equatable {
    public let availableCount: Int
    public let credits: [ResetCredit]

    public init(availableCount: Int, credits: [ResetCredit]) {
        self.availableCount = availableCount
        self.credits = credits
    }
}

public struct ResetCredit: Codable, Equatable {
    public let issuedAt: Date?
    public let expiresAt: Date?

    public init(issuedAt: Date?, expiresAt: Date?) {
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}
```

在 `ProviderSnapshotCache.merge` 构造 warning 快照时传入：

```swift
resetCredits: cached.resetCredits
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ProviderSnapshotCacheTests/testMergePreservesResetCreditsWhenRefreshFails`

Expected: PASS.

---

### Task 2: 接入 Codex 重置卡接口和解析器

**Files:**
- Modify: `Sources/TokenMeterCore/Providers.swift`
- Test: `Tests/TokenMeterCoreTests/CodexUsageParserTests.swift`

**Interfaces:**
- Consumes: `ResetCreditSummary`
- Produces: `CodexResetCreditsClient.fetch() async throws -> ResetCreditSummary`
- Produces: `CodexResetCreditsParser.parse(data: Data) throws -> ResetCreditSummary`

- [ ] **Step 1: Write parser test**

在 `CodexUsageParserTests` 增加测试，使用固定 JSON 验证北京时间转换留给 UI，模型只保存 `Date`。

```swift
func testResetCreditsParserReadsIssuedAndExpiresDates() throws {
    let json = """
    {
      "credits": [
        {
          "id": "redacted-for-test",
          "created_at": "2026-06-18T00:32:44Z",
          "expires_at": "2026-07-18T00:32:44Z"
        }
      ]
    }
    """.data(using: .utf8)!

    let summary = try CodexResetCreditsParser.parse(data: json)

    XCTAssertEqual(summary.availableCount, 1)
    XCTAssertEqual(summary.credits.count, 1)
    XCTAssertEqual(summary.credits[0].issuedAt, ISO8601DateFormatter().date(from: "2026-06-18T00:32:44Z"))
    XCTAssertEqual(summary.credits[0].expiresAt, ISO8601DateFormatter().date(from: "2026-07-18T00:32:44Z"))
}
```

- [ ] **Step 2: Run parser test to verify it fails**

Run: `swift test --filter CodexUsageParserTests/testResetCreditsParserReadsIssuedAndExpiresDates`

Expected: FAIL because `CodexResetCreditsParser` does not exist.

- [ ] **Step 3: Implement parser and client**

在 `Providers.swift` 增加：

```swift
public enum CodexResetCreditsParser {
    public enum ParseError: LocalizedError {
        case missingCredits

        public var errorDescription: String? {
            "Codex 重置卡响应中没有 credits 数据"
        }
    }

    public static func parse(data: Data) throws -> ResetCreditSummary {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              let credits = dictionary["credits"] as? [[String: Any]] else {
            throw ParseError.missingCredits
        }

        return ResetCreditSummary(
            availableCount: credits.count,
            credits: credits.map {
                ResetCredit(
                    issuedAt: codexDate($0["created_at"]) ?? codexDate($0["issued_at"]),
                    expiresAt: codexDate($0["expires_at"])
                )
            }
        )
    }
}
```

实现 `CodexResetCreditsClient`：

```swift
struct CodexResetCreditsClient {
    let authURL: URL
    let endpoint: URL

    func fetch() async throws -> ResetCreditSummary {
        let token = try readAccessToken()
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TokenMeter/0.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw TokenMeterProviderError.message("Codex 凭证失效或 Authorization header 无效")
        }
        return try CodexResetCreditsParser.parse(data: data)
    }
}
```

`readAccessToken()` 只解析 `tokens.access_token`，错误信息不能包含 token 内容。

- [ ] **Step 4: Wire into Codex provider**

`CodexUsageProvider.fetchProviderUsage()` 先读取 rate limit，再尽力读取重置卡。重置卡失败时不让 Codex 整体失败，而是保留额度快照并在 message 中附加“重置卡读取失败”。

```swift
let usage = try CodexUsageParser.parse(data: data, providerId: id, displayName: displayName)
let resetCredits = try? await CodexResetCreditsClient.default.fetch()
return usage.withResetCredits(resetCredits)
```

- [ ] **Step 5: Run parser test**

Run: `swift test --filter CodexUsageParserTests/testResetCreditsParserReadsIssuedAndExpiresDates`

Expected: PASS.

---

### Task 3: 增加通知事件检测器

**Files:**
- Create: `Sources/TokenMeterCore/UsageNotificationEvents.swift`
- Test: `Tests/TokenMeterCoreTests/UsageNotificationEventDetectorTests.swift`

**Interfaces:**
- Consumes: `[ProviderUsageSnapshot]`
- Produces: `UsageNotificationEventDetector.events(previous:current:) -> [UsageNotificationEvent]`

- [ ] **Step 1: Write event tests**

测试覆盖新增重置卡、额度刷新、额度归零和停留状态不重复触发。

```swift
func testDetectsResetCreditIncrease() {
    let previous = snapshot(resetCredits: ResetCreditSummary(availableCount: 1, credits: []))
    let current = snapshot(resetCredits: ResetCreditSummary(availableCount: 3, credits: []))

    let events = UsageNotificationEventDetector.events(previous: [previous], current: [current])

    XCTAssertEqual(events, [.resetCreditsAdded(providerId: "codex", providerName: "Codex", addedCount: 2, totalCount: 3)])
}
```

```swift
func testDoesNotRepeatWhenResetCreditCountIsUnchanged() {
    let previous = snapshot(resetCredits: ResetCreditSummary(availableCount: 3, credits: []))
    let current = snapshot(resetCredits: ResetCreditSummary(availableCount: 3, credits: []))

    XCTAssertTrue(UsageNotificationEventDetector.events(previous: [previous], current: [current]).isEmpty)
}
```

```swift
func testDetectsQuotaRefreshFromLowRemainingToFull() {
    let previous = snapshot(remainingPercent: 12)
    let current = snapshot(remainingPercent: 100)

    let events = UsageNotificationEventDetector.events(previous: [previous], current: [current])

    XCTAssertEqual(events, [.quotaRefreshed(providerId: "codex", providerName: "Codex", metricLabel: "5h")])
}
```

```swift
func testDetectsQuotaDepletedCrossingZero() {
    let previous = snapshot(remainingPercent: 1)
    let current = snapshot(remainingPercent: 0)

    let events = UsageNotificationEventDetector.events(previous: [previous], current: [current])

    XCTAssertEqual(events, [.quotaDepleted(providerId: "codex", providerName: "Codex", metricLabel: "5h")])
}
```

- [ ] **Step 2: Run event tests to verify they fail**

Run: `swift test --filter UsageNotificationEventDetectorTests`

Expected: FAIL because event types do not exist.

- [ ] **Step 3: Implement event detector**

创建 `UsageNotificationEvents.swift`：

```swift
public enum UsageNotificationEvent: Equatable {
    case resetCreditsAdded(providerId: String, providerName: String, addedCount: Int, totalCount: Int)
    case quotaRefreshed(providerId: String, providerName: String, metricLabel: String)
    case quotaDepleted(providerId: String, providerName: String, metricLabel: String)
}

public enum UsageNotificationEventDetector {
    public static func events(
        previous: [ProviderUsageSnapshot],
        current: [ProviderUsageSnapshot]
    ) -> [UsageNotificationEvent] {
        let previousById = Dictionary(uniqueKeysWithValues: previous.map { ($0.providerId, $0) })
        return current.flatMap { currentSnapshot in
            guard currentSnapshot.status == .ok,
                  let previousSnapshot = previousById[currentSnapshot.providerId],
                  previousSnapshot.status == .ok else {
                return []
            }
            return resetCreditEvents(previous: previousSnapshot, current: currentSnapshot)
                + quotaEvents(previous: previousSnapshot, current: currentSnapshot)
        }
    }
}
```

边界规则：

- `previous.availableCount < current.availableCount` 触发重置卡新增。
- `previous.remainingPercent < 95 && current.remainingPercent >= 99` 触发刷新。
- `previous.remainingPercent > 0 && current.remainingPercent <= 0` 触发归零。

- [ ] **Step 4: Run event tests**

Run: `swift test --filter UsageNotificationEventDetectorTests`

Expected: PASS.

---

### Task 4: 接入 macOS 通知发送

**Files:**
- Create: `Sources/TokenMeterApp/UsageNotificationCenter.swift`
- Modify: `Sources/TokenMeterApp/AppDelegate.swift`
- Modify: `Sources/TokenMeterApp/ProviderStore.swift`

**Interfaces:**
- Consumes: `[UsageNotificationEvent]`
- Produces: `UsageNotificationCenter.requestAuthorization()`
- Produces: `UsageNotificationCenter.deliver(_ events: [UsageNotificationEvent])`

- [ ] **Step 1: Implement notification center wrapper**

创建 `UsageNotificationCenter.swift`：

```swift
import Foundation
import TokenMeterCore
import UserNotifications

final class UsageNotificationCenter {
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    func deliver(_ events: [UsageNotificationEvent]) {
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = title(for: event)
            content.body = body(for: event)
            let request = UNNotificationRequest(
                identifier: identifier(for: event),
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }
}
```

通知文案：

- 新重置卡：`Codex 新增重置卡` / `新增 2 张，当前共 3 张`
- 额度刷新：`Codex 额度已刷新` / `5h 已恢复`
- 额度归零：`Codex 额度已用尽` / `5h 已到 0%`

- [ ] **Step 2: Wire AppDelegate**

在 `AppDelegate` 中创建 `UsageNotificationCenter`，启动时请求权限，并传给 `ProviderStore`。

```swift
private let usageNotificationCenter = UsageNotificationCenter()

func applicationDidFinishLaunching(_ notification: Notification) {
    usageNotificationCenter.requestAuthorization()
    let store = ProviderStore(notificationCenter: usageNotificationCenter)
}
```

- [ ] **Step 3: Wire ProviderStore**

`ProviderStore.refresh()` 在合并前保存旧快照，合并后检测事件并发送。

```swift
let previousProviderSnapshots = providerSnapshots
let mergedProviderSnapshots = ProviderSnapshotCache.merge(previous: providerSnapshots, refreshed: nextProviderSnapshots)
let events = UsageNotificationEventDetector.events(previous: previousProviderSnapshots, current: mergedProviderSnapshots)
notificationCenter?.deliver(events)
```

- [ ] **Step 4: Run app target tests**

Run: `swift test`

Expected: PASS.

---

### Task 5: 增加重置卡 UI

**Files:**
- Modify: `Sources/TokenMeterApp/PopoverView.swift`

**Interfaces:**
- Consumes: `ProviderUsageSnapshot.resetCredits`
- Produces: `ResetCreditsDisclosureView`

- [ ] **Step 1: Add UI component**

在 `ProviderCardView` 的额度区下面加：

```swift
if let resetCredits = snapshot.resetCredits {
    ResetCreditsDisclosureView(summary: resetCredits)
}
```

新增 `ResetCreditsDisclosureView`，默认折叠，只显示数量。

```swift
private struct ResetCreditsDisclosureView: View {
    let summary: ResetCreditSummary
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text("重置卡")
                    Text("\(summary.availableCount) 张")
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(Array(summary.credits.enumerated()), id: \.offset) { index, credit in
                    ResetCreditRowView(index: index + 1, credit: credit)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Add Beijing time formatting**

`ResetCreditRowView` 用 `DateFormatter` 设置 `timeZone = Asia/Shanghai`，显示：

```swift
Text("发放：\(format(credit.issuedAt))")
Text("过期：\(format(credit.expiresAt))")
```

- [ ] **Step 3: Build and inspect**

Run: `swift build`

Expected: PASS.

---

### Task 6: Full verification

**Files:**
- No new files.

**Interfaces:**
- Consumes: all previous tasks.
- Produces: passing test suite and runnable app.

- [ ] **Step 1: Run all tests**

Run: `swift test`

Expected: PASS.

- [ ] **Step 2: Build app bundle**

Run: `swift build`

Expected: PASS.

- [ ] **Step 3: Launch local app if existing script supports it**

Run: `rg -n "swift run|open .*TokenMeter|build" scripts README.md`

Expected: find the current local launch command, then use it to launch the menu bar app.

- [ ] **Step 4: Manual check**

Expected UI:

- Codex 卡片默认显示 `重置卡 6 张`。
- 点击后显示 6 张卡的发放和过期时间，时间为北京时间。
- 没有 token、cookie、完整 ID 出现在 UI、日志或缓存文件中。
- 正常刷新不会重复发送同一个通知。
