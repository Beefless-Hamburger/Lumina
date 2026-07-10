import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: DisplayMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor = DisplayMonitor()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.cleanup()
        monitor = nil
    }
}
