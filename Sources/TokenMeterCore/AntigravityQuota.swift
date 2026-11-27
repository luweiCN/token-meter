package enum AntigravityQuota {
    package static let providerID = "antigravity"
    package static let shortName = "AGY"

    package static func menuName(_ name: String) -> String {
        name == "Antigravity" ? shortName : name
    }
}
