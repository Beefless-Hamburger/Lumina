import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: DisplayMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor = DisplayMonitor()
    }
}
