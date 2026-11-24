import AppKit
import TokenMeterCore

@main
@MainActor
enum TokenMeterMain {
    static func main() {
        if CommandLine.arguments.dropFirst().first == AntigravityQuota.captureArgument {
            AntigravityStatusLine.captureInput(passthrough: CommandLine.arguments.dropFirst(2).first == "--passthrough")
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()

        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
