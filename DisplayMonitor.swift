import AppKit
import Foundation
import ServiceManagement
import os
import SwiftUI

@MainActor
final class DisplayMonitor: NSObject {
    var availableDisplays: [String] = []

    // Settings
    var targetDisplay: String = "" {
        didSet { UserDefaults.standard.set(targetDisplay, forKey: "TargetDisplay") }
    }
    var targetAllDisplays: Bool = false {
        didSet { UserDefaults.standard.set(targetAllDisplays, forKey: "TargetAllDisplays") }
    }
    var autoOffOnLock: Bool = true {
        didSet { UserDefaults.standard.set(autoOffOnLock, forKey: "AutoOffOnLock") }
    }
    var autoOnOnUnlock: Bool = true {
        didSet { UserDefaults.standard.set(autoOnOnUnlock, forKey: "AutoOnOnUnlock") }
    }

    private let logger = Logger(subsystem: "io.github.lumina-app.Lumina", category: "DisplayMonitor")
    private let displayService: any DisplayBackend
    private let appBundleID = "pro.betterdisplay.BetterDisplay"
    private var statusItem: NSStatusItem?
    private var refreshTask: Task<Void, Never>?
    private var powerTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var powerGeneration = 0

    // State & Resource Management
    private var isLockedOrAsleep = false
    private var heartbeatTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(displayBackend: any DisplayBackend = BetterDisplayService(), createStatusItem: Bool = true) {
        self.displayService = displayBackend
        super.init()
        loadSettings()

        if createStatusItem {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = statusItem?.button {
                button.image = NSImage(systemSymbolName: "moon.stars", accessibilityDescription: "Lumina Controller")
            }
        }

        refreshDisplays()
        setupObservers()
        updateMenu()
    }

    deinit {
        refreshTask?.cancel()
        powerTask?.cancel()
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        heartbeatTimer?.invalidate()
    }

    func updateMenu() {
        let menu = NSMenu()

        // --- Status Section ---
        let statusTitle = statusTitle(targetAllDisplays: targetAllDisplays, targetDisplay: targetDisplay, availableDisplays: availableDisplays)
        let statusItemMenu = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusItemMenu.isEnabled = false
        menu.addItem(statusItemMenu)

        let isRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == appBundleID }
        let bdStatus = isRunning ? "BetterDisplay: Running" : "BetterDisplay: Will Auto-Launch"
        let bdStatusItem = NSMenuItem(title: bdStatus, action: nil, keyEquivalent: "")
        bdStatusItem.isEnabled = false
        menu.addItem(bdStatusItem)

        menu.addItem(NSMenuItem.separator())

