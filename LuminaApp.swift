import AppKit
import Foundation

@main
@MainActor
struct LuminaApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
