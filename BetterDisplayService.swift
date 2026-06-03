import Foundation
import os

actor BetterDisplayService: DisplayBackend {
    private let transport: any BetterDisplayTransport
    private let sleeper: any DisplaySleeper
    private let logger = Logger(subsystem: "io.github.lumina-app.Lumina", category: "BetterDisplay")
    private var powerSequenceGeneration = 0

    init(transport: any BetterDisplayTransport = SystemBetterDisplayTransport(), sleeper: any DisplaySleeper = TaskDisplaySleeper()) {
        self.transport = transport
        self.sleeper = sleeper
    }

    func refreshDisplayNames() async -> [String] {
        guard await transport.ensureRunning(context: "refresh displays") else {
            return []
        }

        guard let result = await transport.run(arguments: ["get", "-identifiers"], context: "refresh displays", captureOutput: true) else {
            return []
        }

        let names = parseDisplayNames(from: result.output)
        guard !names.isEmpty else {
            logger.warning("BetterDisplay returned no display identifiers or an unsupported payload.")
            return []
        }

        logger.debug("Refreshed \(names.count, privacy: .public) display names.")
        return names
    }

    func powerOff(targets: [String]) async {
        guard !targets.isEmpty else {
            logger.debug("Skipping power-off because no resolved targets were available.")
            return
        }

        let sequence = beginPowerSequence(label: "power off", targets: targets)
        guard await transport.ensureRunning(context: "power off") else {
            return
        }

        for display in targets {
            guard isCurrentPowerSequence(sequence) else {
                logger.debug("Stopping stale power-off sequence.")
                return
            }

            _ = await transport.run(arguments: ["set", "-name=\(display)", "-connected=off"], context: "power off connected for \(display)", captureOutput: false)
            _ = await transport.run(arguments: ["set", "-name=\(display)", "-ddc", "-vcp=powerMode", "-value=4"], context: "power off DDC for \(display)", captureOutput: false)
        }
    }

    func powerOn(targets: [String]) async {
        guard !targets.isEmpty else {
            logger.debug("Skipping power-on because no resolved targets were available.")
            return
        }

        let sequence = beginPowerSequence(label: "power on", targets: targets)
        guard await transport.ensureRunning(context: "power on") else {
            return
        }

        for display in targets {
            guard isCurrentPowerSequence(sequence) else {
                logger.debug("Stopping stale power-on sequence before the initial pulse.")
                return
            }

            _ = await transport.run(arguments: ["set", "-name=\(display)", "-connected=on"], context: "power on connected for \(display)", captureOutput: false)
            _ = await transport.run(arguments: ["set", "-name=\(display)", "-ddc", "-vcp=powerMode", "-value=1"], context: "power on DDC for \(display)", captureOutput: false)
        }

        guard await waitIfStillCurrent(sequence, seconds: 2, label: "reinitialize") else {
            return
        }

        for display in targets {
            guard isCurrentPowerSequence(sequence) else {
                logger.debug("Stopping stale power-on sequence before reinitialize.")
                return
            }

            _ = await transport.run(arguments: ["perform", "-name=\(display)", "-reinitialize"], context: "power on reinitialize for \(display)", captureOutput: false)
        }

        guard await waitIfStillCurrent(sequence, seconds: 2, label: "backlight") else {
            return
        }

        for display in targets {
            guard isCurrentPowerSequence(sequence) else {
                logger.debug("Stopping stale power-on sequence before backlight recovery.")
                return
            }

            _ = await transport.run(arguments: ["set", "-name=\(display)", "-hardwareBacklight=on"], context: "power on backlight for \(display)", captureOutput: false)
            _ = await transport.run(arguments: ["set", "-name=\(display)", "-ddc", "-vcp=powerMode", "-value=1"], context: "power on final DDC for \(display)", captureOutput: false)
        }
    }

    private func beginPowerSequence(label: String, targets: [String]) -> Int {
        powerSequenceGeneration += 1
        logger.debug("Starting \(label, privacy: .public) sequence \(self.powerSequenceGeneration, privacy: .public) for \(targets.count, privacy: .public) target(s).")
        return powerSequenceGeneration
    }

    private func isCurrentPowerSequence(_ sequence: Int) -> Bool {
        sequence == powerSequenceGeneration
    }

    private func waitIfStillCurrent(_ sequence: Int, seconds: UInt64, label: String) async -> Bool {
        do {
            try await sleeper.sleep(nanoseconds: seconds * 1_000_000_000)
        } catch {
            logger.debug("Cancelled sleep before \(label, privacy: .public) pulse.")
            return false
        }

        guard isCurrentPowerSequence(sequence) else {
            logger.debug("Skipping stale \(label, privacy: .public) pulse.")
            return false
        }

        return true
    }

}