        // --- Controls ---
        let offItem = NSMenuItem(title: "Force Power Off", action: #selector(forceOff), keyEquivalent: "")
        offItem.target = self
        menu.addItem(offItem)

        let onItem = NSMenuItem(title: "Force Power On", action: #selector(forceOn), keyEquivalent: "")
        onItem.target = self
        menu.addItem(onItem)

        menu.addItem(NSMenuItem.separator())

        // --- Settings Section ---
        let allItem = NSMenuItem(title: "Target All Displays", action: #selector(toggleTargetAll), keyEquivalent: "")
        allItem.target = self
        allItem.state = targetAllDisplays ? .on : .off
        menu.addItem(allItem)

        let autoOffItem = NSMenuItem(title: "Auto-off on Lock/Sleep", action: #selector(toggleAutoOff), keyEquivalent: "")
        autoOffItem.target = self
        autoOffItem.state = autoOffOnLock ? .on : .off
        menu.addItem(autoOffItem)

        let autoOnItem = NSMenuItem(title: "Auto-on on Unlock/Wake", action: #selector(toggleAutoOn), keyEquivalent: "")
        autoOnItem.target = self
        autoOnItem.state = autoOnOnUnlock ? .on : .off
        menu.addItem(autoOnItem)

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())

        // --- Display Selection ---
        let displayMenu = NSMenu()
        if availableDisplays.isEmpty {
            displayMenu.addItem(NSMenuItem(title: "No displays found", action: nil, keyEquivalent: ""))
        } else {
            for name in availableDisplays {
                let item = NSMenuItem(title: name, action: #selector(selectDisplay(_:)), keyEquivalent: "")
                item.target = self
                item.state = (!targetAllDisplays && name == targetDisplay) ? .on : .off
                item.isEnabled = !targetAllDisplays
                displayMenu.addItem(item)
            }
        }
        displayMenu.addItem(NSMenuItem.separator())
        let refreshItem = NSMenuItem(title: "Refresh Displays", action: #selector(manualRefresh), keyEquivalent: "r")
        refreshItem.target = self
        displayMenu.addItem(refreshItem)

        let subMenuItem = NSMenuItem(title: "Select Specific Display", action: nil, keyEquivalent: "")
        subMenuItem.submenu = displayMenu
        menu.addItem(subMenuItem)

        menu.addItem(NSMenuItem.separator())

        // --- App Info ---
        let aboutItem = NSMenuItem(title: "About Lumina", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(terminate), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc func toggleTargetAll() {
        targetAllDisplays.toggle()
        updateMenu()
    }

    @objc func toggleAutoOff() {
        autoOffOnLock.toggle()
        updateMenu()
    }

    @objc func toggleAutoOn() {
        autoOnOnUnlock.toggle()
        updateMenu()
    }

    @objc func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            logger.info("Launch at Login setting updated.")
        } catch {
            logger.error("Failed to update Launch at Login: \(error.localizedDescription, privacy: .public)")
        }
        updateMenu()
    }

    @objc func forceOff() {
        executePowerOff()
    }

    @objc func forceOn() {
        executePowerOn()
    }

    @objc func manualRefresh() {
        refreshDisplays()
    }

    @objc func terminate() {
        NSApplication.shared.terminate(nil)
    }

    private var aboutWindow: NSWindow?

    @objc func showAbout() {
        if aboutWindow == nil {
            let hostingController = NSHostingController(rootView: AboutView())
            let window = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentViewController = hostingController
            window.center()
            window.level = .floating
            aboutWindow = window
        }

        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func selectDisplay(_ sender: NSMenuItem) {
        targetDisplay = sender.title
        targetAllDisplays = false
        logger.info("Selected display \(sender.title, privacy: .private).")
        updateMenu()
    }

    func refreshDisplays() {
        refreshTask?.cancel()
        let generation = beginRefreshGeneration()
        let backend = displayService
        refreshTask = Task { [weak self] in
            let names = await backend.refreshDisplayNames()
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.isCurrentRefresh(generation) else { return }
                self.applyDisplayRefresh(names)
            }
        }
    }

    private func applyDisplayRefresh(_ names: [String]) {
        availableDisplays = names

        if !targetAllDisplays, !targetDisplay.isEmpty, !availableDisplays.contains(targetDisplay) {
            logger.warning("Selected display \(self.targetDisplay, privacy: .private) is unavailable after refresh.")
        }

        updateMenu()
    }

    private func loadSettings() {
        targetDisplay = UserDefaults.standard.string(forKey: "TargetDisplay") ?? ""
        targetAllDisplays = UserDefaults.standard.bool(forKey: "TargetAllDisplays")
        autoOffOnLock = UserDefaults.standard.object(forKey: "AutoOffOnLock") as? Bool ?? true
        autoOnOnUnlock = UserDefaults.standard.object(forKey: "AutoOnOnUnlock") as? Bool ?? true
    }

    private func beginRefreshGeneration() -> Int {
        refreshGeneration += 1
        return refreshGeneration
    }

    private func isCurrentRefresh(_ generation: Int) -> Bool {
        generation == refreshGeneration
    }

    private func setupObservers() {
        let dnc = DistributedNotificationCenter.default()
        let wc = NSWorkspace.shared.notificationCenter

        observers.append(dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.shouldAcceptScreenLockNotification() ?? false else { return }
                self?.handleSleepOrLock()
            }
        })
        observers.append(dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.shouldAcceptScreenUnlockNotification() ?? false else { return }
                self?.handleWakeOrUnlock()
            }
        })
        observers.append(wc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSleepOrLock()
            }
        })
        observers.append(wc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWakeOrUnlock()
            }
        })
    }

    private func shouldAcceptScreenLockNotification() -> Bool {
        guard let isLocked = currentSessionScreenIsLocked() else {
            logger.debug("Accepting screen lock notification because session lock state is unavailable.")
            return true
        }

        guard isLocked else {
            logger.warning("Ignoring screen lock notification because the current session is not locked.")
            return false
        }

        return true
    }

    private func shouldAcceptScreenUnlockNotification() -> Bool {
        guard let isLocked = currentSessionScreenIsLocked() else {
            logger.debug("Accepting screen unlock notification because session lock state is unavailable.")
            return true
        }

        guard !isLocked else {
            logger.warning("Ignoring screen unlock notification because the current session is still locked.")
            return false
        }

        return true
    }

    private func currentSessionScreenIsLocked() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return nil
        }

        return session["CGSSessionScreenIsLocked"] as? Bool
    }

    func handleSleepOrLock() {
        guard !isLockedOrAsleep else {
            logger.debug("Ignoring duplicate sleep or lock notification.")
            return
        }

        isLockedOrAsleep = true
        logger.debug("System locked or slept.")

        if autoOffOnLock {
            executePowerOff()
        }

        heartbeatTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 900.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isLockedOrAsleep else { return }
                self.executePowerOff()
            }
        }
        timer.tolerance = 60.0
        heartbeatTimer = timer
    }

    func handleWakeOrUnlock() {
        guard isLockedOrAsleep else {
            logger.debug("Ignoring duplicate wake or unlock notification.")
            return
        }

        isLockedOrAsleep = false
        logger.debug("System unlocked or woke.")

        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

        if autoOnOnUnlock {
            executePowerOn()
        }
    }

    private func getTargets() -> [String] {
        resolvedTargets(targetAllDisplays: targetAllDisplays, targetDisplay: targetDisplay, availableDisplays: availableDisplays)
    }

    func executePowerOff() {
        let targets = getTargets()
        guard !targets.isEmpty else {
            logger.info("Skipping power-off because no display target is currently resolved.")
            return
        }

        powerTask?.cancel()
        let generation = beginPowerGeneration()
        let backend = displayService
        powerTask = Task { [weak self] in
            await backend.powerOff(targets: targets)
            await MainActor.run { [weak self] in
                guard let self, self.isCurrentPowerGeneration(generation) else { return }
                self.powerTask = nil
            }
        }
    }

    func executePowerOn() {
        let targets = getTargets()
        guard !targets.isEmpty else {
            logger.info("Skipping power-on because no display target is currently resolved.")
            return
        }

        powerTask?.cancel()
        let generation = beginPowerGeneration()
        let backend = displayService
        powerTask = Task { [weak self] in
            await backend.powerOn(targets: targets)
            await MainActor.run { [weak self] in
                guard let self, self.isCurrentPowerGeneration(generation) else { return }
                self.powerTask = nil
            }
        }
    }

    private func beginPowerGeneration() -> Int {
        powerGeneration += 1
        return powerGeneration
    }

    private func isCurrentPowerGeneration(_ generation: Int) -> Bool {
        generation == powerGeneration
    }
}
