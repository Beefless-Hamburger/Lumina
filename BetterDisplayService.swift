import Foundation
import os

actor BetterDisplayService: DisplayBackend {
    private static let fullBrightness = "1.0"

    private enum CommandDecision {
        case succeeded
        case recoverableFailure
        case terminalFailure
        case superseded
    }

    private let transport: any BetterDisplayTransport
    private let sleeper: any DisplaySleeper
    private let logger = Logger(subsystem: "io.github.lumina-app.Lumina", category: "BetterDisplay")
    private var powerSequenceGeneration = 0

    init(transport: any BetterDisplayTransport = SystemBetterDisplayTransport(), sleeper: any DisplaySleeper = TaskDisplaySleeper()) {
        self.transport = transport
        self.sleeper = sleeper
    }

    func refreshDisplayTargets() async -> [DisplayTarget] {
        let availability = await transport.ensureRunning(context: "refresh displays")
        guard availability.isAvailable else {
            return []
        }

        let result = await transport.run(arguments: ["get", "-identifiers"], context: "refresh displays", captureOutput: true)
        guard result.succeeded else {
            return []
        }

        let targets = parseDisplayTargets(from: result.output)
        guard !targets.isEmpty else {
            logger.warning("BetterDisplay returned no display identifiers or an unsupported payload.")
            return []
        }

        logger.debug("Refreshed \(targets.count, privacy: .public) display targets.")
        return targets
    }

    func powerOff(targets requestedTargets: [String]) async -> DisplayOperationResult {
        let targets = normalizedTargets(requestedTargets)
        let sequence = beginPowerSequence(label: "power off", targets: targets)

        guard !targets.isEmpty else {
            logger.debug("Skipping power-off because no resolved targets were available.")
            return .noTargets
        }

        let availability = await transport.ensureRunning(context: "power off")
        guard availability.isAvailable else {
            return unavailableResult(for: availability)
        }
        guard shouldContinue(sequence, label: "power-off after launch") else {
            return supersededResult()
        }

        var attemptedCommands = 0
        var failedCommands = 0

        for display in targets {
            let commands = [
                (["set", "-UUID=\(display)", "-connected=off"], "power off connected"),
                (["set", "-UUID=\(display)", "-ddc", "-vcp=powerMode", "-value=4"], "power off DDC")
            ]

            for (arguments, context) in commands {
                attemptedCommands += 1
                switch await executeCommand(arguments: arguments, context: context, sequence: sequence) {
                case .succeeded:
                    break
                case .recoverableFailure:
                    failedCommands += 1
                case .terminalFailure:
                    failedCommands += 1
                    return failedResult(attemptedCommands: attemptedCommands, failedCommands: failedCommands)
                case .superseded:
                    return supersededResult(attemptedCommands: attemptedCommands, failedCommands: failedCommands)
                }
            }
        }

        return completedResult(attemptedCommands: attemptedCommands, failedCommands: failedCommands)
    }

    func powerOn(targets requestedTargets: [String], restoreHDRBrightness: Bool = false) async -> DisplayOperationResult {
        let targets = normalizedTargets(requestedTargets)
        let sequence = beginPowerSequence(label: "power on", targets: targets)

        guard !targets.isEmpty else {
            logger.debug("Skipping power-on because no resolved targets were available.")
            return .noTargets
        }

        let availability = await transport.ensureRunning(context: "power on")
        guard availability.isAvailable else {
            return unavailableResult(for: availability)
        }
        guard shouldContinue(sequence, label: "power-on after launch") else {
            return supersededResult()
        }

        var attemptedCommands = 0
        var failedCommands = 0
        var connectedTargets: [String] = []

        for display in targets {
            attemptedCommands += 1
            switch await executeCommand(
                arguments: ["set", "-UUID=\(display)", "-connected=on"],
                context: "power on connected",
                sequence: sequence
            ) {
            case .succeeded:
                connectedTargets.append(display)
            case .recoverableFailure:
                failedCommands += 1
                continue
            case .terminalFailure:
                failedCommands += 1
                return failedResult(attemptedCommands: attemptedCommands, failedCommands: failedCommands)
            case .superseded:
                return supersededResult(attemptedCommands: attemptedCommands, failedCommands: failedCommands)
            }

            attemptedCommands += 1
            switch await executeCommand(
                arguments: ["set", "-UUID=\(display)", "-ddc", "-vcp=powerMode", "-value=1"],
                context: "power on DDC",
                sequence: sequence
            ) {
            case .succeeded:
                break
            case .recoverableFailure:
                failedCommands += 1
            case .terminalFailure:
                failedCommands += 1
                return failedResult(attemptedCommands: attemptedCommands, failedCommands: failedCommands)
            case .superseded:
                return supersededResult(attemptedCommands: attemptedCommands, failedCommands: failedCommands)
            }
        }

        guard !connectedTargets.isEmpty else {
            logger.error("Power-on could not connect any requested display targets.")
            return failedResult(attemptedCommands: attemptedCommands, failedCommands: failedCommands)
        }

        guard await waitIfStillCurrent(sequence, seconds: 2, label: "reinitialize") else {
            return supersededResult(attemptedCommands: attemptedCommands, failedCommands: failedCommands)
        }

        for display in connectedTargets {
            attemptedCommands += 1
            switch await executeCommand(
                arguments: ["perform", "-UUID=\(display)", "-reinitialize"],
                context: "power on reinitialize",
                sequence: sequence
            ) {
            case .succeeded:
                break
            case .recoverableFailure:
                failedCommands += 1
            case .terminalFailure:
                failedCommands += 1
                return failedResult(attemptedCommands: attemptedCommands, failedCommands: failedCommands)
            case .superseded:
                return supersededResult(attemptedCommands: attemptedCommands, failedCommands: failedCommands)
            }
        }

        guard await waitIfStillCurrent(sequence, seconds: 2, label: "backlight") else {
            return supersededResult(attemptedCommands: attemptedCommands, failedCommands: failedCommands)
        }

        for display in connectedTargets {
            let commands = [
                (["set", "-UUID=\(display)", "-hardwareBacklight=on"], "power on backlight"),
                (["set", "-UUID=\(display)", "-ddc", "-vcp=powerMode", "-value=1"], "power on final DDC")
            ]

            for (arguments, context) in commands {
                attemptedCommands += 1
                switch await executeCommand(arguments: arguments, context: context, sequence: sequence) {
                case .succeeded:
                    break
                case .recoverableFailure:
                    failedCommands += 1
                case .terminalFailure:
                    failedCommands += 1
                    return failedResult(attemptedCommands: attemptedCommands, failedCommands: failedCommands)
                case .superseded:
                    return supersededResult(attemptedCommands: attemptedCommands, failedCommands: failedCommands)
                }
            }
        }

        if restoreHDRBrightness {
            for (index, display) in connectedTargets.enumerated() {
                guard shouldContinue(sequence, label: "HDR brightness qualification") else {
                    return supersededResult(attemptedCommands: attemptedCommands, failedCommands: failedCommands)
                }

                logger.debug("Checking HDR brightness recovery qualification for target index \(index, privacy: .public).")
                let hdrResult = await transport.run(
                    arguments: ["get", "-UUID=\(display)", "-hdr", "-value"],
                    context: "check HDR state",
                    captureOutput: true
                )
                guard shouldContinue(sequence, label: "HDR brightness qualification") else {
                    return supersededResult(attemptedCommands: attemptedCommands, failedCommands: failedCommands)
                }

                guard hdrResult.succeeded else {
                    logger.warning("HDR detection was unavailable for target index \(index, privacy: .public); skipping brightness recovery.")
                    continue
                }
                guard hdrResult.output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "on" else {
                    logger.debug("Target index \(index, privacy: .public) did not qualify for HDR brightness recovery.")
                    continue
                }

                attemptedCommands += 1
                logger.debug("Attempting HDR brightness recovery for target index \(index, privacy: .public).")
                switch await executeCommand(
                    arguments: ["set", "-UUID=\(display)", "-brightness=\(Self.fullBrightness)"],
                    context: "restore HDR brightness",
                    sequence: sequence
                ) {
                case .succeeded:
                    logger.debug("HDR brightness recovery succeeded for target index \(index, privacy: .public).")
                case .recoverableFailure:
                    failedCommands += 1
                    logger.warning("HDR brightness recovery failed for target index \(index, privacy: .public).")
                case .terminalFailure:
                    failedCommands += 1
                    logger.warning("HDR brightness recovery could not complete for target index \(index, privacy: .public).")
                case .superseded:
                    return supersededResult(attemptedCommands: attemptedCommands, failedCommands: failedCommands)
                }
            }
        } else {
            logger.debug("HDR brightness recovery is disabled; wake sequence is unchanged.")
        }

        return completedResult(attemptedCommands: attemptedCommands, failedCommands: failedCommands)
    }

    private func beginPowerSequence(label: String, targets: [String]) -> Int {
        powerSequenceGeneration += 1
        logger.debug("Starting \(label, privacy: .public) sequence \(self.powerSequenceGeneration, privacy: .public) for \(targets.count, privacy: .public) target(s).")
        return powerSequenceGeneration
    }

    private func shouldContinue(_ sequence: Int, label: String) -> Bool {
        if Task.isCancelled {
            logger.debug("Stopping cancelled \(label, privacy: .public) sequence.")
            return false
        }

        guard sequence == powerSequenceGeneration else {
            logger.debug("Stopping stale \(label, privacy: .public) sequence.")
            return false
        }

        return true
    }

    private func executeCommand(arguments: [String], context: String, sequence: Int) async -> CommandDecision {
        guard shouldContinue(sequence, label: context) else {
            return .superseded
        }

        let result = await transport.run(arguments: arguments, context: context, captureOutput: false)

        guard shouldContinue(sequence, label: context) else {
            return .superseded
        }

        switch result.status {
        case .succeeded:
            return .succeeded
        case .nonZeroExit:
            return .recoverableFailure
        case .cancelled:
            return .superseded
        case .executableMissing, .launchFailed, .timedOut:
            return .terminalFailure
        }
    }

    private func waitIfStillCurrent(_ sequence: Int, seconds: UInt64, label: String) async -> Bool {
        guard shouldContinue(sequence, label: label) else {
            return false
        }

        do {
            try await sleeper.sleep(nanoseconds: seconds * 1_000_000_000)
        } catch {
            logger.debug("Cancelled sleep before \(label, privacy: .public) pulse.")
            return false
        }

        return shouldContinue(sequence, label: label)
    }

    private func normalizedTargets(_ targets: [String]) -> [String] {
        var seen = Set<String>()
        return targets.filter { target in
            !target.isEmpty && seen.insert(target).inserted
        }
    }

    private func unavailableResult(for availability: BetterDisplayAvailability) -> DisplayOperationResult {
        if availability == .cancelled {
            return supersededResult()
        }

        return DisplayOperationResult(
            status: .betterDisplayUnavailable(availability),
            attemptedCommandCount: 0,
            failedCommandCount: 0
        )
    }

    private func completedResult(attemptedCommands: Int, failedCommands: Int) -> DisplayOperationResult {
        DisplayOperationResult(
            status: failedCommands == 0 ? .succeeded : .failed,
            attemptedCommandCount: attemptedCommands,
            failedCommandCount: failedCommands
        )
    }

    private func failedResult(attemptedCommands: Int, failedCommands: Int) -> DisplayOperationResult {
        DisplayOperationResult(
            status: .failed,
            attemptedCommandCount: attemptedCommands,
            failedCommandCount: failedCommands
        )
    }

    private func supersededResult(attemptedCommands: Int = 0, failedCommands: Int = 0) -> DisplayOperationResult {
        DisplayOperationResult(
            status: .superseded,
            attemptedCommandCount: attemptedCommands,
            failedCommandCount: failedCommands
        )
    }
}
