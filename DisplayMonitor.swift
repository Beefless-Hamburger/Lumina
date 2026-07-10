import AppKit
import Foundation
import ServiceManagement
import os
import SwiftUI

@MainActor
final class DisplayMonitor: NSObject {
    private enum PowerDirection {
        case on
        case off
    }

    var availableDisplays: [String] = []
    private var availableDisplayTargets: [DisplayTarget] = []
    private var targetDisplayIdentifier: String = "" {
        didSet {
            if oldValue != targetDisplayIdentifier {
                UserDefaults.standard.set(targetDisplayIdentifier, forKey: "TargetDisplayIdentifier")
            }
        }
    }

    // Settings
    var targetDisplay: String = "" {
        didSet {
            if oldValue != targetDisplay {
                UserDefaults.standard.set(targetDisplay, forKey: "TargetDisplay")
            }
        }
    }
    var targetAllDisplays: Bool = false {
        didSet {
            if oldValue != targetAllDisplays {
                UserDefaults.standard.set(targetAllDisplays, forKey: "TargetAllDisplays")
            }
        }
    }
    var autoOffOnLock: Bool = true {
        didSet {
            if oldValue != autoOffOnLock {
                UserDefaults.standard.set(autoOffOnLock, forKey: "AutoOffOnLock")
            }
        }
    }
    var autoOnOnUnlock: Bool = true {
        didSet {
            if oldValue != autoOnOnUnlock {
                UserDefaults.standard.set(autoOnOnUnlock, forKey: "AutoOnOnUnlock")
            }
        }
    }
    var restoreHDRBrightnessAfterWake: Bool = false {
        didSet {
            if oldValue != restoreHDRBrightnessAfterWake {
                saveRestoreHDRBrightnessPreference(restoreHDRBrightnessAfterWake, to: .standard)
            }
        }
    }

    private let logger = Logger(subsystem: "io.github.lumina-app.Lumina", category: "DisplayMonitor")
    private let displayService: any DisplayBackend
    private let heartbeatController: ShutdownHeartbeatController
    private let sessionLockStateProvider: @MainActor () -> Bool?
    private let appBundleID = "pro.betterdisplay.BetterDisplay"
    private var statusItem: NSStatusItem?
    private var refreshTask: Task<Void, Never>?
    private var powerTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var powerGeneration = 0
    private var powerDirection: PowerDirection?
    private var screenReconciliationTask: Task<Void, Never>?
    private var screenNotificationGeneration = 0
    private let screenReconciliationAttempts = 5
    private let screenReconciliationDelayNanoseconds: UInt64 = 100_000_000

    // State & Resource Management
    private var lifecycleCoordinator = DisplayLifecycleCoordinator()
    private var observers: [NSObjectProtocol] = []

    private var isLockedOrAsleep: Bool {
        lifecycleCoordinator.state.isInactive
    }

    init(
        displayBackend: any DisplayBackend = BetterDisplayService(),
        heartbeatScheduler: any HeartbeatScheduling = FoundationHeartbeatScheduler(),
        sessionLockStateProvider: @escaping @MainActor () -> Bool? = DisplayMonitor.systemSessionScreenIsLocked,
        createStatusItem: Bool = true
    ) {
        self.displayService = displayBackend
        heartbeatController = ShutdownHeartbeatController(scheduler: heartbeatScheduler)
        self.sessionLockStateProvider = sessionLockStateProvider
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

    isolated deinit {
        refreshTask?.cancel()
        powerTask?.cancel()
        screenReconciliationTask?.cancel()
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func cleanup() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration += 1
        invalidatePowerOperation()
        screenReconciliationTask?.cancel()
        screenReconciliationTask = nil
        screenNotificationGeneration += 1
        stopHeartbeatTimer()

        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
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

        let brightnessItem = NSMenuItem(title: "Restore HDR Brightness After Wake", action: #selector(toggleHDRBrightnessRecovery), keyEquivalent: "")
        brightnessItem.target = self
        brightnessItem.state = restoreHDRBrightnessAfterWake ? .on : .off
        menu.addItem(brightnessItem)

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
                if let target = availableDisplayTargets.first(where: { $0.selectionLabel == name }) {
                    item.representedObject = target.identifier
                    item.state = (!targetAllDisplays && target.identifier == targetDisplayIdentifier) ? .on : .off
                }
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
        targetSelectionDidChange()
        updateMenu()
    }

    @objc func toggleAutoOff() {
        autoOffOnLock.toggle()

        if !autoOffOnLock {
            invalidatePowerOperation(if: .off)
            stopHeartbeatTimer()
        } else if isLockedOrAsleep {
            executePowerOff()
            startHeartbeatTimer()
        }

        updateMenu()
    }

    @objc func toggleAutoOn() {
        autoOnOnUnlock.toggle()
        if !autoOnOnUnlock {
            invalidatePowerOperation(if: .on)
        }
        updateMenu()
    }

    @objc func toggleHDRBrightnessRecovery() {
        restoreHDRBrightnessAfterWake.toggle()
        logger.info("HDR brightness recovery setting changed; enabled=\(self.restoreHDRBrightnessAfterWake, privacy: .public).")
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
        cleanup()
        NSApplication.shared.terminate(nil)
    }

    private var aboutWindow: NSWindow?

    @objc func showAbout() {
        if aboutWindow == nil {
            let hostingController = NSHostingController(rootView: AboutView())
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 390),
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
        targetDisplayIdentifier = sender.representedObject as? String ?? ""
        targetAllDisplays = false
        targetSelectionDidChange()
        logger.info("Selected display \(sender.title, privacy: .private).")
        updateMenu()
    }

    func refreshDisplays() {
        refreshTask?.cancel()
        let generation = beginRefreshGeneration()
        let backend = displayService
        refreshTask = Task { [weak self] in
            let targets = await backend.refreshDisplayTargets()
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.isCurrentRefresh(generation) else { return }
                self.applyDisplayRefresh(targets)
            }
        }
    }

    private func applyDisplayRefresh(_ targets: [DisplayTarget]) {
        let previousTargets = getTargets()
        availableDisplayTargets = targets
        availableDisplays = targets.map(\.selectionLabel)

        if targetDisplayIdentifier.isEmpty, !targetDisplay.isEmpty {
            let legacyMatches = targets.filter { $0.name == targetDisplay || $0.selectionLabel == targetDisplay }
            if legacyMatches.count == 1, let match = legacyMatches.first {
                targetDisplayIdentifier = match.identifier
                targetDisplay = match.selectionLabel
            }
        } else if let selected = targets.first(where: { $0.identifier == targetDisplayIdentifier }) {
            targetDisplay = selected.selectionLabel
        }
        let refreshedTargets = getTargets()

        if !targetAllDisplays, !targetDisplayIdentifier.isEmpty,
           !availableDisplayTargets.contains(where: { $0.identifier == targetDisplayIdentifier }) {
            logger.warning("Selected display \(self.targetDisplay, privacy: .private) is unavailable after refresh.")
        }

        if previousTargets != refreshedTargets {
            invalidatePowerOperation()
            if isLockedOrAsleep, autoOffOnLock {
                executePowerOff()
            }
        }

        updateMenu()
    }

    private func targetSelectionDidChange() {
        invalidatePowerOperation()
        if isLockedOrAsleep, autoOffOnLock {
            executePowerOff()
        }
    }

    private func loadSettings() {
        targetDisplay = UserDefaults.standard.string(forKey: "TargetDisplay") ?? ""
        targetDisplayIdentifier = UserDefaults.standard.string(forKey: "TargetDisplayIdentifier") ?? ""
        targetAllDisplays = UserDefaults.standard.bool(forKey: "TargetAllDisplays")
        autoOffOnLock = UserDefaults.standard.object(forKey: "AutoOffOnLock") as? Bool ?? true
        autoOnOnUnlock = UserDefaults.standard.object(forKey: "AutoOnOnUnlock") as? Bool ?? true
        restoreHDRBrightnessAfterWake = loadRestoreHDRBrightnessPreference(from: .standard)
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
                self?.receiveScreenNotification(.screenLocked)
            }
        })
        observers.append(dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.receiveScreenNotification(.screenUnlocked)
            }
        })
        observers.append(wc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleLifecycleEvent(.systemWillSleep)
            }
        })
        observers.append(wc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleLifecycleEvent(.systemDidWake)
            }
        })
    }

    private func receiveScreenNotification(_ event: DisplayLifecycleEvent) {
        screenReconciliationTask?.cancel()
        screenNotificationGeneration += 1
        let generation = screenNotificationGeneration
        logger.debug("Received \(self.eventLabel(event), privacy: .public) notification.")

        screenReconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return }

            for attempt in 1...screenReconciliationAttempts {
                guard !Task.isCancelled, generation == screenNotificationGeneration else { return }
                let sessionLocked = currentSessionScreenIsLocked()
                let isFinalAttempt = attempt == screenReconciliationAttempts
                let outcome = lifecycleCoordinator.receive(
                    event,
                    sessionScreenIsLocked: sessionLocked,
                    finalReconciliationAttempt: isFinalAttempt
                )
                logScreenNotificationDecision(
                    event: event,
                    sessionLocked: sessionLocked,
                    attempt: attempt,
                    outcome: outcome
                )

                if outcome.disposition != .delayed {
                    if outcome.disposition == .accepted {
                        applyLifecycleOutcome(outcome, event: event)
                    }
                    if generation == screenNotificationGeneration {
                        screenReconciliationTask = nil
                    }
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: screenReconciliationDelayNanoseconds)
                } catch {
                    return
                }
            }
        }
    }

    private func currentSessionScreenIsLocked() -> Bool? {
        sessionLockStateProvider()
    }

    private static func systemSessionScreenIsLocked() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return nil
        }

        return session["CGSSessionScreenIsLocked"] as? Bool
    }

    func handleLifecycleEvent(_ event: DisplayLifecycleEvent) {
        let outcome = lifecycleCoordinator.receive(event)
        applyLifecycleOutcome(outcome, event: event)
    }

    private func applyLifecycleOutcome(_ outcome: DisplayLifecycleOutcome, event: DisplayLifecycleEvent) {
        guard let transition = outcome.transition else { return }
        logger.debug("Applied \(self.eventLabel(event), privacy: .public): transition=\(self.transitionLabel(transition), privacy: .public), beforeLocked=\(outcome.stateBefore.isScreenLocked, privacy: .public), beforeAsleep=\(outcome.stateBefore.isSystemAsleep, privacy: .public), afterLocked=\(outcome.stateAfter.isScreenLocked, privacy: .public), afterAsleep=\(outcome.stateAfter.isSystemAsleep, privacy: .public).")

        switch transition {
        case .becameInactive:
            logger.debug("System entered a locked or asleep state.")
            guard autoOffOnLock else {
                stopHeartbeatTimer()
                logger.debug("Auto-off on lock/sleep is disabled; skipping shutdown heartbeat.")
                return
            }
            executePowerOff()
            startHeartbeatTimer()

        case .becameActive:
            logger.debug("System fully returned from lock and sleep.")
            stopHeartbeatTimer()
            if autoOnOnUnlock {
                executePowerOn(restoreHDRBrightness: true)
            }

        case .unchanged:
            logger.debug("Lifecycle event did not change the combined lock/sleep state.")
            if isLockedOrAsleep {
                if autoOffOnLock {
                    startHeartbeatTimer()
                } else {
                    stopHeartbeatTimer()
                }
            } else {
                stopHeartbeatTimer()
            }
        }
    }

    private func logScreenNotificationDecision(
        event: DisplayLifecycleEvent,
        sessionLocked: Bool?,
        attempt: Int,
        outcome: DisplayLifecycleOutcome
    ) {
        let sessionLabel = sessionLocked.map(String.init) ?? "unavailable"
        let disposition: String
        switch outcome.disposition {
        case .accepted: disposition = "accepted"
        case .delayed: disposition = "delayed"
        case .ignored: disposition = "ignored"
        }
        logger.debug("Screen event=\(self.eventLabel(event), privacy: .public), sessionLocked=\(sessionLabel, privacy: .public), attempt=\(attempt, privacy: .public), decision=\(disposition, privacy: .public), stateLocked=\(self.lifecycleCoordinator.state.isScreenLocked, privacy: .public), stateAsleep=\(self.lifecycleCoordinator.state.isSystemAsleep, privacy: .public).")
    }

    private func eventLabel(_ event: DisplayLifecycleEvent) -> String {
        switch event {
        case .screenLocked: return "screenLocked"
        case .screenUnlocked: return "screenUnlocked"
        case .systemWillSleep: return "systemWillSleep"
        case .systemDidWake: return "systemDidWake"
        }
    }

    private func transitionLabel(_ transition: DisplayLifecycleTransition) -> String {
        switch transition {
        case .becameInactive: return "becameInactive"
        case .becameActive: return "becameActive"
        case .unchanged: return "unchanged"
        }
    }

    private func startHeartbeatTimer() {
        guard autoOffOnLock, isLockedOrAsleep else {
            logger.debug("Not starting shutdown heartbeat because shutdown automation is inactive.")
            return
        }

        let wasRunning = heartbeatController.isRunning
        heartbeatController.start { [weak self] in
            guard let self, self.isLockedOrAsleep, self.autoOffOnLock else { return }
            self.executePowerOff()
        }
        logger.debug("Shutdown heartbeat start requested; wasRunning=\(wasRunning, privacy: .public), isRunning=\(self.heartbeatController.isRunning, privacy: .public).")
    }

    private func stopHeartbeatTimer() {
        let wasRunning = heartbeatController.isRunning
        heartbeatController.stop()
        logger.debug("Shutdown heartbeat stopped; wasRunning=\(wasRunning, privacy: .public).")
    }

    private func getTargets() -> [String] {
        if targetAllDisplays {
            return availableDisplayTargets.map(\.identifier)
        }
        guard availableDisplayTargets.contains(where: { $0.identifier == targetDisplayIdentifier }) else {
            return []
        }
        return [targetDisplayIdentifier]
    }

    func executePowerOff() {
        executePower(direction: .off)
    }

    func executePowerOn(restoreHDRBrightness: Bool = false) {
        executePower(direction: .on, restoreHDRBrightness: restoreHDRBrightness)
    }

    private func executePower(direction: PowerDirection, restoreHDRBrightness: Bool = false) {
        let cancelledExistingTask = powerTask != nil
        invalidatePowerOperation()
        let targets = getTargets()
        guard !targets.isEmpty else {
            logger.info("Skipping power command because no display target is currently resolved.")
            return
        }

        powerDirection = direction
        let generation = powerGeneration
        let operation = direction == .on ? "power-on" : "power-off"
        let shouldRestoreHDRBrightness = restoreHDRBrightness && restoreHDRBrightnessAfterWake
        logger.debug("Requesting \(operation, privacy: .public), generation=\(generation, privacy: .public), cancelledExistingTask=\(cancelledExistingTask, privacy: .public), targetCount=\(targets.count, privacy: .public).")
        let backend = displayService
        powerTask = Task { [weak self] in
            let result: DisplayOperationResult
            switch direction {
            case .off:
                result = await backend.powerOff(targets: targets)
            case .on:
                result = await backend.powerOn(
                    targets: targets,
                    restoreHDRBrightness: shouldRestoreHDRBrightness
                )
            }

            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.isCurrentPowerGeneration(generation) else { return }
                self.logPowerResult(result, direction: direction)
                self.powerTask = nil
                self.powerDirection = nil
            }
        }
    }

    private func invalidatePowerOperation(if direction: PowerDirection? = nil) {
        if let direction, powerDirection != direction {
            return
        }

        powerTask?.cancel()
        powerTask = nil
        powerDirection = nil
        powerGeneration += 1
    }

    private func isCurrentPowerGeneration(_ generation: Int) -> Bool {
        generation == powerGeneration
    }

    private func logPowerResult(_ result: DisplayOperationResult, direction: PowerDirection) {
        let operation = direction == .on ? "power-on" : "power-off"

        switch result.status {
        case .succeeded:
            logger.debug("Completed \(operation, privacy: .public) with \(result.attemptedCommandCount, privacy: .public) command(s).")
        case .noTargets:
            logger.info("Skipped \(operation, privacy: .public) because no targets were available.")
        case let .betterDisplayUnavailable(availability):
            logger.error("Could not complete \(operation, privacy: .public) because BetterDisplay was \(self.availabilityLabel(availability), privacy: .public).")
        case .superseded:
            logger.debug("Stopped superseded \(operation, privacy: .public) operation.")
        case .failed:
            logger.error("Completed \(operation, privacy: .public) with \(result.failedCommandCount, privacy: .public) failed command(s) out of \(result.attemptedCommandCount, privacy: .public).")
        }
    }

    private func availabilityLabel(_ availability: BetterDisplayAvailability) -> String {
        switch availability {
        case .running:
            return "available"
        case .unavailable:
            return "not installed"
        case .launchFailed:
            return "unable to launch"
        case .timedOut:
            return "not ready before the launch timeout"
        case .cancelled:
            return "cancelled"
        }
    }
}
